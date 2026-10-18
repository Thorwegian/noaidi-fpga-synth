// engine_link.cpp — the register image → the write queue → the swap
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "engine_link.h"

#include <algorithm>
#include <array>
#include <bitset>
#include <string>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "csp/control_program.hpp"
#include "engine_image.hpp"
#include "engine_selftest.hpp"
#include "fpga_map.hpp"
#include "render.hpp"
#include "spi_link.hpp"

namespace {

constexpr const char *tag = "engine_link";

constexpr int task_stack = 4096;
// highest app task: above midi_in/voice_alloc (5), midi_log/ble_rx (4)
constexpr int task_priority = 6;
// 1 kHz control rate. Paced by an esp_timer notifying the task, so the rate
// does not depend on the FreeRTOS tick (CONFIG_FREERTOS_HZ, pinned to 1000
// in sdkconfig.defaults).
constexpr int64_t tick_us = 1000;

// The FPGA's FIFO holds 511 quads and the CSP applies 48 a pass: 48 passes
// in a tick, so a tick can send nearly the whole queue and it is empty again
// by the next. A tick sends no more than this, the rest waits for the next.
constexpr int writes_per_tick = 480;

// The SPI link, as the image sends through it: every quad into the FIFO's
// door, in one frame without auto-increment.
class SpiPort : public EnginePort {
public:
    void queue(const fpga_map::quad_t *quads, int count) override {
        spi_link::write_repeated(fpga_map::fifo_door, quads, static_cast<size_t>(count));
    }
    void write_register(uint32_t address, fpga_map::quad_t value) override {
        spi_link::write_one(address, value);
    }
};

EngineImage image;
SpiPort port;
SemaphoreHandle_t lock = nullptr;
TaskHandle_t task      = nullptr;
bool test_tone         = false;
bool data_stream       = false;
int stream_source      = 0;
bool running           = false;
bool paused = false; // the tick sends nothing (the self-test has the chip)

// CTRL as the engine keeps it: the levels it owns, over the bits asked for.
fpga_map::quad_t ctrl_word(fpga_map::quad_t bits) {
    return bits | (test_tone ? fpga_map::ctrl_test_tone : 0)
           | (data_stream ? fpga_map::ctrl_data_stream : 0)
           | (static_cast<fpga_map::quad_t>(stream_source & 3) << fpga_map::ctrl_source_shift);
}

// Send what is pending, at most `limit` words, and commit it with a swap.
int send(int limit, fpga_map::quad_t ctrl_bits) {
    return image.send(port, limit, ctrl_word(ctrl_bits));
}

// The low 32 bits of a status quad, read twice until the two agree: the
// status quads cross from the system clock bit by bit.
uint32_t read_status(uint32_t address) {
    std::array<fpga_map::quad_t, 2> twice{};
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
// well: the CSP has stopped running passes, the queue dropped writes, or the
// master limiter holds the output down. Silence that outlasts the notes is
// then explained by the log, not guessed at.
void check_gateware_health() {
    static uint32_t previous_passes  = 0;
    static uint32_t previous_dropped = 0;
    static int healthy_seconds       = 0;
    std::array<fpga_map::quad_t, fpga_map::diag_words> diag{};
    xSemaphoreTake(lock, portMAX_DELAY);
    const bool read_ok = spi_link::read(fpga_map::diag_pass, diag.data(), diag.size());
    xSemaphoreGive(lock);
    if (!read_ok) {
        ESP_LOGW(tag, "diagnostic read failed");
        return;
    }
    const uint32_t passes    = static_cast<uint32_t>(diag[0]);
    const bool queue_full    = (diag[1] >> 10) & 1;
    const uint32_t reduction = static_cast<uint32_t>(diag[2] >> 11); // codes of 0.375 dB
    const uint32_t dropped   = static_cast<uint32_t>(diag[3] & 0xFFFF);
    const bool csp_stopped   = passes == previous_passes;
    const bool dropped_new   = dropped != previous_dropped;
    previous_passes          = passes;
    previous_dropped         = dropped;
    if (csp_stopped || dropped_new || queue_full || reduction > 16) {
        healthy_seconds = 0;
        ESP_LOGW(
                tag,
                "gateware: passes %lu%s, queue %s, dropped %lu%s, limiter -%.1f dB (raw %05lx)",
                static_cast<unsigned long>(passes),
                csp_stopped ? " (NOT RUNNING)" : "", queue_full ? "FULL" : "ok",
                static_cast<unsigned long>(dropped),
                dropped_new ? " (new)" : "", reduction * 0.375,
                static_cast<unsigned long>(diag[2]));
    } else if (++healthy_seconds % 60 == 0) {
        ESP_LOGI(tag, "gateware ok: passes %lu, limiter -%.1f dB",
                 static_cast<unsigned long>(passes), reduction * 0.375);
    }
}

// Read one CSP register pair through the probe: the even register is the
// upper 18 bits of the result, the odd one the lower. The lock is not held
// while the probe waits for its pass.
uint64_t probe_pair(int register_address) {
    xSemaphoreTake(lock, portMAX_DELAY);
    spi_link::write_one(fpga_map::probe_address, static_cast<fpga_map::quad_t>(register_address));
    xSemaphoreGive(lock);
    vTaskDelay(pdMS_TO_TICKS(3)); // at least two passes
    std::array<fpga_map::quad_t, 2> pair{};
    xSemaphoreTake(lock, portMAX_DELAY);
    spi_link::read(fpga_map::probe_even, pair.data(), pair.size());
    xSemaphoreGive(lock);
    return ((pair[0] & fpga_map::word_mask) << fpga_map::word_bits)
           | (pair[1] & fpga_map::word_mask);
}

// The boot self-test's way to the chip: the SPI link, and the probe.
class SpiSelfTestPort : public SelfTestPort {
public:
    void write_quad(uint32_t address, uint64_t value) override {
        spi_link::write_one(address, value);
    }
    void wait_ms(int milliseconds) override {
        vTaskDelay(pdMS_TO_TICKS(milliseconds));
    }
    uint64_t probe(int register_address) override {
        return probe_pair(register_address);
    }
};

// The LFO probe log below is a diagnostic: its SPI traffic every few seconds
// is off unless this is set (a lab run of 480 queued writes lost a run of
// them each time the probe fired).
constexpr bool log_lfo_probe = false;

// Diagnostic: leave the CSP held and the tick paused after the boot image is
// in, to snapshot the chip before its program has run (tools/lab/snapshot.py).
constexpr bool hold_after_boot = false;

// Every few seconds, log what the CSP holds for the LFOs: the pass counter
// and, for each LFO, its record (phase, step, depth and its negative, gain
// and output) and its set (where it starts, how many of each shape). What the
// simulator cannot show of a board that does not modulate.
void probe_task(void *) {
    namespace cp = csp::control;
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        const unsigned long pass =
                static_cast<unsigned long>(probe_pair(0x040) >> 18);
        ESP_LOGI(tag, "probe: pass %lu", pass);
        // PARITY (which half of the LFOs this pass works) and the pass
        // counter's low bit, sampled eight times: each should show both.
        std::array<unsigned, 8> parity{};
        std::array<unsigned, 8> pass_low_bit{};
        for (size_t sample = 0; sample < parity.size(); ++sample) {
            parity[sample] = static_cast<unsigned>(
                    (probe_pair(cp::parity) >> 18) & 0x3FFFF);
            pass_low_bit[sample] =
                    static_cast<unsigned>((probe_pair(0x040) >> 18) & 1);
        }
        ESP_LOGI(
                tag,
                "probe: PARITY %u %u %u %u %u %u %u %u, PASS bit 0 %u %u %u %u %u %u %u %u",
                parity[0], parity[1], parity[2], parity[3], parity[4],
                parity[5], parity[6], parity[7], pass_low_bit[0],
                pass_low_bit[1], pass_low_bit[2], pass_low_bit[3],
                pass_low_bit[4], pass_low_bit[5], pass_low_bit[6],
                pass_low_bit[7]);
        for (int lfo = 0; lfo < 2; ++lfo) {
            const int record           = cp::lfos + lfo * 16 * cp::lfo_size;
            const int set              = cp::lfo_sets + lfo * cp::set_size;
            const uint64_t phase       = probe_pair(record + cp::phase);
            const uint64_t step        = probe_pair(record + cp::phase_step);
            const uint64_t depth       = probe_pair(record + cp::depth);
            const uint64_t gain        = probe_pair(record + cp::gain);
            const uint64_t set_a       = probe_pair(set + cp::base);
            const uint64_t set_b       = probe_pair(set + cp::n_saw + 1);
            const uint64_t set_c       = probe_pair(set + cp::n_saw + 3);
            const uint64_t scratch_p_t = probe_pair(record + cp::p);
            const uint64_t scratch_z   = probe_pair(record + cp::z);
            ESP_LOGI(
                    tag,
                    "probe: LFO%d phase %09llx step %09llx depth/neg %09llx gain/out %09llx "
                    "set %09llx %09llx %09llx P/T %09llx Z %09llx",
                    lfo + 1, static_cast<unsigned long long>(phase),
                    static_cast<unsigned long long>(step),
                    static_cast<unsigned long long>(depth),
                    static_cast<unsigned long long>(gain),
                    static_cast<unsigned long long>(set_a),
                    static_cast<unsigned long long>(set_b),
                    static_cast<unsigned long long>(set_c),
                    static_cast<unsigned long long>(scratch_p_t),
                    static_cast<unsigned long long>(scratch_z));
        }
    }
}

// Every register the image knows, read back through the probe and compared:
// how many differ, the first `limit` of them filled in.
int verify_image(int *registers, int32_t *wanted, int32_t *held, int limit) {
    int differing = 0;
    // The probe reads the register file (0x000–0x7FF) a pair at a time; the
    // sinks beyond it cannot be read back.
    for (int even = 0; even < 0x800; even += 2) {
        int32_t expected[2];
        const bool known[2] = {image.known(even, &expected[0]),
                               image.known(even + 1, &expected[1])};
        if (!known[0] && !known[1]) {
            continue;
        }
        const uint64_t pair = probe_pair(even);
        const int32_t actual[2] = {
                static_cast<int32_t>((pair >> 18) & 0x3FFFF),
                static_cast<int32_t>(pair & 0x3FFFF)};
        for (int half = 0; half < 2; ++half) {
            if (known[half] && actual[half] != (expected[half] & 0x3FFFF)) {
                if (differing < limit) {
                    registers[differing] = even + half;
                    wanted[differing]    = expected[half] & 0x3FFFF;
                    held[differing]      = actual[half];
                }
                ++differing;
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
    for (int attempt = 1; attempt <= boot_image_attempts; ++attempt) {
        const int lost = verify_image(nullptr, nullptr, nullptr, 0);
        if (lost == 0) {
            ESP_LOGI(tag, "boot image: every register as sent%s",
                     attempt > 1 ? " (after a resend)" : "");
            return;
        }
        ESP_LOGW(tag, "boot image: %d register(s) not as sent, sending it again (%d of %d)",
                 lost, attempt, boot_image_attempts);
        xSemaphoreTake(lock, portMAX_DELAY);
        image.resend_all();
        xSemaphoreGive(lock);
        while (image.pending()) {
            xSemaphoreTake(lock, portMAX_DELAY);
            send(writes_per_tick, 0);
            xSemaphoreGive(lock);
            vTaskDelay(pdMS_TO_TICKS(2));
        }
    }
    ESP_LOGE(tag, "boot image: still not as sent after %d resends; the synth may be silent",
             boot_image_attempts);
}

void engine_task(void *) {
    if (!paused) {
        verify_boot_image();
    }
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

// The quad at `index` of the program image as the firmware sends it: a row
// is two quads, bits 71:36 then 35:0, NOP rows past the program's end.
fpga_map::quad_t program_quad(size_t index) {
    const size_t pc = index / 2;
    if (pc >= csp::control::rows.size()) {
        return 0;
    }
    const csp::Row &row = csp::control::rows[pc];
    return index % 2 == 0 ? row.high : row.low;
}

// The quad at `index` of the decode ROM image: one control word a row,
// NOP rows (0) past the program's.
fpga_map::quad_t rom_quad(size_t index) {
    return index < csp::control::rom.size() ? csp::control::rom[index] : 0;
}

// Send `count` quads from `base` in bursts, and read them back through the
// same port: how many differ from what was sent.
template <typename Quad>
int send_and_verify(uint32_t base, size_t count, Quad quad_at) {
    std::array<fpga_map::quad_t, spi_link::burst_max> burst{};
    for (size_t first = 0; first < count; first += burst.size()) {
        const size_t n = std::min(burst.size(), count - first);
        for (size_t k = 0; k < n; ++k) {
            burst[k] = quad_at(first + k);
        }
        spi_link::write(base + static_cast<uint32_t>(first), burst.data(), n);
    }
    int differing = 0;
    for (size_t first = 0; first < count; first += burst.size()) {
        const size_t n = std::min(burst.size(), count - first);
        spi_link::read(base + static_cast<uint32_t>(first), burst.data(), n);
        for (size_t k = 0; k < n; ++k) {
            differing += burst[k] != (quad_at(first + k) & spi_link::quad_mask);
        }
    }
    return differing;
}

// Load the control program while the CSP is held: the rows into IMEM and
// the control words into the decode ROM, then both read back and counted
// against what was sent, so the program image is verified the way the
// register image is.
void load_program() {
    const int rows_differing = send_and_verify(fpga_map::program_base, 2 * fpga_map::program_rows, program_quad);
    const int rom_differing  = send_and_verify(fpga_map::rom_base, fpga_map::rom_rows, rom_quad);
    if (rows_differing == 0 && rom_differing == 0) {
        ESP_LOGI(tag, "program image: every quad as sent (%u rows, %u decode rows)",
                 static_cast<unsigned>(fpga_map::program_rows), static_cast<unsigned>(fpga_map::rom_rows));
    } else {
        ESP_LOGE(tag, "program image: %d row quad(s) and %d decode quad(s) not as sent", rows_differing,
                 rom_differing);
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
    // the held CSP apply it all now (up to 511 quads, in one pass when held).
    spi_link::write_one(fpga_map::ctrl, fpga_map::ctrl_hold | fpga_map::ctrl_swap);
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

    load_program();

    // The program's constants are immediates in its rows; the register image
    // starts from what the renderer sets up.
    render::Writes writes;
    render::setup(writes);
    for (const render::Write &write : writes) {
        image.set(write.address, write.raw);
    }
    // Held, the CSP applies every committed write in one pass; the queue holds
    // 511, so a chunk at a time, and a pass between.
    while (image.pending()) {
        send(fpga_map::queue_depth / 2, fpga_map::ctrl_hold);
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    if (hold_after_boot) {
        paused = true;
        ESP_LOGW(tag, "hold_after_boot: the CSP stays held, the tick is paused");
    } else {
        spi_link::write_one(fpga_map::ctrl, ctrl_word(0)); // release
    }
    ESP_LOGI(tag, "control program loaded: %u rows, %u decode rows, %d cycles a pass",
             static_cast<unsigned>(csp::control::rows.size()), static_cast<unsigned>(csp::control::rom.size()),
             csp::control::cycles);

    if (xTaskCreate(engine_task, "engine_link", task_stack, nullptr,
                    task_priority, &task)
        != pdPASS) {
        ESP_LOGE(tag, "failed to create task");
        return;
    }
    if (log_lfo_probe) {
        xTaskCreate(probe_task, "engine_probe", 3072, nullptr, 2, nullptr);
    }
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

bool engine_link_raw_write(uint32_t address, uint64_t quad) {
    if (!running) {
        return false;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    spi_link::write_one(address, quad);
    xSemaphoreGive(lock);
    return true;
}

bool engine_link_raw_write_burst(uint32_t address, const uint64_t *quads, int count,
                                 bool auto_increment) {
    if (!running) {
        return false;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    if (auto_increment) {
        spi_link::write(address, quads, static_cast<size_t>(count));
    } else {
        spi_link::write_repeated(address, quads, static_cast<size_t>(count));
    }
    xSemaphoreGive(lock);
    return true;
}

bool engine_link_raw_read(uint32_t address, uint64_t *quads, int count) {
    if (!running) {
        return false;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    const bool ok = spi_link::read(address, quads, static_cast<size_t>(count));
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

uint32_t engine_link_spi_frequency(uint32_t frequency_hz) {
    if (!running) {
        return 0;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    const uint32_t actual = spi_link::set_frequency(frequency_hz);
    xSemaphoreGive(lock);
    return actual;
}

bool engine_link_selftest(bool leave_running) {
    if (!running) {
        return false;
    }
    SpiSelfTestPort self_test_port;
    xSemaphoreTake(lock, portMAX_DELAY);
    paused = true;
    spi_link::write_one(fpga_map::ctrl, fpga_map::ctrl_hold);
    xSemaphoreGive(lock);
    const SelfTestResult result = run_selftest(self_test_port, leave_running);
    for (const std::string &line : result.lines) {
        ESP_LOGI(tag, "self-test: %s", line.c_str());
    }
    return result.passed;
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

bool engine_link_write_forced(int address, int32_t raw) {
    if (!running) {
        return false;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    const bool ok = image.set(address, raw, true);
    xSemaphoreGive(lock);
    return ok;
}

int engine_link_verify(int *registers, int32_t *wanted, int32_t *held,
                       int limit) {
    if (!running) {
        return -1;
    }
    return verify_image(registers, wanted, held, limit);
}

void engine_link_resend(void) {
    if (!running) {
        return;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    image.resend_all();
    xSemaphoreGive(lock);
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

bool engine_link_point(int partial, const int *pointers) {
    if (!running || partial < 0 || partial >= fpga_map::partial_count) {
        return false;
    }
    // Three pointers of ten bits to a quad, the fourth quad commits.
    std::array<fpga_map::quad_t, fpga_map::pointer_words> quads{};
    for (int k = 0; k < render::pointer_count; ++k) {
        quads[k / 3] |= (static_cast<fpga_map::quad_t>(pointers[k]) & 0x3FF)
                        << (10 * (k % 3));
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    spi_link::write(fpga_map::partial_base + static_cast<uint32_t>(partial) * fpga_map::partial_stride,
                    quads.data(), quads.size());
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
