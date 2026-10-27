// param_text.c — labels and number formats (see param_text.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Montserrat as LVGL builds it has ASCII only: "-" not a minus sign, no ∞.

#include "param_text.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

const char *param_text_label(noaidi_param_t param) {
    switch (param) {
    case NOAIDI_PARAM_VOICE_STRUCTURE:
        return "Structure";
    case NOAIDI_PARAM_VOICE_OSC_MIX:
        return "Osc mix";
    case NOAIDI_PARAM_VOICE_UNISON_DETUNE:
        return "Detune";
    case NOAIDI_PARAM_VOICE_UNISON_STEREO:
        return "Stereo";
    case NOAIDI_PARAM_OSC0_WAVE:
        return "Osc 1 wave";
    case NOAIDI_PARAM_OSC1_WAVE:
        return "Osc 2 wave";
    case NOAIDI_PARAM_OSC0_TUNE:
        return "Osc 1 tune";
    case NOAIDI_PARAM_OSC1_TUNE:
        return "Osc 2 tune";
    case NOAIDI_PARAM_OSC0_PULSE_WIDTH:
        return "Osc 1 PW";
    case NOAIDI_PARAM_OSC1_PULSE_WIDTH:
        return "Osc 2 PW";
    case NOAIDI_PARAM_FILTER_TYPE:
        return "Type";
    case NOAIDI_PARAM_FILTER_SLOPE:
        return "Slope";
    case NOAIDI_PARAM_FILTER_CUTOFF:
        return "Cutoff";
    case NOAIDI_PARAM_FILTER_RESONANCE:
        return "Resonance";
    case NOAIDI_PARAM_FILTER_KEY_TRACK:
        return "Key track";
    case NOAIDI_PARAM_AMP_ENV_ATTACK:
        return "Attack";
    case NOAIDI_PARAM_AMP_ENV_SUSTAIN:
        return "Sustain";
    case NOAIDI_PARAM_AMP_ENV_DECAY:
        return "Decay";
    case NOAIDI_PARAM_AMP_ENV_RELEASE:
        return "Release";
    case NOAIDI_PARAM_AMP_ENV_VELOCITY:
        return "Velocity";
    case NOAIDI_PARAM_MOD_ENV_ATTACK:
        return "Mod attack";
    case NOAIDI_PARAM_MOD_ENV_SUSTAIN:
        return "Mod sustain";
    case NOAIDI_PARAM_MOD_ENV_DECAY:
        return "Mod decay";
    case NOAIDI_PARAM_MOD_ENV_RELEASE:
        return "Mod release";
    case NOAIDI_PARAM_MOD_ENV_VELOCITY:
        return "Mod velocity";
    case NOAIDI_PARAM_MOD_ENV_DESTINATION:
        return "Mod dest";
    case NOAIDI_PARAM_MOD_ENV_DEPTH:
        return "Env depth";
    case NOAIDI_PARAM_LFO0_SHAPE:
        return "LFO 1 shape";
    case NOAIDI_PARAM_LFO1_SHAPE:
        return "LFO 2 shape";
    case NOAIDI_PARAM_LFO0_RATE:
        return "LFO 1 rate";
    case NOAIDI_PARAM_LFO1_RATE:
        return "LFO 2 rate";
    case NOAIDI_PARAM_LFO0_DESTINATION:
        return "LFO 1 dest";
    case NOAIDI_PARAM_LFO1_DESTINATION:
        return "LFO 2 dest";
    case NOAIDI_PARAM_LFO0_DEPTH:
        return "LFO 1 depth";
    case NOAIDI_PARAM_LFO1_DEPTH:
        return "LFO 2 depth";
    case NOAIDI_PARAM_PART_VOLUME:
        return "Volume";
    case NOAIDI_PARAM_PART_PAN:
        return "Pan";
    case NOAIDI_PARAM_PART_BEND_RANGE:
        return "Bend range";
    default:
        return "";
    }
}

static const char *name_label(const char *name) {
    static const char *const map[][2] = {
            {"lowpass", "LP"},  {"bandpass", "BP"},    {"highpass", "HP"},
            {"saw", "Saw"},     {"pulse", "Pulse"},    {"triangle", "Tri"},
            {"sine", "Sine"},   {"pulse_width", "PW"}, {"resonance", "Res"},
            {"pitch", "Pitch"}, {"cutoff", "Cutoff"},
    };
    for (size_t k = 0; k < sizeof map / sizeof map[0]; k++) {
        if (strcmp(map[k][0], name) == 0) {
            return map[k][1];
        }
    }
    return name;
}

static void hz(double v, char *buf, size_t len) {
    if (v >= 10000) {
        snprintf(buf, len, "%.1f kHz", v / 1000);
    } else if (v >= 1000) {
        snprintf(buf, len, "%.2f kHz", v / 1000);
    } else if (v >= 100) {
        snprintf(buf, len, "%.0f Hz", v);
    } else if (v >= 10) {
        snprintf(buf, len, "%.1f Hz", v);
    } else {
        snprintf(buf, len, "%.2f Hz", v);
    }
}

static void seconds(double v, char *buf, size_t len) {
    if (v < 0.01) {
        snprintf(buf, len, "%.2f ms", v * 1000);
    } else if (v < 1) {
        snprintf(buf, len, "%.0f ms", v * 1000);
    } else if (v < 10) {
        snprintf(buf, len, "%.2f s", v);
    } else {
        snprintf(buf, len, "%.1f s", v);
    }
}

void param_text_value(noaidi_param_t param, double value, const char *name,
                      char *buf, size_t len) {
    if (name) {
        snprintf(buf, len, "%s", name_label(name));
        return;
    }
    if (isnan(value)) {
        snprintf(buf, len, "--");
        return;
    }
    switch (param) {
    case NOAIDI_PARAM_FILTER_CUTOFF:
    case NOAIDI_PARAM_LFO0_RATE:
    case NOAIDI_PARAM_LFO1_RATE:
        hz(value, buf, len);
        break;
    case NOAIDI_PARAM_FILTER_RESONANCE:
        if (isinf(value)) {
            snprintf(buf, len, "Self-osc");
        } else {
            snprintf(buf, len, "Q %.2f", value);
        }
        break;
    case NOAIDI_PARAM_FILTER_SLOPE:
        snprintf(buf, len, "%.0f dB", value);
        break;
    case NOAIDI_PARAM_AMP_ENV_ATTACK:
    case NOAIDI_PARAM_AMP_ENV_DECAY:
    case NOAIDI_PARAM_AMP_ENV_RELEASE:
    case NOAIDI_PARAM_MOD_ENV_ATTACK:
    case NOAIDI_PARAM_MOD_ENV_DECAY:
    case NOAIDI_PARAM_MOD_ENV_RELEASE:
        seconds(value, buf, len);
        break;
    case NOAIDI_PARAM_AMP_ENV_SUSTAIN:
    case NOAIDI_PARAM_PART_VOLUME:
        if (isinf(value)) {
            snprintf(buf, len, "Off");
        } else {
            snprintf(buf, len, "%+.1f dB", value);
        }
        break;
    case NOAIDI_PARAM_OSC0_TUNE:
    case NOAIDI_PARAM_OSC1_TUNE:
    case NOAIDI_PARAM_MOD_ENV_DEPTH:
        snprintf(buf, len, "%+.2f st", value);
        break;
    case NOAIDI_PARAM_PART_BEND_RANGE:
        snprintf(buf, len, "+-%.0f st", value);
        break;
    case NOAIDI_PARAM_LFO0_DEPTH:
    case NOAIDI_PARAM_LFO1_DEPTH:
        snprintf(buf, len, "%+.2f", value); // unit follows the destination
        break;
    default: // percentages
        snprintf(buf, len, "%.0f %%", value);
        break;
    }
}
