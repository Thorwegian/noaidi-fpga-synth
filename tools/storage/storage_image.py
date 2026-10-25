#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Copy the synth's storage partition to and from a folder.

    storage_image.py read   <folder>          synth -> folder (over serial)
    storage_image.py write  <folder>          folder -> synth
    storage_image.py pack   <folder> <image>  folder -> image file
    storage_image.py unpack <image>  <folder> image file -> folder

Every command replaces its destination: write and pack replace the
whole partition, read and unpack replace the folder. A folder is only
replaced when it is empty or holds a storage copy (system.toml or
Presets at its top), so a mistyped path cannot wipe unrelated files.

read and write talk to the ESP32 through ESP-IDF's parttool; set ESPPORT
to pick the serial port, otherwise esptool finds it.

The partition (docs/storage_format.md) is FAT with long names on
ESP-IDF's wear-levelling layer, in safety mode with 512-byte sectors.
The FAT part is built and read by fatimage.c, which runs ESP-IDF's own
FatFs against a RAM disk. This script compiles it on first use and adds
or removes the wear-levelling layer, following
components/wear_levelling/WL_Flash.cpp:

    physical: [dummy page][logical pages ...][state 1][state 2][config]

The logical pages are the FAT followed by the two pages safety mode
reserves for itself. The dummy page moves through them as the device
writes, so unpacking reads the dummy position and move count from the
state and maps every logical page back.

ESP-IDF's location and its Python come from the firmware build
(app/build), so run "make fw" once first; $IDF_PATH overrides the
location. Any Python 3 runs this script.
"""

import binascii
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
PARTITIONS = os.path.join(REPO, 'app', 'partitions.csv')
SDKCONFIG = os.path.join(REPO, 'app', 'sdkconfig')
BUILD = os.path.join(REPO, 'app', 'build')

PAGE = 4096                 # flash sector = WL page
FAT_SECTOR = 512            # CONFIG_WL_SECTOR_SIZE
SAFE_PAGES = 2              # WL_Ext_Safe: transaction state + dump page
STATE_HEADER = 64           # sizeof(wl_state_t)
STATE_RECORD = 16           # cfg.wl_pos_update_record_size
CFG_HEADER = 48
WL_VERSION = 2
WL_UPDATE_RATE = 16
WL_WR_SIZE = 16
WL_TEMP_BUFF = 32
DEVICE_ID = 0x4E4F4144      # fixed, so a folder always packs to the same image


def crc32(data):
    """crc32_le(UINT32_MAX, ...) as WL_Flash computes it."""
    return binascii.crc32(data, 0xFFFFFFFF) & 0xFFFFFFFF


def partition_size(name='storage'):
    with open(PARTITIONS) as f:
        for line in f:
            fields = [x.strip() for x in line.split('#')[0].split(',')]
            if fields[0] == name:
                return int(fields[4], 0)
    sys.exit(f'storage_image: no "{name}" partition in {PARTITIONS}')


class Layout:
    """Where WL_Flash puts things in a partition of a given size."""

    def __init__(self, size):
        pages = size // PAGE
        self.size = size
        # state: header + one record per flash page, rounded up to pages
        self.state_bytes = -(-(STATE_HEADER + pages * STATE_RECORD) // PAGE) * PAGE
        self.addr_state1 = size - 2 * self.state_bytes - PAGE
        self.addr_state2 = size - self.state_bytes - PAGE
        self.addr_cfg = size - PAGE
        self.logical_pages = (size - 2 * self.state_bytes - PAGE) // PAGE - 1
        self.max_pos = self.logical_pages + 1          # wl_part_max_sec_pos
        self.fat_pages = self.logical_pages - SAFE_PAGES

    def physical(self, logical_page, pos, move_count):
        """WL_Flash::calcAddr, in pages."""
        result = (self.logical_pages - move_count + logical_page) % self.logical_pages
        return result + 1 if result >= pos else result


# ── fatimage.c, built against ESP-IDF's FatFs ──────────────────────────

def sdkconfig_values():
    values = {}
    with open(SDKCONFIG) as f:
        for line in f:
            m = re.match(r'(CONFIG_\w+)=(.*)', line.strip())
            if m:
                v = m.group(2)
                values[m.group(1)] = '1' if v == 'y' else v
    return values


def idf_path():
    """$IDF_PATH, else the ESP-IDF the firmware was last built with."""
    if os.environ.get('IDF_PATH'):
        return os.environ['IDF_PATH']
    try:
        with open(os.path.join(BUILD, 'project_description.json')) as f:
            return json.load(f)['idf_path']
    except (OSError, KeyError, ValueError):
        sys.exit('storage_image: ESP-IDF not found; build the firmware first '
                 '(make fw) or set IDF_PATH')


def idf_python():
    """The ESP-IDF Python the firmware was last built with (it has esptool)."""
    try:
        with open(os.path.join(BUILD, 'CMakeCache.txt')) as f:
            for line in f:
                m = re.match(r'PYTHON(?::\w+)?=(.+)', line.strip())
                if m:
                    return m.group(1)
    except OSError:
        pass
    sys.exit('storage_image: ESP-IDF Python not found; build the firmware '
             'first (make fw)')


def parttool(*args):
    cmd = [idf_python(), os.path.join(idf_path(), 'components', 'partition_table',
                                      'parttool.py')]
    if os.environ.get('ESPPORT'):
        cmd += ['--port', os.environ['ESPPORT']]
    subprocess.run(cmd + list(args), check=True)


def build_fatimage(workdir):
    src = os.path.join(idf_path(), 'components', 'fatfs', 'src')
    if not os.path.isfile(os.path.join(src, 'ff.c')):
        sys.exit(f'storage_image: no FatFs sources in {src}')
    # ESP-IDF's ffconf.h, with the app's sdkconfig in place of sdkconfig.h
    # and no FreeRTOS: the same configuration the firmware compiles.
    with open(os.path.join(src, 'ffconf.h')) as f:
        conf = f.read()
    cfg = sdkconfig_values()
    used = sorted(set(re.findall(r'CONFIG_\w+', conf)))
    defs = ''.join(f'#define {n} {cfg[n]}\n' if n in cfg else f'#define {n} 0\n'
                   for n in used if n in cfg or not re.search(rf'defined\({n}\)|ifdef {n}', conf))
    conf = conf.replace('#include "sdkconfig.h"', defs)
    conf = conf.replace('#include "freertos/FreeRTOS.h"', '#define portTICK_PERIOD_MS 1')
    conf = conf.replace('#include "freertos/semphr.h"', '')
    with open(os.path.join(workdir, 'ffconf.h'), 'w') as f:
        f.write(conf)
    # ff.h includes "ffconf.h" from its own folder first, so the sources
    # are compiled from copies next to the generated ffconf.h.
    for name in ('ff.c', 'ff.h', 'ffunicode.c', 'diskio.h'):
        shutil.copy(os.path.join(src, name), workdir)
    exe = os.path.join(workdir, 'fatimage')
    cc = os.environ.get('CC', 'cc')
    subprocess.run([cc, '-O2', '-w', '-I', workdir, '-o', exe,
                    os.path.join(HERE, 'fatimage.c'),
                    os.path.join(workdir, 'ff.c'), os.path.join(workdir, 'ffunicode.c')],
                   check=True)
    return exe


# ── pack ───────────────────────────────────────────────────────────────

def wl_state(lay):
    header = struct.pack('<8I28x', 0, lay.max_pos, 0, 0, WL_UPDATE_RATE, PAGE,
                         WL_VERSION, DEVICE_ID)
    header += struct.pack('<I', crc32(header))
    return header.ljust(lay.state_bytes, b'\xff')


def wl_config(lay):
    data = struct.pack('<8I', 0, lay.size, PAGE, PAGE, WL_UPDATE_RATE,
                       WL_WR_SIZE, WL_VERSION, WL_TEMP_BUFF)
    data += struct.pack('<I12x', crc32(data))
    return data.ljust(PAGE, b'\xff')


def pack(folder, image):
    lay = Layout(partition_size())
    with tempfile.TemporaryDirectory() as work:
        exe = build_fatimage(work)
        fat_img = os.path.join(work, 'fat.img')
        sectors = lay.fat_pages * PAGE // FAT_SECTOR
        subprocess.run([exe, 'pack', fat_img, str(sectors), folder], check=True)
        with open(fat_img, 'rb') as f:
            fat = f.read()
    logical = fat + b'\xff' * (SAFE_PAGES * PAGE)
    # A fresh state: dummy page at 0, nothing moved, so logical page n
    # sits at physical page n + 1.
    out = b'\xff' * PAGE + logical + wl_state(lay) + wl_state(lay) + wl_config(lay)
    assert len(out) == lay.size
    with open(image, 'wb') as f:
        f.write(out)
    print(f'{image}: {folder} packed into {lay.size} bytes '
          f'({lay.fat_pages * PAGE} bytes of FAT)')


# ── unpack ─────────────────────────────────────────────────────────────

def read_state(img, lay):
    """The valid state copy's move count, and the dummy position its
    records give (WL_Flash::recoverPos)."""
    for addr in (lay.addr_state1, lay.addr_state2):
        header = img[addr:addr + STATE_HEADER]
        fields = struct.unpack('<8I28xI', header)
        if crc32(header[:STATE_HEADER - 4]) != fields[8]:
            continue
        move_count, max_pos = fields[2], fields[1]
        pos = 0
        while pos < max_pos:
            rec = img[addr + STATE_HEADER + pos * STATE_RECORD:][:STATE_RECORD]
            if rec == b'\xff' * STATE_RECORD:
                break
            pos += 1
        if pos == max_pos and pos != 0:
            pos -= 1
        return pos, move_count
    sys.exit('storage_image: no valid wear-levelling state in the image')


def replaceable(folder):
    """Missing, empty, or a previous storage copy."""
    if not os.path.exists(folder):
        return True
    if not os.path.isdir(folder):
        return False
    entries = os.listdir(folder)
    return not entries or 'system.toml' in entries or 'Presets' in entries


def unpack(image, folder):
    if not replaceable(folder):
        sys.exit(f'storage_image: {folder} is not empty and holds no storage copy '
                 '(system.toml or Presets); not replacing it')
    with open(image, 'rb') as f:
        img = f.read()
    lay = Layout(len(img))
    pos, move_count = read_state(img, lay)
    fat = b''.join(img[lay.physical(p, pos, move_count) * PAGE:][:PAGE]
                   for p in range(lay.fat_pages))
    with tempfile.TemporaryDirectory() as work:
        exe = build_fatimage(work)
        fat_img = os.path.join(work, 'fat.img')
        with open(fat_img, 'wb') as f:
            f.write(fat)
        out = os.path.join(work, 'out')
        subprocess.run([exe, 'unpack', fat_img, out], check=True)
        # Replace, not merge: files deleted on the synth must not survive
        # in the folder.
        if os.path.exists(folder):
            shutil.rmtree(folder)
        shutil.move(out, folder)
    print(f'{folder}: replaced with the contents of {image}')


# ── read / write: the synth over serial ──────────────────────────────

def read(folder):
    if not replaceable(folder):
        sys.exit(f'storage_image: {folder} is not empty and holds no storage copy '
                 '(system.toml or Presets); not replacing it')
    with tempfile.TemporaryDirectory() as work:
        image = os.path.join(work, 'storage.img')
        parttool('read_partition', '--partition-name', 'storage', '--output', image)
        unpack(image, folder)


def write(folder):
    with tempfile.TemporaryDirectory() as work:
        image = os.path.join(work, 'storage.img')
        pack(folder, image)
        parttool('write_partition', '--partition-name', 'storage', '--input', image)


def main():
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == 'pack':
        pack(args[1], args[2])
    elif len(args) == 3 and args[0] == 'unpack':
        unpack(args[1], args[2])
    elif len(args) == 2 and args[0] == 'read':
        read(args[1])
    elif len(args) == 2 and args[0] == 'write':
        write(args[1])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
