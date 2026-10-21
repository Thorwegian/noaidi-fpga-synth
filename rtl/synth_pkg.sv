// synth_pkg.sv — shared design parameters
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The single home for the design's constants; no module carries
// hardcoded numbers. Modules import what they need, and module
// parameters default from here so testbenches can still override.

package synth_pkg;

    parameter int SAMPLE_RATE = 96000;
    // 768 x 96 kHz. Not ~100 MHz: at that clock the 36x36 DSP cascades
    // fail on silicon although STA passes, and the extra slack protects
    // paths that STA does not flag.
    parameter int SYS_CLK_HZ  = 73_728_000;

    //--- Timebase (TDM) scheduling ---------------------------------
    parameter int CYCLES_PER_SAMPLE  = 768;    // SYS_CLK_HZ / SAMPLE_RATE
    parameter int TIMEBASE_W       = 10;     // $clog2(CYCLES_PER_SAMPLE)
    parameter int CELL_DIV     = 6;      // SPDIF cell = 6 sysclk (768 = 128 x 6)

    //--- Partials and issue slots (design doc terminology) ----------
    // The FPGA generates PARTIALS (256 of them), one per issue slot
    // through the time-division-multiplexed partial pipeline. The
    // ESP32 groups partials into voices; the FPGA never sees that.
    parameter int NUM_PARTIALS = 256;
    parameter int PARTIAL_W       = 8;      // $clog2(NUM_PARTIALS)
    parameter int UNISON       = 8;      // firmware convention only
    parameter int POLYPHONY    = 32;     // firmware convention only

    //--- The wire (docs/memory_map.md, conventions) ------------------
    // Every block RAM on the chip is 9, 18 or 36 bits wide, so the SPI
    // link is too: a 9-bit command nonet, an 18-bit address in 36-bit
    // dwords, and 36-bit payload dwords. Nothing straddles a boundary.
    parameter int SPI_NONET_W  = 9;
    parameter int SPI_ADDRESS_W = 18;
    parameter int SPI_DWORD_W    = 36;
    parameter int SPI_NONETS_PER_DWORD = SPI_DWORD_W / SPI_NONET_W;   // 4
    parameter logic [SPI_NONET_W-1:0] SPI_ID_NONET = 9'h0A5;      // MISO's first nonet, every frame

    // The system registers: sixteen dwords at the bottom of the map.
    parameter logic [SPI_ADDRESS_W-1:0] MAP_CTRL = 18'h00002;
    // CTRL's bits: [0] commit the write FIFO (an event), [1] hold the CSP,
    // [2] the test tone on the outputs, [3] the data stream on the 48 kHz
    // S/PDIF output, [5:4] the stream's source.
    parameter int CTRL_SWAP        = 0;
    parameter int CTRL_HOLD        = 1;
    parameter int CTRL_TEST_TONE   = 2;
    parameter int CTRL_DATA_STREAM = 3;
    parameter int CTRL_SOURCE_LOW  = 4;
    parameter int CTRL_SOURCE_HIGH = 5;
    parameter int MAP_SYSTEM_DWORDS = 16;
    parameter int MAP_STORED_DWORDS = 8;         // 0x0–0x7 are kept and read back; 0x8–0xF are status
    parameter int MAP_DIAG_PASS    = 8;         // status dword: the passes since reset
    parameter int MAP_DIAG_QUEUE   = 9;         // status dword: the FIFO's Gray read pointer, [10] full
    parameter int MAP_DIAG_LIMITER = 10;        // status dword: the master limiter (with the output, #236)
    parameter int MAP_DIAG_DROPPED = 11;        // status dword: writes dropped at a full FIFO
    parameter logic [SPI_ADDRESS_W-1:0] MAP_PROBE_ADDRESS = 18'h0000C;   // the pair the probe reads
    parameter int MAP_PROBE_EVEN   = 13;        // status dword: the pair's even register
    parameter int MAP_PROBE_ODD    = 14;        //   and its odd one
    parameter int MAP_DIAG_STREAM  = 15;        // status dword: the stream's frames sent since reset

    // The regions beyond the system dwords (docs/memory_map.md, the map).
    parameter logic [SPI_ADDRESS_W-1:0] MAP_FIFO_DOOR = 18'h06000;   // the write FIFO's door
    parameter logic [SPI_ADDRESS_W-1:0] MAP_IMEM_BASE = 18'h08000;   // IMEM: two dwords a row
    parameter logic [SPI_ADDRESS_W-1:0] MAP_ROM_BASE  = 18'h09000;   // the decode ROM: one dword a row
    parameter logic [SPI_ADDRESS_W-1:0] MAP_LAB_BASE  = 18'h0A000;   // the lab's counters (#241): read-only, one dword each
    parameter int MAP_LAB_DWORDS = 64;

    //--- The S/PDIF data stream (rtl/spdif/spdif_stream.sv) -----------
    // A frame is 64 samples of 32 bits: the sync word, the sequence word,
    // 61 payload words, the CRC of the first 63.
    parameter int STREAM_FRAME_WORDS = 64;
    parameter logic [31:0] STREAM_SYNC = 32'hB7E1_5A3C;
    parameter logic [31:0] STREAM_CRC_POLYNOMIAL = 32'h04C1_1DB7;  // IEEE 802.3, MSB first, no final inversion
    parameter logic [31:0] STREAM_LFSR_SEED = 32'h0000_0001;
    // The payload sources, chosen by CTRL[5:4].
    parameter logic [1:0] STREAM_SOURCE_LFSR    = 2'd0;   // a 32-bit maximal LFSR, 32 steps a word
    parameter logic [1:0] STREAM_SOURCE_COUNTER = 2'd1;   // the pass counter
    parameter logic [1:0] STREAM_SOURCE_PROBE   = 2'd2;   // the probe's pair: even and odd words alternating

    //--- Partial sinks (docs/csp2_architecture.md, the sink area) ------
    // A partial reads ten sink words, named by ten pointers into the sink
    // area, over two cycles. Words are Q4.14; pitch and cutoff are
    // octaves from the reference below, the gains linear.
    parameter int POINTER_W            = 10;    // $clog2(sink words)
    parameter int POINTERS_PER_PARTIAL = 10;
    // The last word of the sink area, which nobody writes: always zero.
    parameter logic [9:0] POINTER_ZERO = 10'h3FF;
    parameter int POINTER_ENTRY_W      = POINTER_W * POINTERS_PER_PARTIAL;
    parameter int CYCLES_PER_PARTIAL   = 2;
    parameter int SINK_READ_PORTS      = 6;     // a cycle's worth of the sink area
    // The pointers of a partial, by position in its entry.
    parameter int POINTER_PITCH_VOICE   = 0;    // the voice's pitch
    parameter int POINTER_PITCH_CHANNEL = 1;    //   and the oscillator's detune
    parameter int POINTER_CUTOFF_VOICE  = 2;
    parameter int POINTER_CUTOFF_CHANNEL = 3;   // the tracking of tune and detune
    parameter int POINTER_GAIN_VOICE    = 4;    // envelope × velocity
    parameter int POINTER_GAIN_LEFT     = 5;    // the channel's side of it
    parameter int POINTER_GAIN_RIGHT    = 6;
    parameter int POINTER_DUTY          = 7;
    parameter int POINTER_RESONANCE     = 8;
    parameter int POINTER_MODE          = 9;    // waveform, cascade, filter type
    // Octave zero of the pitch and cutoff sinks: middle C (MIDI note 60),
    // in the pipeline's UQ4.10 log2 pitch.
    parameter logic [13:0] PITCH_REFERENCE = 14'h1400;

    //--- Filter stability clamp --------------------------------------
    // Instability comes from HEAVY DAMPING (low Q = high q1), not
    // from resonance — theory and the autocorrelation bench agree.
    //
    //   FC_MAX = 0x2B20 = 14.4 kHz: one measured-clean step of
    //   margin below the resonance bloom that precedes the
    //   16 kHz wall. Measured at q1 = sqrt(2), the heaviest damping
    //   any resonance code decodes to: clean through 15.7 kHz,
    //   limit-cycles at 16.4 kHz, chaos at 19.5 kHz.
    //
    // No separate q1 clamp is needed: with log2-encoded resonance
    // (r octaves of Q above Butterworth, q1 = sqrt2 * 2^-r via
    // q1_lut), r = 0 IS Butterworth and no code decodes heavier, so
    // the sqrt(2) bound is structural. The high-Q
    // end stays open by design: at the top of the range the decode
    // underflows q1 to zero — self-oscillation as a feature.
    parameter logic [13:0] FC_MAX = 14'h2B20;

    //--- Number formats (design doc) ---------------------------------
    parameter int OSC_W = 24;       // UQ0.24 phase accumulator
    typedef logic signed [OSC_W-1:0] osc_t;

    parameter int CTRL_W = 14;      // UQ4.10 pitch/cutoff

    parameter int AUDIO_W = 18;     // Q4.14 audio transport
    typedef logic signed [AUDIO_W-1:0] sample_t;

    parameter int SVF_W = 36;       // Q8.28 filter states

    parameter int AUDIO_SHIFT = 14;

endpackage
