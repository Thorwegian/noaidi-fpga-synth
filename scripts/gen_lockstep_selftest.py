#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# The boot self-test as a SystemVerilog task for the lockstep bench
# (rtl/tb/lock/tb_lock.sv): the program, its constants and the LFOs'
# configuration, as engine_selftest.cpp writes them.
#
#   gen_lockstep_selftest.py selftest_program.hpp selftest.svh
import re
import sys

header, out = sys.argv[1:3]
text = open(header).read()
words = [int(x, 16) for x in re.findall(r'0x([0-9a-f]{9})ull', text)]
constants = re.findall(r'Constant\{0x([0-9a-f]+), (-?\d+)\}', text)
symbol = {n: int(v) for n, v in re.findall(r'constexpr int (\w+) = (-?\d+);', text)}

ONE = 0x4000
lines = ['task automatic load_selftest;', '    held = 1;']
for pc, word in enumerate(words):
    lines.append(f"    imem_write({pc}, 36'h{word:09x});")
for address, raw in constants:
    lines.append(f"    queue_put({int(address, 16)}, {int(raw) & 0x3ffff});")
# Every shape in both halves, one record each, so that the vector loops run
# one after the other as they do in the control program (lfo.s).
shapes = ['n_saw', 'n_square', 'n_triangle', 'n_sine']
for half in range(2):
    first = symbol['lfos'] + half * 16 * symbol['lfo_size']
    lfo_set = symbol['lfo_sets'] + half * symbol['set_size']
    step = 350 * 2 * 2 * (1 << 11)  # csp::lfo_rate(350, 2)
    lines.append(f"    queue_put({lfo_set + symbol['base']}, {first});")
    for index, shape in enumerate(shapes):
        record = first + index * symbol['lfo_size']
        lines.append(f"    queue_put({record + symbol['phase_step']}, {(step >> 18) & 0x3ffff});")
        lines.append(f"    queue_put({record + symbol['phase_step'] + 1}, {step & 0x3ffff});")
        lines.append(f"    queue_put({record + symbol['depth']}, {ONE});")
        lines.append(f"    queue_put({record + symbol['neg_depth']}, {-ONE & 0x3ffff});")
        lines.append(f"    queue_put({record + symbol['gain']}, {ONE // 4 if half == 0 else ONE // 8});")
        lines.append(f"    queue_put({lfo_set + symbol[shape]}, 1);")
lines += ['    queue_swap;', 'endtask']
open(out, 'w').write('\n'.join(lines) + '\n')
