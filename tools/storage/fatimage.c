// fatimage.c — build and read the storage partition's FAT image on a
// computer, with the same FatFs library the firmware uses
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// ESP-IDF's own image generator upper-cases paths and lower-cases long
// names, so "Arctic Ice.toml" would not survive. This tool runs ESP-IDF's
// FatFs (components/fatfs/src) against a RAM disk instead, so names,
// letter case and UTF-8 come out exactly as the firmware writes them.
// It handles the plain FAT image only; storage_image.py adds and
// removes the wear-levelling layer.
//
//   fatimage pack   <image> <sectors> <folder>   format, then copy folder in
//   fatimage unpack <image> <folder>             copy the image's tree out
//
// Sectors are 512 bytes, one sector per cluster, as on the device.

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

// FatFs and POSIX both name their directory type DIR.
#define DIR FF_DIR
#include "ff.h"
#include "diskio.h"
#undef DIR

#define SECTOR_SIZE 512

static BYTE *s_disk;
static LBA_t s_sectors;

// ── RAM disk ────────────────────────────────────────────────────────
DSTATUS disk_initialize(BYTE pdrv) {
    (void) pdrv;
    return 0;
}
DSTATUS disk_status(BYTE pdrv) {
    (void) pdrv;
    return 0;
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count) {
    (void) pdrv;
    if (sector + count > s_sectors) {
        return RES_PARERR;
    }
    memcpy(buff, s_disk + (size_t) sector * SECTOR_SIZE,
           (size_t) count * SECTOR_SIZE);
    return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count) {
    (void) pdrv;
    if (sector + count > s_sectors) {
        return RES_PARERR;
    }
    memcpy(s_disk + (size_t) sector * SECTOR_SIZE, buff,
           (size_t) count * SECTOR_SIZE);
    return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff) {
    (void) pdrv;
    switch (cmd) {
    case CTRL_SYNC:
        return RES_OK;
    case GET_SECTOR_COUNT:
        *(LBA_t *) buff = s_sectors;
        return RES_OK;
    case GET_SECTOR_SIZE:
        *(WORD *) buff = SECTOR_SIZE;
        return RES_OK;
    case GET_BLOCK_SIZE:
        *(DWORD *) buff = 1;
        return RES_OK;
    case CTRL_TRIM:
        return RES_OK;
    default:
        return RES_PARERR;
    }
}

// ESP-IDF builds FatFs with FF_MULTI_PARTITION: every volume is the RAM
// disk, partition 0 = auto-detect (an unpartitioned FAT volume here).
#if FF_MULTI_PARTITION
PARTITION VolToPart[FF_VOLUMES];
#endif

// FatFs's OS hooks: one thread, plain malloc, a fixed timestamp so the
// same folder always packs to the same image.
void *ff_memalloc(unsigned msize) {
    return malloc(msize);
}
void ff_memfree(void *mblock) {
    free(mblock);
}
int ff_mutex_create(int vol) {
    (void) vol;
    return 1;
}
void ff_mutex_delete(int vol) {
    (void) vol;
}
int ff_mutex_take(int vol) {
    (void) vol;
    return 1;
}
void ff_mutex_give(int vol) {
    (void) vol;
}
DWORD get_fattime(void) {
    return ((DWORD) (2026 - 1980) << 25) | (1u << 21) | (1u << 16);
}

static void fail_ff(const char *what, const char *path, FRESULT fr) {
    fprintf(stderr, "fatimage: %s \"%s\": FatFs error %d\n", what, path,
            (int) fr);
    exit(1);
}

static void fail_os(const char *path) {
    fprintf(stderr, "fatimage: %s: %s\n", path, strerror(errno));
    exit(1);
}

// ── pack: folder -> image ───────────────────────────────────────────
static void pack_dir(const char *host, const char *fat) {
    DIR *d = opendir(host);
    if (!d) {
        fail_os(host);
    }
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') {
            continue; // ., .., .DS_Store
        }
        char hp[1024], fp[1024];
        snprintf(hp, sizeof hp, "%s/%s", host, e->d_name);
        snprintf(fp, sizeof fp, "%s/%s", fat, e->d_name);
        struct stat st;
        if (stat(hp, &st) != 0) {
            fail_os(hp);
        }
        if (S_ISDIR(st.st_mode)) {
            FRESULT fr = f_mkdir(fp);
            if (fr != FR_OK && fr != FR_EXIST) {
                fail_ff("mkdir", fp, fr);
            }
            pack_dir(hp, fp);
        } else if (S_ISREG(st.st_mode)) {
            FILE *in = fopen(hp, "rb");
            if (!in) {
                fail_os(hp);
            }
            FIL f      = {0}; // ESP-IDF's dynamic buffers start out NULL
            FRESULT fr = f_open(&f, fp, FA_WRITE | FA_CREATE_ALWAYS);
            if (fr != FR_OK) {
                fail_ff("create", fp, fr);
            }
            char buf[4096];
            size_t n;
            while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
                UINT bw;
                fr = f_write(&f, buf, (UINT) n, &bw);
                if (fr == FR_OK && bw != n) {
                    fr = FR_DENIED; // disk full
                }
                if (fr != FR_OK) {
                    fail_ff("write", fp, fr);
                }
            }
            fclose(in);
            fr = f_close(&f);
            if (fr != FR_OK) {
                fail_ff("close", fp, fr);
            }
        }
    }
    closedir(d);
}

// ── unpack: image -> folder ─────────────────────────────────────────
static void unpack_dir(const char *fat, const char *host) {
    if (mkdir(host, 0775) != 0 && errno != EEXIST) {
        fail_os(host);
    }
    FF_DIR d   = {0};
    FRESULT fr = f_opendir(&d, fat);
    if (fr != FR_OK) {
        fail_ff("opendir", fat, fr);
    }
    FILINFO fi;
    while ((fr = f_readdir(&d, &fi)) == FR_OK && fi.fname[0]) {
        char hp[1024], fp[1024];
        snprintf(hp, sizeof hp, "%s/%s", host, fi.fname);
        snprintf(fp, sizeof fp, "%s/%s", fat, fi.fname);
        if (fi.fattrib & AM_DIR) {
            unpack_dir(fp, hp);
            continue;
        }
        FIL f = {0};
        fr    = f_open(&f, fp, FA_READ);
        if (fr != FR_OK) {
            fail_ff("open", fp, fr);
        }
        FILE *out = fopen(hp, "wb");
        if (!out) {
            fail_os(hp);
        }
        char buf[4096];
        UINT br;
        while ((fr = f_read(&f, buf, sizeof buf, &br)) == FR_OK && br > 0) {
            if (fwrite(buf, 1, br, out) != br) {
                fail_os(hp);
            }
        }
        if (fr != FR_OK) {
            fail_ff("read", fp, fr);
        }
        fclose(out);
        f_close(&f);
    }
    if (fr != FR_OK) {
        fail_ff("readdir", fat, fr);
    }
    f_closedir(&d);
}

static void usage(void) {
    fprintf(stderr, "usage: fatimage pack <image> <sectors> <folder>\n"
                    "       fatimage unpack <image> <folder>\n");
    exit(2);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage();
    }
    FATFS fs = {0}; // ESP-IDF's dynamic buffers start out NULL
    FRESULT fr;

    if (strcmp(argv[1], "pack") == 0 && argc == 5) {
        s_sectors = (LBA_t) strtoul(argv[3], NULL, 0);
        s_disk    = calloc(s_sectors, SECTOR_SIZE);
        if (!s_disk) {
            fail_os("memory");
        }
        // Two FATs and 512-byte clusters, as storage.c's mount expects.
        static BYTE work[FF_MAX_SS];
        const MKFS_PARM opt = {
                .fmt = FM_FAT | FM_SFD, .n_fat = 2, .au_size = SECTOR_SIZE};
        fr = f_mkfs("", &opt, work, sizeof work);
        if (fr != FR_OK) {
            fail_ff("mkfs", argv[2], fr);
        }
        fr = f_mount(&fs, "", 1);
        if (fr != FR_OK) {
            fail_ff("mount", argv[2], fr);
        }
        pack_dir(argv[4], "");
        f_unmount("");
        FILE *out = fopen(argv[2], "wb");
        if (!out) {
            fail_os(argv[2]);
        }
        if (fwrite(s_disk, SECTOR_SIZE, s_sectors, out) != s_sectors) {
            fail_os(argv[2]);
        }
        fclose(out);
    } else if (strcmp(argv[1], "unpack") == 0 && argc == 4) {
        FILE *in = fopen(argv[2], "rb");
        if (!in) {
            fail_os(argv[2]);
        }
        fseek(in, 0, SEEK_END);
        long size = ftell(in);
        fseek(in, 0, SEEK_SET);
        s_sectors = (LBA_t) (size / SECTOR_SIZE);
        s_disk    = malloc((size_t) size);
        if (!s_disk || fread(s_disk, 1, (size_t) size, in) != (size_t) size) {
            fail_os(argv[2]);
        }
        fclose(in);
        fr = f_mount(&fs, "", 1);
        if (fr != FR_OK) {
            fail_ff("mount", argv[2], fr);
        }
        unpack_dir("", argv[3]);
        f_unmount("");
    } else {
        usage();
    }
    return 0;
}
