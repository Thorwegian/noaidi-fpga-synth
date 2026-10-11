// param_text.h — how the display names and writes parameter values
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The display's own labels and number formats. The companion has the same
// for its Editor (companion/src/display/parameters.ts); the two are
// written separately for now.

#pragma once

#include <stddef.h>

#include "noaidi_param_ids.h"

// Short label for a parameter on its own screen ("Cutoff"), "" for NONE.
const char *param_text_label(noaidi_param_t param);

// The value as shown: a number value in its unit ("2.40 kHz") or a name
// value as a short label ("LP"). name is NULL for number parameters.
void param_text_value(noaidi_param_t param, double value, const char *name,
                      char *buf, size_t len);
