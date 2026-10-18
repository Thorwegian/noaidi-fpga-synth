// cli_csp.cpp — the serial console's commands for the CSP
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// csp-peek reads CSP registers through the gateware's register probe
// (docs/memory_map.md), csp-poke queues a write to one, csp-diag reads the
// gateware's diagnostic words. For looking at a board that does not do what
// the simulation says.

#include "cli.h"

#include <cstdint>
#include <algorithm>
#include <cstdio>
#include <cstdlib>

#include "console.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "engine_link.h"
#include "fpga_map.hpp"
#include "spi_regs.h"

namespace {

int signed_word(uint64_t raw18) {
    const int word = static_cast<int>(raw18 & 0x3FFFF);
    return word >= (1 << 17) ? word - (1 << 18) : word;
}

int cmd_peek(int argc, char **argv) {
    if (argc < 2) {
        std::printf("usage: csp-peek <register> [count]   (decimal or 0x..)\n");
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

int cmd_poke(int argc, char **argv) {
    if (argc < 3 || argc > 4) {
        std::printf("usage: csp-poke <register> <raw> [force]\n");
        return 1;
    }
    const int address = static_cast<int>(std::strtol(argv[1], nullptr, 0));
    const int raw     = static_cast<int>(std::strtol(argv[2], nullptr, 0));
    // The image drops a write of the value it believes the chip holds;
    // `force` sends it anyway, for a chip whose copy is in doubt.
    const bool force = argc == 4;
    if (!(force ? engine_link_write_forced(address, raw)
                : engine_link_write(address, raw))) {
        std::printf("  refused\n");
        return 1;
    }
    std::printf("  queued %03x <- %d%s\n", address, raw, force ? " (forced)" : "");
    return 0;
}

// Every register the image knows, read back through the probe: how many
// differ from the image, and the first of them. A sounding voice's levels
// and stages differ legitimately (the CSP writes them); verify a silent synth.
int cmd_verify(int, char **) {
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
    std::printf("  verified: %d register(s) differ from the image\n", differing);
    return differing ? 1 : 0;
}

// The whole image sent again, over the next ticks.
int cmd_resend(int, char **) {
    engine_link_resend();
    std::printf("  every known word queued again\n");
    return 0;
}

int cmd_diag(int, char **) {
    uint32_t words[fpga_map::diag_words] = {};
    if (!fpga_word_read_burst(fpga_map::diag_pass, words,
                              fpga_map::diag_words)) {
        std::printf("  the link answers no ID byte\n");
        return 1;
    }
    std::printf("  passes %lu  queue %lx  limiter %lx  dropped %lu\n",
                static_cast<unsigned long>(words[0] & 0x3FFFF),
                static_cast<unsigned long>(words[1]),
                static_cast<unsigned long>(words[2]),
                static_cast<unsigned long>(words[3] & 0xFFFF));
    return 0;
}

int cmd_selftest(int argc, char **argv) {
    const bool leave_running = argc > 1;
    std::printf(
            "  the CSP's program is replaced by the self-test's%s; reboot to restore\n",
            leave_running ? ", left running" : "");
    std::printf("  %s\n",
                engine_link_selftest(leave_running) ? "passed" : "FAILED");
    return 0;
}

// A lab on the board: csp-hold (stop the tick, hold the CSP, clear its program),
// csp-word and csp-const (load), csp-go (release it). Then csp-peek.
// What the lab has loaded since csp-hold, to check against the host's list.
unsigned s_words_written;
unsigned s_checksum;

int cmd_hold(int, char **) {
    s_words_written = 0;
    s_checksum      = 0;
    engine_link_pause(true);
    engine_link_raw_write(fpga_map::ctrl, fpga_map::ctrl_hold);
    engine_link_raw_write(fpga_map::ctrl,
                          fpga_map::ctrl_hold | fpga_map::ctrl_swap);
    vTaskDelay(pdMS_TO_TICKS(10));
    engine_link_raw_write(fpga_map::program_high, 0);
    for (size_t pc = 0; pc < fpga_map::program_words; ++pc) {
        engine_link_raw_write(
                static_cast<uint16_t>(fpga_map::program_base + pc), 0);
    }
    std::printf("  held, program cleared, tick paused\n");
    return 0;
}

int cmd_word(int argc, char **argv) {
    if (argc != 3) {
        std::printf("usage: csp-word <pc> <36-bit hex>\n");
        return 1;
    }
    const unsigned pc =
            static_cast<unsigned>(std::strtoul(argv[1], nullptr, 0));
    const uint64_t word = std::strtoull(argv[2], nullptr, 16);
    engine_link_raw_write(fpga_map::program_high,
                          static_cast<uint32_t>(word >> 32));
    engine_link_raw_write(static_cast<uint16_t>(fpga_map::program_base + pc),
                          static_cast<uint32_t>(word));
    ++s_words_written;
    s_checksum = s_checksum * 31u + static_cast<unsigned>(pc) * 7u
                 + static_cast<unsigned>(word)
                 + static_cast<unsigned>(word >> 32);
    return 0;
}

int cmd_const(int argc, char **argv) {
    if (argc != 3) {
        std::printf("usage: csp-const <register> <raw>\n");
        return 1;
    }
    const unsigned address =
            static_cast<unsigned>(std::strtoul(argv[1], nullptr, 0));
    const int raw = static_cast<int>(std::strtol(argv[2], nullptr, 0));
    engine_link_raw_write(static_cast<uint16_t>(fpga_map::queue_base + address),
                          static_cast<uint32_t>(raw) & 0x3FFFF);
    ++s_words_written;
    s_checksum = s_checksum * 31u + address * 5u
                 + (static_cast<unsigned>(raw) & 0x3FFFFu);
    return 0;
}

// csp-burst <first register> <count> <seed>: queue the registers' test values
// (register × 37 + seed) as the engine does, in bursts of up to 8 consecutive
// words (applies on csp-go).
int cmd_burst(int argc, char **argv) {
    if (argc != 4) {
        std::printf("usage: csp-burst <first register> <count> <seed>\n");
        return 1;
    }
    const unsigned first = static_cast<unsigned>(std::strtoul(argv[1], nullptr, 0));
    const unsigned count = static_cast<unsigned>(std::strtoul(argv[2], nullptr, 0));
    const unsigned seed  = static_cast<unsigned>(std::strtoul(argv[3], nullptr, 0));
    constexpr unsigned burst_words = 8;
    for (unsigned at = 0; at < count; at += burst_words) {
        uint32_t words[burst_words];
        const unsigned n = std::min(burst_words, count - at);
        for (unsigned k = 0; k < n; ++k) {
            words[k] = ((first + at + k) * 37u + seed) & 0x1FFFFu;
        }
        engine_link_raw_write_burst(
                static_cast<uint16_t>(fpga_map::queue_base + first + at), words,
                static_cast<int>(n));
    }
    std::printf("  queued %u words in bursts\n", count);
    return 0;
}

int cmd_go(int, char **) {
    engine_link_raw_write(fpga_map::ctrl,
                          fpga_map::ctrl_hold | fpga_map::ctrl_swap);
    vTaskDelay(pdMS_TO_TICKS(5));
    engine_link_raw_write(fpga_map::ctrl, 0);
    std::printf("  running; loaded %u words, checksum %08x\n", s_words_written,
                s_checksum);
    return 0;
}

// Does the SPI link carry what it is given? Random words to the scratch
// registers and back, N rounds.
int cmd_spitest(int argc, char **argv) {
    const int rounds =
            argc > 1 ? static_cast<int>(std::strtol(argv[1], nullptr, 0))
                     : 1000;
    uint32_t state = 0x12345678;
    int single_bad = 0, burst_bad = 0;
    for (int round = 0; round < rounds; ++round) {
        uint32_t words[5];
        for (uint32_t &word : words) {
            state = state * 1664525u + 1013904223u;
            word  = state;
        }
        for (int k = 0; k < 5; ++k) {
            engine_link_raw_write(static_cast<uint16_t>(3 + k), words[k]);
        }
        for (int k = 0; k < 5; ++k) {
            single_bad +=
                    fpga_word_read(static_cast<uint16_t>(3 + k)) != words[k];
        }
        engine_link_raw_write_burst(3, words, 5);
        uint32_t back[5] = {};
        fpga_word_read_burst(3, back, 5);
        for (int k = 0; k < 5; ++k) {
            burst_bad += back[k] != words[k];
        }
    }
    std::printf("  %d rounds: %d single-word and %d burst mismatches\n", rounds,
                single_bad, burst_bad);
    return 0;
}

// A snapshot of the CSP's registers: csp-freeze (stop the tick, hold the CSP:
// the program stays), csp-dump (every register, one pair a line), csp-thaw.
// tools/lab/snapshot.py takes two snapshots a few passes apart for
// `csp replay` to check the model against.
int cmd_freeze(int, char **) {
    engine_link_pause(true);
    engine_link_raw_write(fpga_map::ctrl, fpga_map::ctrl_hold);
    vTaskDelay(pdMS_TO_TICKS(10)); // a pass in flight finishes
    std::printf("  frozen\n");
    return 0;
}

int cmd_thaw(int, char **) {
    engine_link_raw_write(fpga_map::ctrl, 0);
    std::printf("  thawed\n");
    return 0;
}

int cmd_step(int argc, char **argv) {
    const int milliseconds =
            argc > 1 ? static_cast<int>(std::strtol(argv[1], nullptr, 0)) : 1;
    // The pass counter counts held passes too (and register 0x040 follows it):
    // note where the run began and where it was held again, for `csp replay`.
    const uint32_t first = fpga_word_read(fpga_map::diag_pass);
    engine_link_raw_write(fpga_map::ctrl, 0);
    vTaskDelay(pdMS_TO_TICKS(milliseconds));
    engine_link_raw_write(fpga_map::ctrl, fpga_map::ctrl_hold);
    const uint32_t last = fpga_word_read(fpga_map::diag_pass);
    vTaskDelay(pdMS_TO_TICKS(10));
    std::printf("  stepped %d ms from pass %lu to %lu\n", milliseconds,
                static_cast<unsigned long>(first & 0x3FFFF),
                static_cast<unsigned long>(last & 0x3FFFF));
    return 0;
}

int cmd_dump(int argc, char **argv) {
    const int first =
            argc > 1 ? static_cast<int>(std::strtol(argv[1], nullptr, 0)) & ~1
                     : 0;
    const int count =
            argc > 2 ? static_cast<int>(std::strtol(argv[2], nullptr, 0))
                     : 0x800;
    for (int at = first; at < first + count && at < 0x800; at += 2) {
        uint64_t pair = 0;
        if (!engine_link_peek(at, &pair)) {
            std::printf("  the link is not running\n");
            return 1;
        }
        std::printf("R %03x %05x %05x\n", at,
                    static_cast<unsigned>(pair >> 18) & 0x3FFFF,
                    static_cast<unsigned>(pair) & 0x3FFFF);
    }
    std::printf("  dumped\n");
    return 0;
}

const console_cmd_t commands[] = {
        {"csp-freeze", "",
         "hold the CSP (its program stays) and pause the tick", cmd_freeze,
         nullptr},
        {"csp-thaw", "", "release the CSP", cmd_thaw, nullptr},
        {"csp-step", "[ms]",
         "release the CSP for some milliseconds, then hold it", cmd_step,
         nullptr},
        {"csp-dump", "[first [count]]", "every register, a pair a line",
         cmd_dump, nullptr},
        {"csp-spitest", "[rounds]", "write and read back scratch registers",
         cmd_spitest, nullptr},
        {"csp-hold", "", "lab: pause the tick, hold the CSP, clear its program",
         cmd_hold, nullptr},
        {"csp-word", "<pc> <hex>", "lab: write an instruction word", cmd_word,
         nullptr},
        {"csp-const", "<register> <raw>",
         "lab: write a register (applies on csp-go)", cmd_const, nullptr},
        {"csp-burst", "<register> <count> <seed>",
         "lab: queue test values in bursts of 8, as the engine does", cmd_burst,
         nullptr},
        {"csp-go", "", "lab: commit the writes and release the CSP", cmd_go,
         nullptr},
        {"csp-selftest", "[run]",
         "run the boot self-test again ('run': leave it running)", cmd_selftest,
         nullptr},
        {"csp-peek", "<register> [count]",
         "read CSP registers (even-aligned pairs)", cmd_peek, nullptr},
        {"csp-poke", "<register> <raw> [force]",
         "queue a write to a CSP register ('force': even if the image says it is there)",
         cmd_poke, nullptr},
        {"csp-verify", "",
         "read every register the image knows back and count the differences",
         cmd_verify, nullptr},
        {"csp-resend", "", "send the whole register image again", cmd_resend,
         nullptr},
        {"csp-diag", "", "the gateware's diagnostic words", cmd_diag, nullptr},
};

} // namespace

extern "C" void cli_csp_init(void) {
    for (const console_cmd_t &command : commands) {
        console_register(&command);
    }
}
