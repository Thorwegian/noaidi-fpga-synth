// patch.c — the active-patch instance and its default (issue #69).
//
// Foundation of the VA surface: g_patch is the single source of
// truth for the active sound. patch_default() reproduces the former
// hardcoded timbre EXACTLY, so wiring voice_alloc to render from it
// is behavior-identical (verify: sounds the same). Later issues move
// more constants into the struct and add CC/SysEx mutation.

#include "patch.h"
#include <string.h>

patch_t g_patch;

// Pack an ADSR into the producer RATES word (A | D<<8 | S<<16 | R<<24)
// — the gateware's universal A,D,S,R byte order.
uint32_t patch_adsr_word(const adsr_t *e)
{
    return (uint32_t)e->attack
         | ((uint32_t)e->decay   << 8)
         | ((uint32_t)e->sustain << 16)
         | ((uint32_t)e->release << 24);
}

void patch_default(patch_t *p)
{
    memset(p, 0, sizeof(*p));

    // ---- values that reproduce the pre-#69 hardcoded timbre ----
    p->osc[0].wave = WAVE_SAW;
    p->osc[1].wave = WAVE_SAW;
    // voice_struct/unison spread are not rendered yet (issue #72);
    // today's 8-detuned-elements organ layout stays in voice_alloc's
    // DETUNE table until then.
    p->voice_struct = VOICE_7_PLUS_1;

    p->filter.resonance = 0x200;       // was RESO (q1 = 1.0)
    p->filter.type      = 0;           // LP
    p->filter.dual      = 0;           // 12 dB

    // amp env — was ADSR_RATES (0x98/0x20/0xF0/0x28, A,D,S,R)
    p->env[0].attack  = 0x98;
    p->env[0].decay   = 0x20;
    p->env[0].sustain = 0xF0;
    p->env[0].release = 0x28;
    // MOD env (#42) not rendered yet; leave zeroed.

    // LFO 1 = the boot vibrato (source 0): 1 Hz triangle, ±19 cents
    p->lfo[0].shape = 2;               // triangle
    p->lfo[0].rate  = 175;             // ~1 Hz
    p->lfo[0].depth = 16;

    p->volume     = 0xCF;              // was VOL_BASE (~-18 dB as volume)
    p->bend_range = 2;                 // current ±2 semitones
}
