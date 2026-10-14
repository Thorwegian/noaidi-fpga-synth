; map.s -- the control program's registers and sinks
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; The definitions every part of the control program shares; the parts
; (lfo.s, channel.s, envelope.s, voice.s) hold only code, and the program is
; the parts after this file, in that order: csp sim map.s lfo.s channel.s
; envelope.s voice.s. docs/csp_isa.md section 5 has the regions.
;
;   0x000–0x03F  constants (the assembler allocates them)
;   0x040        the pass counter (I/O)
;   0x060–0x07F  globals: the LFOs' sets and a scratch word
;   0x080–0x1FF  the LFO pool: 32 records of 12 words
;   0x200–0x5FF  16 channels of 64 words
;   0x600–0x7FF  32 voices of 16 words
;   0x800–0x8FF  the sinks the program owns: 32 voices of 8 words
;   0x900–0xBFF  the sinks the firmware owns: 16 channels of 48 words
;
; Wide fields are at even offsets. A vector loop's iterations must not
; share registers, so every scratch word a loop uses is in its record; a
; field's name says what it holds in the loop that uses it, and a scratch
; field that two loops use for different things has a name for each.

; ---- constants -----------------------------------------------------------
        .const ONE, 1.0
        .const FULL, 1.0
        .const EIGHTH, 0.125
        .const FOUR, 4.0
        .const MINUS_FOUR, -4.0
        .const CORRECTION, 0.225
        .const ONE_MINUS_CORRECTION, 0.775

; ---- globals --------------------------------------------------------------
        .reg   PASS, 0x040          ; the pass counter
        .reg   PARITY, 0x060        ; scratch for the LFOs' half
        .reg   CHANNELS_IN_USE, 0x061   ; how many channels the program works out (the firmware's)
        .equ   LFO_SETS, 0x070

; the LFOs update every other pass, half of them each time (24 kHz): a set
; says where a half's records start and how many of each shape they are
        .block SET
        .field BASE, 1              ; address of the half's first record
        .field N_SAW, 1
        .field N_SQUARE, 1
        .field N_TRIANGLE, 1
        .field N_SINE, 1
        .field PAD, 3               ; a set is 8 words
        .end

; ---- the LFO pool -----------------------------------------------------------
        .equ   LFOS, 0x080
        .block LFO
        .field PHASE, 2             ; −8 … +8, wrapping: one cycle
        .field PHASE_STEP, 2        ; added to PHASE at each update
        .field DEPTH, 1
        .field NEG_DEPTH, 1
        .field GAIN, 1              ; DEPTH ÷ 8 (saw), DEPTH ÷ 4 (triangle)
        .field OUT, 1               ; the wave, ±depth
        .field P, 1                 ; scratch
        .field T, 1
        .field Z, 1
        .field SPARE, 1
        .end

; ---- the channels --------------------------------------------------------------
        .equ   CHANNELS, 0x200
        .block CHANNEL
        .field ENVELOPES, 28        ; the amp envelope's rows at +0, +4, +8; the mod's at +16, +20, +24
        .field BEND, 1              ; pitch bend, in octaves
        .field LFO1_PITCH, 1        ; LFO 1's depth on the pitch, in octaves
        .field LFO1_CUTOFF, 1       ;   and on the cutoff
        .field LFO2_PITCH, 1
        .field LFO2_CUTOFF, 1
        .field LFO1, 1              ; the address of LFO 1's record in the pool
        .field LFO2, 1
        .field CUTOFF_BASE, 1       ; the cutoff knob, the wheel…, in octaves
        .field KEY_TRACK, 1         ; 1.0: the cutoff follows the pitch
        .field MOD_AMOUNT, 1        ; the mod envelope's depth on the cutoff, in octaves
        .field VOLUME, 1            ; linear
        .field CH_PITCH, 1          ; bend and the pitch LFOs: added to every note
        .field CH_CUTOFF, 1         ; the cutoff, with the LFOs and the tracking of CH_PITCH
        .field TP, 1                ; scratch
        .field TC, 1
        .field LFO1_DUTY, 1         ; LFO 1's depth on the pulse width, 1.0 being the rail
        .field LFO2_DUTY, 1
        .field LFO1_RESONANCE, 1    ;   and on the resonance, in octaves of Q
        .field LFO2_RESONANCE, 1
        .field DUTY_BASE_0, 1       ; each oscillator's pulse width, before the LFOs
        .field DUTY_BASE_1, 1
        .field RESONANCE_BASE, 1    ; the resonance knob, in octaves of Q
        .field SINK_BLOCK, 1        ; the address of the channel's sinks (below)
        .field TD, 1                ; scratch
        .field TR, 1
        .field SPARE_CHANNEL, 11    ; a channel is 64 words
        .end

; ---- the envelopes ----------------------------------------------------------------
        .block SEGMENT
        .field TARGET, 2
        .field RATE, 2
        .end

; ---- the voices -------------------------------------------------------------------
        .equ   VOICES, 0x600
        .block VOICE
        .field LEVEL_A, 2           ; 0: the amp envelope's level
        .field STAGE_A, 1           ; 2: its row's offset in the channel's table
        .field GATE, 1              ; 3
        .field VELOCITY, 1          ; 4
        .field CHANNEL, 1           ; 5: the address of the voice's channel
        .field U_A, 1               ; 6: scratch; the voice's pitch
        .field U_M, 1               ; 7: scratch; the voice's cutoff
        .field LEVEL_M, 2           ; 8: the mod envelope's level
        .field STAGE_M, 1           ; 10
        .field OUT_A, 1             ; 11: level × velocity
        .field D, 1                 ; 12: scratch; the voice's gain
        .field OUT_M, 1             ; 13
        .field NOTE, 1              ; 14: in octaves
        .field SINK, 1              ; 15: the address of the voice's sinks
        .end

; ---- the sinks -----------------------------------------------------------------------
        .equ   SINKS, 0x800
        .block VOICE_SINKS
        .field SINK_PITCH, 1
        .field SINK_CUTOFF, 1
        .field SINK_GAIN, 1
        .field SINK_SPARE, 5
        .end

; The channels' sinks are mostly the firmware's: what only a MIDI message
; moves (docs/memory_map.md). A partial points at its voice's sinks above
; and at its channel's here: one word for each of its oscillator and unison
; positions (eight, two oscillators of four) for the detune, the cutoff's
; offset and the gain of each side, and one for each oscillator's mode. The
; firmware writes them through the queue (to both pages of the sink area).
; The duty and the resonance are the program's, since LFOs move them
; (channel.s): the firmware sets their bases in the channel's registers.
        .equ   CHANNEL_SINKS, 0x900
        .block CHANNEL_SINK
        .field DETUNE, 8            ; pitch: the oscillator's tune and the unison spread, in octaves
        .field CUTOFF_OFFSET, 8     ; cutoff: the tracking of tune and spread, in octaves
        .field GAIN_LEFT, 8         ; the pan, the spread and the oscillator mix, linear
        .field GAIN_RIGHT, 8
        .field DUTY_0, 1            ; per oscillator: 1.0 is the rail (the program's: base and LFOs)
        .field DUTY_1, 1
        .field MODE_0, 1            ; per oscillator: waveform [1:0], cascade [2], filter type [4:3]
        .field MODE_1, 1
        .field RESONANCE, 1         ; octaves of Q above Butterworth (the program's, like the duty)
        .field SPARE_SINKS, 11      ; a channel's block is 48 words
        .end

; The last word of the last block, 0xBFF, is nobody's: it stays 0. A
; partial that points nowhere points at it, and is silent.
        .equ   ZERO_SINK, 0xBFF
