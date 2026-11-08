// cli_csp.cpp — the serial console's `csp` command: the lab's view of the CSP
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One command, `csp <op> ...`, so that `help` shows a player one line for the
// lab's instruments and `csp help` lists them. Every op is sent by a tool:
// `csp verify`, `csp diag`, `csp peek` and `csp voices` by the acceptance,
// the board checks and the soak (tools/lab); `csp stream` by the S/PDIF
// capture; `csp hold`, `csp rom`, `csp row`, `csp const`, `csp burst`,
// `csp go` and `csp freeze` by the chip check (`csp script` in tools/csp
// prints them, tools/lab/chip_check.py sends them). An op nothing sends is
// not kept here.

#include "cli.h"

#include <cstdint>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "console.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "engine_link.h"
#include "fpga_map.hpp"
#include "spi_link.hpp"
#include "voice_alloc.h"

namespace {

int signed_word(uint64_t raw18) {
    const int word = static_cast<int>(raw18 & 0x3FFFF);
    return word >= (1 << 17) ? word - (1 << 18) : word;
}

// Each op runs with argv[0] its own name, as a command of its own would.

// csp peek reads CSP registers through the gateware's register probe
// (docs/memory_map.md), a pair a line.
int op_peek(int argc, char **argv) {
    if (argc < 2) {
        std::printf("usage: csp peek <register> [count]   (decimal or 0x..)\n");
        return 1;
    }
    const int first = static_cast<int>(std::strtol(argv[1], nullptr, 0)) & ~1;
    const int count =
            argc > 2 ? static_cast<int>(std::strtol(argv[2], nullptr, 0)) : 2;
    for (int at = first; at < first + count; at += 2) {
        uint64_t pair = 0;
        if (!engine_link_peek(at, &pair)) {
            std::printf("  the link is not running\n");
            return 1;
        }
        const unsigned even = static_cast<unsigned>(pair >> 18) & 0x3FFFF;
        const unsigned odd  = static_cast<unsigned>(pair) & 0x3FFFF;
        std::printf("  %03x: %05x (%d)   %03x: %05x (%d)   wide %09llx\n", at,
                    even, signed_word(even), at + 1, odd, signed_word(odd),
                    static_cast<unsigned long long>(pair));
    }
    return 0;
}

// Every register the image knows, read back through the probe: how many
// differ from the image, and the first of them. A sounding voice's levels
// and stages differ legitimately (the CSP writes them); verify a silent synth.
int op_verify(int, char **) {
    constexpr int limit = 24;
    int registers[limit];
    int32_t wanted[limit], held[limit];
    const int differing = engine_link_verify(registers, wanted, held, limit);
    if (differing < 0) {
        std::printf("  the link is not running\n");
        return 1;
    }
    for (int i = 0; i < differing && i < limit; ++i) {
        std::printf("  %03x: image %05lx (%ld), chip %05lx (%ld)\n",
                    registers[i], static_cast<unsigned long>(wanted[i]),
                    static_cast<long>(signed_word(wanted[i])),
                    static_cast<unsigned long>(held[i]),
                    static_cast<long>(signed_word(held[i])));
    }
    std::printf("  verified: %d register(s) differ from the image\n",
                differing);
    return differing ? 1 : 0;
}

int op_diag(int, char **) {
    uint64_t dwords[fpga_map::diag_words] = {};
    if (!engine_link_raw_read(fpga_map::diag_pass, dwords,
                              fpga_map::diag_words)) {
        std::printf("  the link answers no ID nonet\n");
        return 1;
    }
    std::printf(
            "  passes %lu  queue %llx  limiter %llx  dropped %lu  stream frames %lu\n",
            static_cast<unsigned long>(engine_link_status(fpga_map::diag_pass)),
            static_cast<unsigned long long>(dwords[1]),
            static_cast<unsigned long long>(dwords[2]),
            static_cast<unsigned long>(dwords[3] & 0xFFFF),
            static_cast<unsigned long>(
                    engine_link_status(fpga_map::diag_stream)));
    return 0;
}

// The voice table, live (#238): the firmware's view of each sounding voice —
// a stuck note shows as HELD (or sustained) that the player has let go. Read
// alongside csp peek of the voice's stage words (0x600 + 16*v + 2 and + 10;
// 8 and 24 are release) to see whether the release never issued (firmware
// bug) or issued but did not land (link).
int op_voices(int, char **) {
    voice_diag_t v[32];
    const int n                           = voice_alloc_diag(v, 32);
    static const char *const state_name[] = {"idle", "HELD", "releasing"};
    std::printf("  sustain pedal: %s\n",
                voice_alloc_sustain_pedal() ? "DOWN" : "up");
    std::printf("   v  state      note  vel  sustained  seq\n");
    int shown = 0;
    for (int i = 0; i < n; ++i) {
        if (v[i].state == 0) {
            continue; // idle voices omitted — only what is (or should not be) sounding
        }
        ++shown;
        std::printf("  %2d  %-9s  %3d  %3d  %-9s  %lu\n", i,
                    v[i].state <= 2 ? state_name[v[i].state] : "?", v[i].note,
                    v[i].vel, v[i].sustained ? "yes" : "no",
                    static_cast<unsigned long>(v[i].alloc_seq));
    }
    if (shown == 0) {
        std::printf("  (all 32 voices idle)\n");
    }
    return 0;
}

// A lab on the board: csp hold (stop the tick, hold the CSP, clear its program),
// csp row, csp rom and csp const (load), csp go (release it). Then csp peek.
// What the lab has loaded since csp hold, to check against the host's list.
unsigned s_words_written;
unsigned s_checksum;

int op_hold(int, char **) {
    s_words_written = 0;
    s_checksum      = 0;
    engine_link_pause(true);
    engine_link_raw_write(fpga_map::ctrl, fpga_map::ctrl_hold);
    engine_link_raw_write(fpga_map::ctrl,
                          fpga_map::ctrl_hold | fpga_map::ctrl_swap);
    vTaskDelay(pdMS_TO_TICKS(10));
    // every program row, not the last: that is the fetch's park row while
    // the CSP is held, and a write would meet the fetch on it (the row rule;
    // a program ends with END and never reaches it, #271)
    for (size_t pc = 0; pc + 1 < fpga_map::program_rows; ++pc) {
        const uint64_t row[2] = {0, 0};
        engine_link_raw_write_burst(fpga_map::program_base
                                            + 2 * static_cast<uint32_t>(pc),
                                    row, 2, true);
    }
    for (size_t row = 0; row < fpga_map::rom_rows; ++row) {
        engine_link_raw_write(fpga_map::rom_base + static_cast<uint32_t>(row),
                              0);
    }
    std::printf("  held, program and decode ROM cleared, tick paused\n");
    return 0;
}

// csp row writes one instruction row, a qword: two dwords, bits 71:36 then 35:0,
// at the row's place in IMEM. The CSP must be held (csp hold).
int op_row(int argc, char **argv) {
    if (argc != 4) {
        std::printf("usage: csp row <pc> <bits 71:36 hex> <bits 35:0 hex>\n");
        return 1;
    }
    const unsigned pc =
            static_cast<unsigned>(std::strtoul(argv[1], nullptr, 0));
    const uint64_t row[2] = {
            std::strtoull(argv[2], nullptr, 16) & spi_link::dword_mask,
            std::strtoull(argv[3], nullptr, 16) & spi_link::dword_mask};
    if (pc + 1 >= fpga_map::
                program_rows) { // the last row is the fetch's park, never a program's
        std::printf("  a program has at most %u rows\n",
                    static_cast<unsigned>(fpga_map::program_rows - 1));
        return 1;
    }
    engine_link_raw_write_burst(fpga_map::program_base + 2 * pc, row, 2, true);
    ++s_words_written;
    s_checksum = s_checksum * 31u + pc * 7u + static_cast<unsigned>(row[0])
                 + static_cast<unsigned>(row[1]);
    return 0;
}

// csp rom writes one row of the decode ROM: a control word. The CSP must be held.
int op_rom(int argc, char **argv) {
    if (argc != 3) {
        std::printf("usage: csp rom <row> <control word hex>\n");
        return 1;
    }
    const unsigned row =
            static_cast<unsigned>(std::strtoul(argv[1], nullptr, 0));
    const uint64_t word = std::strtoull(argv[2], nullptr, 16) & 0x3FFFF;
    if (row >= fpga_map::rom_rows) {
        std::printf("  the decode ROM has %u rows\n",
                    static_cast<unsigned>(fpga_map::rom_rows));
        return 1;
    }
    engine_link_raw_write(fpga_map::rom_base + row, word);
    s_checksum = s_checksum * 31u + row * 11u + static_cast<unsigned>(word);
    return 0;
}

int op_const(int argc, char **argv) {
    if (argc != 3) {
        std::printf("usage: csp const <register> <raw>\n");
        return 1;
    }
    const unsigned address =
            static_cast<unsigned>(std::strtoul(argv[1], nullptr, 0));
    const int raw = static_cast<int>(std::strtol(argv[2], nullptr, 0));
    engine_link_raw_write(fpga_map::fifo_door,
                          fpga_map::fifo_dword(static_cast<int>(address),
                                               static_cast<uint32_t>(raw)));
    ++s_words_written;
    s_checksum = s_checksum * 31u + address * 5u
                 + (static_cast<unsigned>(raw) & 0x3FFFFu);
    return 0;
}

// csp burst <first register> <count> <seed>: the registers' test values
// (register × 37 + seed) through the write queue, in bursts of up to 8
// consecutive dwords and committed a chunk at a time, as the engine loads the
// boot image: the window applies only committed dwords, the queue holds 511
// of them, and a held CSP applies a committed chunk within a few passes.
int op_burst(int argc, char **argv) {
    if (argc != 4) {
        std::printf("usage: csp burst <first register> <count> <seed>\n");
        return 1;
    }
    const unsigned first =
            static_cast<unsigned>(std::strtoul(argv[1], nullptr, 0));
    const unsigned count =
            static_cast<unsigned>(std::strtoul(argv[2], nullptr, 0));
    const unsigned seed =
            static_cast<unsigned>(std::strtoul(argv[3], nullptr, 0));
    constexpr unsigned burst_dwords = 8;
    constexpr unsigned chunk_dwords =
            static_cast<unsigned>(fpga_map::queue_depth / 2);
    unsigned since_commit = 0;
    for (unsigned at = 0; at < count; at += burst_dwords) {
        uint64_t dwords[burst_dwords];
        const unsigned n = std::min(burst_dwords, count - at);
        for (unsigned k = 0; k < n; ++k) {
            const unsigned address = first + at + k;
            dwords[k] = fpga_map::fifo_dword(static_cast<int>(address),
                                             (address * 37u + seed) & 0x1FFFFu);
        }
        engine_link_raw_write_burst(fpga_map::fifo_door, dwords,
                                    static_cast<int>(n), false);
        since_commit += n;
        if (since_commit >= chunk_dwords || at + n == count) {
            engine_link_raw_write(fpga_map::ctrl,
                                  fpga_map::ctrl_hold | fpga_map::ctrl_swap);
            vTaskDelay(pdMS_TO_TICKS(2));
            since_commit = 0;
        }
    }
    std::printf("  queued %u words, committed %u a chunk\n", count,
                chunk_dwords);
    return 0;
}

int op_go(int, char **) {
    engine_link_raw_write(fpga_map::ctrl,
                          fpga_map::ctrl_hold | fpga_map::ctrl_swap);
    vTaskDelay(pdMS_TO_TICKS(5));
    engine_link_raw_write(fpga_map::ctrl, 0);
    std::printf("  running; loaded %u words, checksum %08x\n", s_words_written,
                s_checksum);
    return 0;
}

// csp stream off | lfsr | counter | probe | engine | dump: the data stream on
// the 48 kHz S/PDIF output, the pipe tools/lab/spdif_capture.py checks bit
// for bit.
int op_stream(int argc, char **argv) {
    if (argc != 2) {
        std::printf("usage: csp stream off|lfsr|counter|probe|engine|dump\n");
        return 1;
    }
    const char *what = argv[1];
    if (std::strcmp(what, "off") == 0) {
        engine_link_data_stream(false, 0);
    } else if (std::strcmp(what, "lfsr") == 0) {
        engine_link_data_stream(true,
                                static_cast<int>(fpga_map::stream_source_lfsr));
    } else if (std::strcmp(what, "counter") == 0) {
        engine_link_data_stream(
                true, static_cast<int>(fpga_map::stream_source_counter));
    } else if (std::strcmp(what, "probe") == 0) {
        engine_link_data_stream(
                true, static_cast<int>(fpga_map::stream_source_probe));
    } else if (std::strcmp(what, "engine") == 0) {
        // the debug port: the sink word at the probe address's low ten bits
        // and the mix, a sample at a time
        engine_link_data_stream(
                true, static_cast<int>(fpga_map::stream_source_engine));
    } else if (std::strcmp(what, "dump") == 0) {
        // the register file over the pipe: a register a pass, its index and its word, the whole
        // file in 43 ms (tools/lab/spdif_capture.py stream --dump, chip_check.py --stream)
        engine_link_data_stream(true,
                                static_cast<int>(fpga_map::stream_source_dump));
    } else {
        std::printf("usage: csp stream off|lfsr|counter|probe|engine|dump\n");
        return 1;
    }
    std::printf("  stream %s\n", what);
    return 0;
}

// csp freeze stops the tick and holds the CSP with its program in place, so
// that the chip check reads a register file nothing is writing; csp go
// releases it again.
int op_freeze(int, char **) {
    engine_link_pause(true);
    engine_link_raw_write(fpga_map::ctrl, fpga_map::ctrl_hold);
    vTaskDelay(pdMS_TO_TICKS(10)); // a pass in flight finishes
    std::printf("  frozen\n");
    return 0;
}

struct Op {
    const char *name;
    const char *usage;
    const char *help;
    int (*run)(int argc, char **argv);
};

const Op ops[] = {
        {"diag", "", "the gateware's diagnostic words", op_diag},
        {"verify", "",
         "read every register the image knows back and count the differences",
         op_verify},
        {"voices", "",
         "the firmware's voice table, live (a stuck note shows as HELD, #238)",
         op_voices},
        {"peek", "<register> [count]",
         "read CSP registers (even-aligned pairs)", op_peek},
        {"stream", "off|lfsr|counter|probe|engine|dump",
         "the data stream on the 48 kHz S/PDIF output", op_stream},
        {"freeze", "", "hold the CSP (its program stays) and pause the tick",
         op_freeze},
        {"hold", "", "pause the tick, hold the CSP, clear its program",
         op_hold},
        {"row", "<pc> <hi hex> <lo hex>",
         "write an instruction row (bits 71:36, 35:0)", op_row},
        {"rom", "<row> <hex>", "write a decode ROM row", op_rom},
        {"const", "<register> <raw>", "write a register (applies on csp go)",
         op_const},
        {"burst", "<register> <count> <seed>",
         "test values through the queue, committed a chunk at a time, as the engine does",
         op_burst},
        {"go", "", "commit the writes and release the CSP", op_go},
};

void list_ops() {
    for (const Op &op : ops) {
        std::printf("  csp %-7s %-36s %s\n", op.name, op.usage, op.help);
    }
}

int cmd_csp(int argc, char **argv) {
    if (argc < 2) {
        std::printf("usage: csp <op> ...\n");
        list_ops();
        return 1;
    }
    if (std::strcmp(argv[1], "help") == 0) {
        list_ops();
        return 0;
    }
    for (const Op &op : ops) {
        if (std::strcmp(op.name, argv[1]) == 0) {
            return op.run(argc - 1, argv + 1);
        }
    }
    std::printf("csp: no op \"%s\"; try csp help\n", argv[1]);
    return 1;
}

void complete_csp(int argi, const char *prefix, void (*add)(const char *)) {
    if (argi != 1) {
        return;
    }
    const size_t length = std::strlen(prefix);
    for (const Op &op : ops) {
        if (std::strncmp(op.name, prefix, length) == 0) {
            add(op.name);
        }
    }
}

const console_cmd_t command = {"csp", "<op> ...",
                               "lab: the CSP's instruments (csp help)", cmd_csp,
                               complete_csp};

} // namespace

extern "C" void cli_csp_init(void) {
    console_register(&command);
}
