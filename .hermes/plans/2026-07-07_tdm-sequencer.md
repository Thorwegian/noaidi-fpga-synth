# TDM Sequencer + BRAM Banking — Implementation Plan (#7)

> **For Hermes:** Use plan mode to draft, then implement task-by-task.

**Goal:** Time-division multiplex 16 voices through a single voice pipeline (coeff_computer → SVF), with dual-port BRAM banking for per-voice state storage and parameter access.

**Architecture:** A 16-slot TDM sequencer runs at 16 × 96 kHz = 1.536 MHz slot rate. Each slot: read voice state from BRAM → compute coefficients → run SVF → write state back → accumulate output. NEORV32 accesses the other BRAM port for parameter updates at control rate (~1 kHz).

**Tech Stack:** SystemVerilog, Gowin GW2AR-18, dual-port BRAM (SP), iverilog verification.

---

## Constraints

| Parameter | Value | Notes |
|-----------|-------|-------|
| Sample rate | 96 kHz | 1024 clock cycles per sample |
| Voices | 16 | time-multiplexed |
| Slot rate | 1.536 MHz | 64 cycles per slot @ 98.304 MHz |
| coeff_computer latency | ~13 cycles | fits comfortably in 64 |
| SVF | combinational | strobed once per slot |
| BRAM blocks available | ~12 (of 46) | after NEORV32 (18) + K LUT (6) + seed LUT (1) + misc |

## Cycle Budget Per Slot (64 cycles total)

| Step | Cycles |
|------|--------|
| Read voice state BRAM (s1, s2) | 2 |
| Read voice params BRAM (1/Q, cents) | 2 |
| coeff_computer pipeline | 13 |
| SVF combinational settle + strobe | 1 |
| Write voice state BRAM | 1 |
| Accumulate output | 1 |
| **Total** | **~20** |
| Margin | 44 cycles (ample) |

---

## Architecture

```
                    ┌──────────────────────────┐
                    │     TDM Sequencer         │
                    │  (slot counter 0-15)      │
                    └─────┬────────────────────┘
                          │ slot #
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
    ┌──────────┐   ┌──────────┐   ┌──────────┐
    │ State    │   │ Param    │   │ Output   │
    │ BRAM     │   │ BRAM     │   │ Acc      │
    │ s1,s2×16 │   │ 1/Q,c×16 │   │ mix×2    │
    └────┬─────┘   └────┬─────┘   └────▲─────┘
         │              │              │
         ▼              ▼              │
    ┌─────────────────────────────┐    │
    │    coeff_computer + SVF     │────┘
    │   (one pipeline, reused)    │
    └─────────────────────────────┘
              ▲
              │
    ┌─────────┴─────────┐
    │  NEORV32 (other   │
    │   BRAM port)       │
    └───────────────────┘
```

### BRAM Layout

**State BRAM** (16 × 36 bits, 2 BRAM blocks):
```
voice 0: {s1[17:0], s2[17:0]}
voice 1: {s1[17:0], s2[17:0]}
...
voice 15: {s1[17:0], s2[17:0]}
```
Dual-port: Port A = TDM pipeline (read/write), Port B = NEORV32 (read for debug)

**Param BRAM** (16 × 42 bits, 2 BRAM blocks):
```
voice 0: {1/Q[17:0], cents[23:0]}
voice 1: {1/Q[17:0], cents[23:0]}
...
```
Dual-port: Port A = TDM pipeline (read only), Port B = NEORV32 (read/write)

---

## Task 1: Slot Counter

**Objective:** 4-bit counter cycling 0-15, driven by a 1.536 MHz strobe (one slot every 64 clock cycles).

**Files:**
- Create: `rtl/src/voice/tdm_sequencer.sv`

**Details:**
- 4-bit counter reset to 0
- Slot strobe: every 64 cycles (counter div-by-64 from sys_clk)
- Output: `slot[3:0]`, `slot_strobe` (1-cycle pulse at slot rate)
- Wrap at 15 → 0

**Implementation:**
```systemverilog
module tdm_sequencer (
    input  logic        clk,
    input  logic        rst_n,
    output logic [3:0]  slot,
    output logic        slot_strobe    // 1-cycle pulse at start of each slot
);
    localparam SLOT_DIV = 64;
    reg [5:0] div_cnt;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) {slot, div_cnt} <= 0;
        else begin
            slot_strobe <= 0;
            if (div_cnt == SLOT_DIV - 1) begin
                div_cnt <= 0;
                slot <= slot + 1;
                slot_strobe <= 1;
            end else
                div_cnt <= div_cnt + 1;
        end
endmodule
```

**Verification:** iverilog testbench — verify slot cycles 0→15, slot_strobe fires once per 64 cycles, period = 64 × 10.17ns ≈ 651ns.

---

## Task 2: State BRAM (Dual-Port)

**Objective:** 16-entry dual-port BRAM storing SVF states (s1, s2) per voice.

**Files:**
- Create: `rtl/src/voice/voice_state_bram.sv`
- Test: `rtl/src/voice/tb_voice_state_bram.sv`

**Details:**
- 18-bit wide, 16 entries, true dual-port
- Port A: TDM read/write (connects to pipeline)
- Port B: NEORV32 read-only (debug)
- Gowin infers SP or SDP BRAM from address width + dual-port pattern
- Use `(* ram_style = "block" *)` to force BRAM inference

**Verification:** Write known values through Port A, read back same slot on next cycle. Read through Port B simultaneously.

---

## Task 3: Param BRAM (Dual-Port)

**Objective:** 16-entry dual-port BRAM for per-voice parameters (1/Q, cents).

**Files:**
- Create: `rtl/src/voice/voice_param_bram.sv`

**Details:**
- 42-bit wide, 16 entries
- Port A: TDM read-only (feeds coeff_computer)
- Port B: NEORV32 read/write (control updates)
- Packed: `{1/Q[17:0], cents[23:0]}`

**Verification:** NEORV32 writes values, TDM pipeline reads them. Cross-port consistency check.

---

## Task 4: Output Accumulator

**Objective:** Sum 16 voice outputs into stereo mix with per-voice gain.

**Files:**
- Create: `rtl/src/voice/output_mixer.sv`

**Details:**
- Simple accumulator: clear on sample_strobe, add SVF output each slot
- Stereo: mono for now (single accumulator), pan later
- Saturating add to prevent overflow (18-bit → saturate at ±16383)
- Output latched at end of slot 15 → I2S

**Verification:** Feed constant value per slot, verify accumulated sum = 16 × constant. Verify saturation at limits.

---

## Task 5: Top-Level Integration

**Objective:** Wire TDM sequencer, BRAMs, coeff_computer, SVF, and mixer in `voice_top.sv`.

**Files:**
- Create: `rtl/src/voice/voice_top.sv`
- Modify: `rtl/src/top.sv` (replace single-voice wiring with voice_top instance)
- Modify: `rtl/build.tcl`

**Details:**
```
voice_top:
  tdm_sequencer → slot number
  slot → voice_state_bram (read s1, s2)
  slot → voice_param_bram (read 1/Q, cents)
  s1, s2, 1/Q, cents → coeff_computer
  coeff output + osc → SVF
  SVF output → voice_state_bram (write s1, s2) + output_mixer
  output_mixer → I2S (on sample_strobe)
```

The osc input is shared across all 16 voices (no per-voice oscillator yet — that's a separate future task).

**Verification:** iverilog — run 16-voice pipeline, verify 16 unique outputs per sample. Gowin synthesis — check timing + BRAM/DSP counts.

---

## Task 6: Iverilog Full-Pipeline Test

**Objective:** End-to-end test of 16-voice TDM pipeline.

**Files:**
- Create: `rtl/src/voice/tb_tdm_pipeline.sv`

**Details:**
- Instantiate voice_top with test parameters
- Set different cents per voice via BRAM port B
- Run for multiple sample periods
- Verify each voice produces unique output
- Check BRAM read/write consistency across TDM slots

---

## Risks

1. **BRAM dual-port contention** — Port A reads and writes on the same cycle for the same address. Gowin BRAMs support read-before-write in this mode, but verify.
2. **Timing at 1.536 MHz slot rate** — 64 cycles is ample for 13-cycle coeff_computer, but SVF combinational path must settle within slot_strobe window. Same 40.7 MHz Fmax limitation applies.
3. **DSP sharing** — coeff_computer uses 1 DSP. NR uses multipliers (in LUTs or DSPs). At 1.5 MHz slot rate, all combinational paths settle between slots. No DSP contention.

## Open Questions

- Osc per voice? Currently shared osc. Per-voice phase accumulators need separate BRAM.
- Stereo pan? Add later — mono mixer for now, pan parameter sits unused in param BRAM.
- NEORV32 writes during TDM slot? Disable writes during active slot (slot 0-15) to prevent glitches. NEORV32 writes only between sample_strobe and first slot, or during idle periods.
