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
#include <cstring>

#include "console.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "engine_link.h"
#include "fpga_map.hpp"
#include "spi_link.hpp"

namespace {

int signed_word(uint64_t raw18) {
    const int word = static_cast<int>(raw18 & 0x3FFFF);
    return word >= (1 << 17) ? word - (1 << 18) : word;
}

// csp-pairwatch reads one register pair through the probe again and again and
// counts the reads whose two halves differ. The self-test program writes the
// pass counter into both halves of two pairs (through the multiply-add and
// the logic unit, and through the logic unit twice), so at a raised clock the
// count is the rate at which one of the two paths miscomputes, measured on the
// chip, which no timing report can give for a path it does not time.
int cmd_pairwatch(int argc, char **argv) {
    if (argc < 2) {
        std::printf("usage: csp-pairwatch <register> [reads]   (an even register; default 2000 reads)\n");
        return 1;
    }
    const int first = static_cast<int>(std::strtol(argv[1], nullptr, 0)) & ~1;
    const int reads = argc > 2 ? static_cast<int>(std::strtol(argv[2], nullptr, 0)) : 2000;
    // The pair's two status words are fetched a few microseconds apart within one
    // link frame, so the odd half is the next pass's in a share of the reads that
    // grows with the clock: a difference of exactly one is that, not a miss.
    int disagree = 0, next_pass = 0, failed = 0;
    uint64_t first_disagreement = 0;
    for (int n = 0; n < reads; ++n) {
        uint64_t pair = 0;
        if (!engine_link_peek(first, &pair)) {
            ++failed;
            continue;
        }
        const unsigned even = static_cast<unsigned>(pair >> 18) & 0x3FFFF;
        const unsigned odd  = static_cast<unsigned>(pair) & 0x3FFFF;
        if (even == odd) {
            continue;
        }
        if (odd == ((even + 1) & 0x3FFFF)) {
            ++next_pass;
            continue;
        }
        if (disagree == 0) {
            first_disagreement = pair;
        }
        ++disagree;
        if ((n & 255) == 255) {
            vTaskDelay(1); // let the idle task run: the watchdog
        }
    }
    std::printf("  pair %03x: %d of %d reads disagree (%d more were the next pass's odd half)", first, disagree, reads,
                next_pass);
    if (disagree > 0) {
        std::printf(" (first: %05x vs %05x)",
                    static_cast<unsigned>(first_disagreement >> 18) & 0x3FFFF,
                    static_cast<unsigned>(first_disagreement) & 0x3FFFF);
    }
    if (failed > 0) {
        std::printf("; %d reads failed", failed);
    }
    std::printf("\n");
    return 0;
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
    uint64_t dwords[fpga_map::diag_words] = {};
    if (!engine_link_raw_read(fpga_map::diag_pass, dwords, fpga_map::diag_words)) {
        std::printf("  the link answers no ID nonet\n");
        return 1;
    }
    std::printf("  passes %lu  queue %llx  limiter %llx  dropped %lu  stream frames %lu\n",
                static_cast<unsigned long>(engine_link_status(fpga_map::diag_pass)),
                static_cast<unsigned long long>(dwords[1]),
                static_cast<unsigned long long>(dwords[2]),
                static_cast<unsigned long>(dwords[3] & 0xFFFF),
                static_cast<unsigned long>(engine_link_status(fpga_map::diag_stream)));
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
    for (size_t pc = 0; pc < fpga_map::program_rows; ++pc) {
        const uint64_t row[2] = {0, 0};
        engine_link_raw_write_burst(fpga_map::program_base + 2 * static_cast<uint32_t>(pc), row, 2, true);
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
    // A row is two dwords; the first revision's word rides in the lower one
    // until #235 writes 72-bit rows.
    const uint64_t row[2] = {0, word};
    engine_link_raw_write_burst(fpga_map::program_base + 2 * pc, row, 2, true);
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
    engine_link_raw_write(fpga_map::fifo_door,
                          fpga_map::fifo_dword(static_cast<int>(address), static_cast<uint32_t>(raw)));
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
    constexpr unsigned burst_dwords = 8;
    for (unsigned at = 0; at < count; at += burst_dwords) {
        uint64_t dwords[burst_dwords];
        const unsigned n = std::min(burst_dwords, count - at);
        for (unsigned k = 0; k < n; ++k) {
            const unsigned address = first + at + k;
            dwords[k] = fpga_map::fifo_dword(static_cast<int>(address), (address * 37u + seed) & 0x1FFFFu);
        }
        engine_link_raw_write_burst(fpga_map::fifo_door, dwords, static_cast<int>(n), false);
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

// Does the SPI link carry what it is given? Random 36-bit dwords to the
// scratch dwords and back, N rounds, singly and in bursts.
int cmd_spitest(int argc, char **argv) {
    const int rounds =
            argc > 1 ? static_cast<int>(std::strtol(argv[1], nullptr, 0))
                     : 1000;
    constexpr int scratch_dwords = fpga_map::scratch_last - fpga_map::scratch_first + 1;
    uint64_t state = 0x12345678;
    int single_bad = 0, burst_bad = 0, id_bad = 0;
    for (int round = 0; round < rounds; ++round) {
        uint64_t dwords[scratch_dwords];
        for (uint64_t &dword : dwords) {
            state = state * 6364136223846793005ull + 1442695040888963407ull;
            dword  = (state >> 20) & spi_link::dword_mask;
        }
        for (int k = 0; k < scratch_dwords; ++k) {
            engine_link_raw_write(fpga_map::scratch_first + k, dwords[k]);
        }
        for (int k = 0; k < scratch_dwords; ++k) {
            uint64_t one = 0;
            id_bad += !engine_link_raw_read(fpga_map::scratch_first + k, &one, 1);
            single_bad += one != dwords[k];
        }
        engine_link_raw_write_burst(fpga_map::scratch_first, dwords, scratch_dwords, true);
        uint64_t back[scratch_dwords] = {};
        id_bad += !engine_link_raw_read(fpga_map::scratch_first, back, scratch_dwords);
        for (int k = 0; k < scratch_dwords; ++k) {
            burst_bad += back[k] != dwords[k];
        }
    }
    std::printf("  %d rounds: %d single-dword and %d burst mismatches, %d frames without the ID\n",
                rounds, single_bad, burst_bad, id_bad);
    return 0;
}

// csp-spiclk <MHz>: the link's clock, for the test above at other rates.
int cmd_spiclk(int argc, char **argv) {
    if (argc != 2) {
        std::printf("usage: csp-spiclk <MHz>\n");
        return 1;
    }
    const double megahertz = std::strtod(argv[1], nullptr);
    if (megahertz < 0.1 || megahertz > 80.0) {
        std::printf("usage: csp-spiclk <MHz> (0.1 to 80)\n");
        return 1;
    }
    const uint32_t actual = engine_link_spi_frequency(static_cast<uint32_t>(megahertz * 1e6));
    std::printf("  SPI clock %.3f MHz\n", actual / 1e6);
    return 0;
}

// csp-stream off | lfsr | counter: the data stream on the 48 kHz S/PDIF
// output, the pipe tools/lab/spdif_capture.py checks bit for bit.
int cmd_stream(int argc, char **argv) {
    if (argc != 2) {
        std::printf("usage: csp-stream off|lfsr|counter|probe\n");
        return 1;
    }
    const char *what = argv[1];
    if (std::strcmp(what, "off") == 0) {
        engine_link_data_stream(false, 0);
    } else if (std::strcmp(what, "lfsr") == 0) {
        engine_link_data_stream(true, static_cast<int>(fpga_map::stream_source_lfsr));
    } else if (std::strcmp(what, "counter") == 0) {
        engine_link_data_stream(true, static_cast<int>(fpga_map::stream_source_counter));
    } else if (std::strcmp(what, "probe") == 0) {
        engine_link_data_stream(true, static_cast<int>(fpga_map::stream_source_probe));
    } else {
        std::printf("usage: csp-stream off|lfsr|counter|probe\n");
        return 1;
    }
    std::printf("  stream %s\n", what);
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
    const uint32_t first = engine_link_status(fpga_map::diag_pass);
    engine_link_raw_write(fpga_map::ctrl, 0);
    vTaskDelay(pdMS_TO_TICKS(milliseconds));
    engine_link_raw_write(fpga_map::ctrl, fpga_map::ctrl_hold);
    const uint32_t last = engine_link_status(fpga_map::diag_pass);
    vTaskDelay(pdMS_TO_TICKS(10));
    std::printf("  stepped %d ms from pass %lu to %lu\n", milliseconds,
                static_cast<unsigned long>(first), static_cast<unsigned long>(last));
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
        {"csp-spitest", "[rounds]", "write and read back the scratch dwords",
         cmd_spitest, nullptr},
        {"csp-spiclk", "<MHz>", "the SPI link's clock", cmd_spiclk, nullptr},
        {"csp-stream", "off|lfsr|counter|probe",
         "the data stream on the 48 kHz S/PDIF output", cmd_stream, nullptr},
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
        {"csp-pairwatch", "<register> [reads]",
         "read a pair many times, count the reads whose halves differ", cmd_pairwatch, nullptr},
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
