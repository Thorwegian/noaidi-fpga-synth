// engine_link.cpp — the register image → the write queue → the swap
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "engine_link.h"

#include <algorithm>
#include <cmath>
#include <array>
#include <bitset>
#include <cstdio>
#include <cstring>
#include <string>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "sdkconfig.h"

#include "console.h"
#include "engine_image.hpp"
#include "engine_selftest.hpp"
#include "fpga_map.hpp"
#include "render.hpp"
#include "spi_link.hpp"
#include "wiring.hpp"

namespace {

constexpr const char *tag = "engine_link";

constexpr int task_stack = 4096;
// highest app task: above midi_in/voice_alloc (5), midi_log/ble_rx (4)
constexpr int task_priority = 6;
// 1 kHz control rate. Paced by an esp_timer notifying the task, so the rate
// does not depend on the FreeRTOS tick (CONFIG_FREERTOS_HZ, pinned to 1000
// in sdkconfig.defaults).
constexpr int64_t tick_us = 1000;

// The FPGA's FIFO holds 511 dwords and the CSP applies 48 a pass: 48 passes
// in a tick, so a tick can send nearly the whole queue and it is empty again
// by the next. A tick sends no more than this, the rest waits for the next.
constexpr int writes_per_tick = 480;

// The SPI link, as the image sends through it: every dword into the FIFO's
// door, in one frame without auto-increment.
class SpiPort : public EnginePort {
public:
    void queue(const fpga_map::dword_t *dwords, int count) override {
        spi_link::write_repeated(fpga_map::fifo_door, dwords,
                                 static_cast<size_t>(count));
    }
    void write_register(uint32_t address, fpga_map::dword_t value) override {
        spi_link::write_one(address, value);
    }
};

EngineImage image;
SpiPort port;

// The Noaidi as a DSP graph, wired at boot (wiring.hpp), and the program
// the graph builds. Every word the firmware writes is one it asks the
// graph for, so the synth lives as long as the firmware plays. Static: an
// image is larger than a task's stack, and so the linker sizes it with the
// rest of the firmware's memory. The graph's own memory is the heap's.
wiring::Synth synth;
csp::ProgramBuilder::Built program;

// The master limiter's gain reduction in codes of 0.375 dB (16 an octave),
// from DIAG_LIMITER: the applied gain, linear, UQ0.18, unity 0x40000. The
// log is taken once here, not in gateware: 16 * log2(unity / gain), to the
// nearest code; 0 at unity, 288 (108 dB) at a gain of 1, 300 at zero.
uint32_t reduction_codes(fpga_map::dword_t word) {
    const uint32_t gain = static_cast<uint32_t>(word) & 0x7FFFF;
    if (gain >= 0x40000) {
        return 0;
    }
    if (gain == 0) {
        return 300;
    }
    return static_cast<uint32_t>(
            std::lround(16.0 * std::log2(262144.0 / gain)));
}
SemaphoreHandle_t lock = nullptr;
TaskHandle_t task      = nullptr;
bool test_tone         = false;
bool data_stream       = false;
int stream_source      = 0;
bool running           = false;
bool paused = false; // the tick sends nothing (the self-test has the chip)

// CTRL as the engine keeps it: the levels it owns, over the bits asked for.
fpga_map::dword_t ctrl_word(fpga_map::dword_t bits) {
    return bits | (test_tone ? fpga_map::ctrl_test_tone : 0)
           | (data_stream ? fpga_map::ctrl_data_stream : 0)
           | (static_cast<fpga_map::dword_t>(stream_source
                                             & fpga_map::stream_source_mask)
              << fpga_map::ctrl_source_shift);
}

// Send what is pending, at most `limit` words, and commit it with a swap.
int send(int limit, fpga_map::dword_t ctrl_bits) {
    return image.send(port, limit, ctrl_word(ctrl_bits));
}

// Every register to zero, while the CSP is held, after the self-test and
// before the image: the register file outlives this chip's reset and keeps
// whatever the last run left (the self-test's values, a chip check's fill and
// pointers, a saturated scratch word), and a register the image never writes
// — a scratch field, an unused channel's — would carry it into the program.
// Bursts of eight through the FIFO's door, every dword at the door's address
// (spi_link::write auto-increments, and landed one dword in eight: issue
// #238), committed a chunk at a time and applied by the held CSP's window,
// as csp burst does (cli_csp.cpp).
void clear_registers() {
    constexpr int burst_dwords = 8;
    constexpr int chunk_dwords = fpga_map::queue_depth / 2;
    int since_commit           = 0;
    for (int at = 1; at < csp::register_count; at += burst_dwords) {
        fpga_map::dword_t dwords[burst_dwords];
        const int n = std::min(burst_dwords, csp::register_count - at);
        for (int k = 0; k < n; ++k) {
            dwords[k] = fpga_map::fifo_dword(at + k, 0);
        }
        spi_link::write_repeated(fpga_map::fifo_door, dwords,
                                 static_cast<size_t>(n));
        since_commit += n;
        if (since_commit >= chunk_dwords || at + n >= csp::register_count) {
            spi_link::write_one(fpga_map::ctrl,
                                fpga_map::ctrl_hold | fpga_map::ctrl_swap);
            vTaskDelay(pdMS_TO_TICKS(2));
            since_commit = 0;
        }
    }
}

// The low 32 bits of a status dword, read twice until the two agree: the
// status dwords cross from the system clock bit by bit.
uint32_t read_status(uint32_t address) {
    std::array<fpga_map::dword_t, 2> twice{};
    for (int attempt = 0; attempt < 4; ++attempt) {
        spi_link::read_repeated(address, twice.data(), twice.size());
        if (twice[0] == twice[1]) {
            break;
        }
    }
    return static_cast<uint32_t>(twice[1]);
}

void tick_timer_cb(void *) {
    xTaskNotifyGive(task); // runs in the esp_timer task
}

// Once a second, ask the gateware how it is doing and say so if it is not
// well: the CSP has stopped running passes, or the queue dropped writes.
// Silence that outlasts the notes is then explained by the log, not guessed
// at.
void check_gateware_health() {
    static uint32_t previous_passes  = 0;
    static uint32_t previous_dropped = 0;
    std::array<fpga_map::dword_t, fpga_map::diag_words> diag{};
    xSemaphoreTake(lock, portMAX_DELAY);
    const bool read_ok =
            spi_link::read(fpga_map::diag_pass, diag.data(), diag.size());
    xSemaphoreGive(lock);
    if (!read_ok) {
        ESP_LOGW(tag, "diagnostic read failed");
        return;
    }
    const uint32_t passes    = static_cast<uint32_t>(diag[0]);
    const bool queue_full    = (diag[1] >> 10) & 1;
    const uint32_t reduction = reduction_codes(diag[2]);
    const uint32_t dropped   = static_cast<uint32_t>(diag[3] & 0xFFFF);
    const bool csp_stopped   = passes == previous_passes;
    const bool dropped_new   = dropped != previous_dropped;
    previous_passes          = passes;
    previous_dropped         = dropped;
    if (csp_stopped || dropped_new || queue_full) {
        ESP_LOGW(
                tag,
                "gateware: passes %lu%s, queue %s, dropped %lu%s, limiter -%.1f dB (raw %05lx)",
                static_cast<unsigned long>(passes),
                csp_stopped ? " (NOT RUNNING)" : "", queue_full ? "FULL" : "ok",
                static_cast<unsigned long>(dropped),
                dropped_new ? " (new)" : "", reduction * 0.375,
                static_cast<unsigned long>(diag[2]));
    }
}

// Read one CSP register pair through the probe: the even register is the
// upper 18 bits of the result, the odd one the lower. The lock is not held
// while the probe waits for its pass.
uint64_t probe_pair(int register_address) {
    xSemaphoreTake(lock, portMAX_DELAY);
    spi_link::write_one(fpga_map::probe_address,
                        static_cast<fpga_map::dword_t>(register_address));
    xSemaphoreGive(lock);
    vTaskDelay(pdMS_TO_TICKS(3)); // at least two passes
    std::array<fpga_map::dword_t, 2> pair{};
    xSemaphoreTake(lock, portMAX_DELAY);
    spi_link::read(fpga_map::probe_even, pair.data(), pair.size());
    xSemaphoreGive(lock);
    return ((pair[0] & fpga_map::word_mask) << fpga_map::word_bits)
           | (pair[1] & fpga_map::word_mask);
}

// The boot self-test's way to the chip: the SPI link, and the probe.
class SpiSelfTestPort : public SelfTestPort {
public:
    void write_dword(uint32_t address, uint64_t value) override {
        spi_link::write_one(address, value);
    }
    void wait_ms(int milliseconds) override {
        vTaskDelay(pdMS_TO_TICKS(milliseconds));
    }
    uint64_t probe(int register_address) override {
        return probe_pair(register_address);
    }
};

// Diagnostic: leave the CSP held and the tick paused after the boot image is
// in, to snapshot the chip before its program has run (tools/lab/snapshot.py).
constexpr bool hold_after_boot = false;

// The limiter meter: the master limiter's gain reduction on the console's
// status bar, one column per code of 0.375 dB. DIAG_LIMITER[18:0] is the
// applied gain, linear, UQ0.18 (unity 0x40000); reduction_codes takes the
// log. The gain's 18 fraction bits bound the reduction at 108 dB, 288
// codes: past an 80-column bar, which it may overrun. Twenty readings a
// second, one dword each, at the lowest priority there is: the engine's
// worst wait for the bus is this one frame (the lock is a mutex, which
// inherits priority). A reading the bus refused shows as full reduction.
constexpr int meter_period_ms = 50;

void meter_task(void *) {
    int shown = -1;
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(meter_period_ms));
        xSemaphoreTake(lock, portMAX_DELAY);
        const fpga_map::dword_t word =
                spi_link::read_one(fpga_map::diag_limiter);
        xSemaphoreGive(lock);
        const int columns = static_cast<int>(reduction_codes(word));
        if (columns != shown) {
            shown = columns;
            console_set_meter(columns);
        }
    }
}

// What a read-back of the image found: the registers that differ, and those
// of them the program does not write. A word the program writes as well (a
// voice's level and stage) moves by itself once the CSP is let go; any other
// that differs is a write that did not land.
struct Differing {
    int all            = 0;
    int firmware_owned = 0;
};

// Every register the image knows, read back through the probe and compared,
// the first `limit` that differ filled in.
Differing verify_image(int *registers, int32_t *wanted, int32_t *held,
                       int limit) {
    Differing differing;
    // The probe reads the register file (0x000–0x7FF) a pair at a time; the
    // sinks beyond it cannot be read back.
    for (int even = 0; even < 0x800; even += 2) {
        int32_t expected[2];
        const bool known[2] = {image.known(even, &expected[0]),
                               image.known(even + 1, &expected[1])};
        if (!known[0] && !known[1]) {
            continue;
        }
        const uint64_t pair     = probe_pair(even);
        const int32_t actual[2] = {static_cast<int32_t>((pair >> 18) & 0x3FFFF),
                                   static_cast<int32_t>(pair & 0x3FFFF)};
        for (int half = 0; half < 2; ++half) {
            if (known[half] && actual[half] != (expected[half] & 0x3FFFF)) {
                if (differing.all < limit) {
                    registers[differing.all] = even + half;
                    wanted[differing.all]    = expected[half] & 0x3FFFF;
                    held[differing.all]      = actual[half];
                }
                ++differing.all;
                differing.firmware_owned += synth.graph.writer(even + half)
                                            != csp::DspGraph::Writer::program;
            }
        }
    }
    return differing;
}

// The boot image, read back before the first note: the write queue has lost
// words of it on some boots (issue #222: the constant ONE among them, and
// the synth silent for it, with every self-test passing), so what the chip
// holds is checked against the image and the image sent again until they
// agree, a bounded number of times. The console shows the count either way.
constexpr int boot_image_attempts = 3;

void verify_boot_image() {
    constexpr int named =
            4; // the first differing registers, in the log: which words a boot loses
    for (int attempt = 1; attempt <= boot_image_attempts; ++attempt) {
        int registers[named];
        int32_t wanted[named], held[named];
        const int lost = verify_image(registers, wanted, held, named).all;
        if (lost == 0) {
            ESP_LOGI(tag, "boot image: every register as sent%s",
                     attempt > 1 ? " (after a resend)" : "");
            return;
        }
        char first[named * 32 + 1] = "";
        for (int k = 0; k < std::min(lost, named); ++k) {
            char one[32];
            std::snprintf(one, sizeof one, " %03x:%ld/%ld", registers[k],
                          static_cast<long>(wanted[k]),
                          static_cast<long>(held[k]));
            std::strncat(first, one, sizeof first - std::strlen(first) - 1);
        }
        ESP_LOGW(
                tag,
                "boot image: %d register(s) not as sent (image/chip:%s), sending it again (%d of %d)",
                lost, first, attempt, boot_image_attempts);
        // the CSP is held: the window applies a committed chunk within a few passes
        image.resend_all();
        while (image.pending()) {
            send(fpga_map::queue_depth / 2, fpga_map::ctrl_hold);
            vTaskDelay(pdMS_TO_TICKS(2));
        }
    }
    ESP_LOGE(
            tag,
            "boot image: still not as sent after %d resends; the synth may be silent",
            boot_image_attempts);
}

void engine_task(void *) {
    int ticks = 0;
    while (true) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        const int64_t woke = esp_timer_get_time();

        xSemaphoreTake(lock, portMAX_DELAY);
        if (!paused) {
            send(writes_per_tick, 0);
        }
        xSemaphoreGive(lock);

        if (++ticks == 1000) {
            ticks = 0;
            check_gateware_health();
        }

        // Single-core guard. If this wake ran long, the 1 kHz notify is
        // already pending, so the ulTaskNotifyTake above would return at once
        // and we would never block: starving IDLE (priority 0) on this
        // one-core chip, and the task watchdog with it. Yield a tick so IDLE
        // runs; the image lags at most a millisecond or two, which is
        // inaudible.
        if (esp_timer_get_time() - woke > 800) {
            vTaskDelay(1);
        }
    }
}

// While one of these lives, malloc() places every block in the PSRAM, the
// small ones too: the graph and what its build needs, which the internal
// RAM has no room for beside the firmware's own
// (docs.espressif.com, "Support for External RAM": the size limit under
// which a block goes to internal memory first).
class ExternalHeap {
public:
    ExternalHeap() {
        heap_caps_malloc_extmem_enable(0);
    }
    ~ExternalHeap() {
        heap_caps_malloc_extmem_enable(CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL);
    }
    ExternalHeap(const ExternalHeap &)            = delete;
    ExternalHeap &operator=(const ExternalHeap &) = delete;
};

// Every LFO, channel and voice wired into the graph and the graph's program
// built, and what it cost: the time of each, the PSRAM the graph holds now
// and what the build took beside it at its most (from the least that has
// been free since boot), what the internal heap gave, and the stack the
// calling task has never used. False if the graph's program does not
// build, with the graph's reasons in the log.
bool generate_program() {
    const size_t external_before = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    const size_t internal_before = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    const int64_t started        = esp_timer_get_time();
    int64_t wired                = 0;
    bool built                   = false;
    {
        const ExternalHeap external;
        wiring::wire(synth);
        wired = esp_timer_get_time();
        built = synth.graph.build(program);
    }
    const int64_t finished      = esp_timer_get_time();
    const size_t external_after = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    ESP_LOGI(
            tag,
            "graph wired in %lld us, its program built in %lld us: %u bytes of PSRAM held, %u more at the build's most; %d bytes of internal heap held; stack %lu bytes never used",
            static_cast<long long>(wired - started),
            static_cast<long long>(finished - wired),
            static_cast<unsigned>(external_before - external_after),
            static_cast<unsigned>(
                    external_after
                    - heap_caps_get_minimum_free_size(MALLOC_CAP_SPIRAM)),
            static_cast<int>(internal_before)
                    - static_cast<int>(
                            heap_caps_get_free_size(MALLOC_CAP_INTERNAL)),
            static_cast<unsigned long>(uxTaskGetStackHighWaterMark(nullptr)));
    for (const csp::DspGraph::Issue &issue : synth.graph.issues()) {
        ESP_LOGE(tag, "control program: %s", issue.message.c_str());
    }
    return built;
}

// The dword at `index` of the program image as the firmware sends it: a row
// is two dwords, bits 71:36 then 35:0.
fpga_map::dword_t program_dword(size_t index) {
    const csp::Row &row = program.image.rows[index / 2];
    return index % 2 == 0 ? row.high : row.low;
}

// The dword at `index` of the decode ROM image: one control word a row,
// NOP rows (0) past the program's.
fpga_map::dword_t rom_dword(size_t index) {
    return program.image.rom[index];
}

// Send `count` dwords from `base` in bursts, and read them back through the
// same port: how many differ from what was sent.
template <typename Dword>
int send_and_verify(uint32_t base, size_t count, Dword dword_at) {
    std::array<fpga_map::dword_t, spi_link::burst_max> burst{};
    for (size_t first = 0; first < count; first += burst.size()) {
        const size_t n = std::min(burst.size(), count - first);
        for (size_t k = 0; k < n; ++k) {
            burst[k] = dword_at(first + k);
        }
        spi_link::write(base + static_cast<uint32_t>(first), burst.data(), n);
    }
    int differing = 0;
    for (size_t first = 0; first < count; first += burst.size()) {
        const size_t n = std::min(burst.size(), count - first);
        spi_link::read(base + static_cast<uint32_t>(first), burst.data(), n);
        for (size_t k = 0; k < n; ++k) {
            differing +=
                    burst[k] != (dword_at(first + k) & spi_link::dword_mask);
        }
    }
    return differing;
}

// Load the control program while the CSP is held: the rows into IMEM and
// the control words into the decode ROM, then both read back and counted
// against what was sent, so the program image is verified the way the
// register image is.
void load_program() {
    // the program's rows only, END included: the chip's fetch parks on END, so
    // what IMEM holds past them never runs (#271)
    const size_t rows = static_cast<size_t>(program.image.length);
    const int rows_differing =
            send_and_verify(fpga_map::program_base, 2 * rows, program_dword);
    const int rom_differing =
            send_and_verify(fpga_map::rom_base, fpga_map::rom_rows, rom_dword);
    if (rows_differing == 0 && rom_differing == 0) {
        ESP_LOGI(tag,
                 "program image: every dword as sent (%u rows, %u decode rows)",
                 static_cast<unsigned>(rows),
                 static_cast<unsigned>(fpga_map::rom_rows));
    } else {
        ESP_LOGE(
                tag,
                "program image: %d row dword(s) and %d decode dword(s) not as sent",
                rows_differing, rom_differing);
    }
}

} // namespace

void engine_link_init(void) {
    lock = xSemaphoreCreateMutex();
    if (lock == nullptr) {
        ESP_LOGE(tag, "no mutex");
        return;
    }

    // The CSP starts held; make sure of it, whatever the last run left, then
    // give it the program and the wiring.
    spi_link::write_one(fpga_map::ctrl, fpga_map::ctrl_hold);

    // The probe reads a register pair once a pass; after a reset it reads
    // pair 0, the row the constant ONE is in, and a read of a block RAM row
    // on one port while the other writes it is a collision (issue #222: ONE
    // lost at boot). Park it on a pair nothing writes until it is asked for.
    spi_link::write_one(fpga_map::probe_address, 0x5FE);

    // The write FIFO outlives a reset of this chip: what the last run left in
    // it (committed or not) would be applied during the self-test and the first
    // passes of the control program, over what they compute. Commit it and let
    // the held CSP apply it all now (up to 511 dwords, in one pass when held).
    spi_link::write_one(fpga_map::ctrl,
                        fpga_map::ctrl_hold | fpga_map::ctrl_swap);
    vTaskDelay(pdMS_TO_TICKS(10));

    // Does the chip do what the model says? Say so before the sound depends
    // on it; the control program loads over the test either way.
    {
        SpiSelfTestPort self_test_port;
        const SelfTestResult self_test = run_selftest(self_test_port);
        for (const std::string &line : self_test.lines) {
            ESP_LOGI(tag, "self-test: %s", line.c_str());
        }
        if (self_test.passed) {
            ESP_LOGI(tag, "self-test: the chip does what the model says");
        } else {
            ESP_LOGE(tag,
                     "self-test: THE CHIP DOES NOT DO WHAT THE MODEL SAYS");
        }
    }

    // Nothing of the test, or of what ran before this chip was reset, under
    // the image: every register zero, then the program and the image.
    clear_registers();
    const bool generated = generate_program();
    load_program();

    // The program's constants are immediates in its rows; the register image
    // starts from what the renderer sets up, in the words the graph laid out.
    render::Writes writes;
    if (generated) {
        render::setup(synth, writes);
    }
    for (const render::Write &write : writes) {
        image.set(write.address, write.raw);
    }
    // Held, the CSP applies every committed write in one pass; the queue holds
    // 511, so a chunk at a time, and a pass between.
    while (image.pending()) {
        send(fpga_map::queue_depth / 2, fpga_map::ctrl_hold);
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    // read back while the CSP is still held: once released, the program rewrites
    // the registers that hold its state, which the image set too
    verify_boot_image();
    if (!generated) {
        // IMEM still holds the self-test: released, it would run on the image
        paused = true;
        ESP_LOGE(
                tag,
                "no control program: the CSP stays held and the synth is silent");
    } else if (hold_after_boot) {
        paused = true;
        ESP_LOGW(tag,
                 "hold_after_boot: the CSP stays held, the tick is paused");
    } else {
        spi_link::write_one(fpga_map::ctrl, ctrl_word(0)); // release
    }
    ESP_LOGI(
            tag,
            "control program loaded: %u rows, %u decode rows, %d cycles a pass",
            static_cast<unsigned>(program.image.length),
            static_cast<unsigned>(program.image.rom_used), program.cycles);

    if (xTaskCreate(engine_task, "engine_link", task_stack, nullptr,
                    task_priority, &task)
        != pdPASS) {
        ESP_LOGE(tag, "failed to create task");
        return;
    }
    xTaskCreate(meter_task, "engine_meter", 3072, nullptr, 1, nullptr);
    esp_timer_create_args_t timer_args = {};
    timer_args.callback                = tick_timer_cb;
    timer_args.name                    = "engine_tick";
    esp_timer_handle_t timer;
    ESP_ERROR_CHECK(esp_timer_create(&timer_args, &timer));
    ESP_ERROR_CHECK(esp_timer_start_periodic(timer, tick_us));
    running = true;
    ESP_LOGI(tag, "1 kHz tick running");
}

void engine_link_pause(bool pause) {
    paused = pause;
}

bool engine_link_raw_write(uint32_t address, uint64_t dword) {
    if (!running) {
        return false;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    spi_link::write_one(address, dword);
    xSemaphoreGive(lock);
    return true;
}

bool engine_link_raw_write_burst(uint32_t address, const uint64_t *dwords,
                                 int count, bool auto_increment) {
    if (!running) {
        return false;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    if (auto_increment) {
        spi_link::write(address, dwords, static_cast<size_t>(count));
    } else {
        spi_link::write_repeated(address, dwords, static_cast<size_t>(count));
    }
    xSemaphoreGive(lock);
    return true;
}

bool engine_link_raw_read(uint32_t address, uint64_t *dwords, int count) {
    if (!running) {
        return false;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    const bool ok = spi_link::read(address, dwords, static_cast<size_t>(count));
    xSemaphoreGive(lock);
    return ok;
}

uint32_t engine_link_status(uint32_t address) {
    if (!running) {
        return 0;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    const uint32_t value = read_status(address);
    xSemaphoreGive(lock);
    return value;
}

bool engine_link_peek(int address, uint64_t *pair) {
    if (!running || pair == nullptr || address < 0 || address >= 0x800) {
        return false;
    }
    *pair = probe_pair(address & ~1);
    return true;
}

bool engine_link_write(int address, int32_t raw) {
    if (!running) {
        return false;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    const bool ok = image.set(address, raw);
    xSemaphoreGive(lock);
    return ok;
}

int engine_link_verify(int *registers, int32_t *wanted, int32_t *held,
                       int limit, int *firmware_owned) {
    if (!running) {
        return -1;
    }
    const Differing differing = verify_image(registers, wanted, held, limit);
    *firmware_owned           = differing.firmware_owned;
    return differing.all;
}

bool engine_link_program_writes(int address) {
    return synth.graph.writer(address) == csp::DspGraph::Writer::program;
}

bool engine_link_write_all(const render::Writes &writes) {
    if (!running) {
        return false;
    }
    bool ok = true;
    xSemaphoreTake(lock, portMAX_DELAY);
    for (const render::Write &write : writes) {
        ok &= image.set(write.address, write.raw, write.force);
    }
    xSemaphoreGive(lock);
    return ok;
}

const wiring::Synth &engine_link_synth() {
    return synth;
}

bool engine_link_point(int partial, const int *pointers) {
    if (!running || partial < 0 || partial >= fpga_map::partial_count) {
        return false;
    }
    // Three pointers of ten bits to a dword, the fourth dword commits.
    std::array<fpga_map::dword_t, fpga_map::pointer_words> dwords{};
    for (int k = 0; k < render::pointer_count; ++k) {
        dwords[k / 3] |= (static_cast<fpga_map::dword_t>(pointers[k]) & 0x3FF)
                         << (10 * (k % 3));
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    spi_link::write(fpga_map::partial_base
                            + static_cast<uint32_t>(partial)
                                      * fpga_map::partial_stride,
                    dwords.data(), dwords.size());
    xSemaphoreGive(lock);
    return true;
}

void engine_link_test_tone(bool on) {
    if (!running) {
        return;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    test_tone = on;
    spi_link::write_one(fpga_map::ctrl, ctrl_word(0));
    xSemaphoreGive(lock);
}

void engine_link_data_stream(bool on, int source) {
    if (!running) {
        return;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    data_stream   = on;
    stream_source = source;
    spi_link::write_one(fpga_map::ctrl, ctrl_word(0));
    xSemaphoreGive(lock);
}
