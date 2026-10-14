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
        .field SPARE_CHANNEL, 21    ; a channel is 64 words
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
