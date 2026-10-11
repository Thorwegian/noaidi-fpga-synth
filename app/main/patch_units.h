// patch_units.h — the patch file's keys and their musical units
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One table, patch_fields(), lists every key a patch file holds
// (docs/storage_format.md "Patch files"): its TOML table and key, its
// unit, its range, and how a value converts to and from the raw value in
// patch_t. The loader and the writer both work from it, so the two
// directions cannot drift apart.
//
// Conversions run in double: pulse_width needs 8 significant digits to
// reach every raw value, more than a float holds. A value converts to
// the nearest raw value and clamps to the key's range; a raw value is
// written as the shortest decimal that converts back to it. Where
// several raw values behave identically (rate codes that share a
// coefficient, decays that run one raw step per sample), the lowest
// stands for all of them, so load → save → load is exact.
//
// Some conversions depend on another key of the same patch: decay
// depends on its envelope's sustain, and an LFO's depth on its
// destination. The table lists those keys first, and the loader
// applies values in table order.
//
// No ESP-IDF dependencies: the host test (app/test) compiles this file
// as it is.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "patch.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    PF_NUMBER,      // a float or integer in the key's unit
    PF_NAME,        // a string from the key's name list
} pf_kind_t;

typedef struct patch_field {
    const char *table;          // TOML table: "voice", "osc", "filter", ...
    const char *key;
    pf_kind_t   kind;
    uint8_t     count;          // 1, or PATCH_NUM_OSC / PATCH_NUM_LFO for
                                // the [[osc]] and [[lfo]] arrays of tables
    bool        integer;        // PF_NUMBER written without decimals
    const char *const *names;   // PF_NAME: names by raw value, NULL-ended
    // The raw value in patch_t, element i of the array.
    int32_t (*get)(const patch_t *p, int i);
    void    (*set)(patch_t *p, int i, int32_t raw);
    // PF_NUMBER conversions. to_raw clamps to the key's range and returns
    // the canonical raw value (see above).
    double  (*to_value)(const patch_t *p, int i, int32_t raw);
    int32_t (*to_raw)(const patch_t *p, int i, double value);
} patch_field_t;

// The keys, in the order the loader applies them.
const patch_field_t *patch_fields(size_t *count);

// Set element i of field f from a file value: a number for PF_NUMBER
// (±inf allowed where the key has it), ignored for PF_NAME.
void patch_field_set_number(const patch_field_t *f, int i, patch_t *p, double value);

// Set element i of PF_NAME field f from a name. False if the name is
// unknown; the field keeps its value.
bool patch_field_set_name(const patch_field_t *f, int i, patch_t *p, const char *name);

// Write element i of field f as TOML: a quoted name, "inf"/"-inf", or the
// shortest decimal that loads back to the same raw value. Returns the
// length, as snprintf does.
int patch_field_format(const patch_field_t *f, int i, const patch_t *p,
                       char *buf, size_t len);

// The canonical form of a raw value: what loading its written value
// gives. Equal to the raw value except where several behave identically.
int32_t patch_field_canonical(const patch_field_t *f, int i, const patch_t *p, int32_t raw);

#ifdef __cplusplus
}
#endif
