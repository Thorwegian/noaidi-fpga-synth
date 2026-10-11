// patch_units_test.c — host test: every raw value of every patch file
// key loads back exactly from the value the writer gives it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// For each key and each raw value its patch_t field can hold, the test
// writes the value as the writer does, reads the text back as the
// loader does, and checks
//   - the loaded raw value is the canonical form of the written one, and
//   - the canonical form is stable (writing and loading it again changes
//     nothing),
// which together make load → save → load exact. Keys whose conversion
// depends on another key (decay on sustain, LFO depth on destination)
// are checked across that key's values.
//
// Then it writes the default patch (patch_default) as a patch file,
// reads it back, and reads the factory file given as the argument; both
// must equal the default patch. The written file is printed, so the
// factory file can be made from it.
//
//   make fw-test

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "patch.h"
#include "patch_file.h"
#include "patch_units.h"

static int s_failures;

// What the loader does with one written value.
static void load_text(const patch_field_t *f, int i, patch_t *p, const char *text)
{
    if (f->kind == PF_NAME) {
        char name[32];
        size_t n = strlen(text);
        snprintf(name, sizeof name, "%.*s", (int)(n - 2), text + 1);   // strip quotes
        patch_field_set_name(f, i, p, name);
        return;
    }
    double v = strcmp(text, "inf") == 0  ?  INFINITY
             : strcmp(text, "-inf") == 0 ? -INFINITY
             : strtod(text, NULL);
    patch_field_set_number(f, i, p, v);
}

static void check_raw(const patch_field_t *f, int i, patch_t *p, int32_t raw)
{
    f->set(p, i, raw);
    raw = f->get(p, i);                         // as the field stores it
    int32_t canon = patch_field_canonical(f, i, p, raw);

    char text[64];
    patch_field_format(f, i, p, text, sizeof text);
    load_text(f, i, p, text);
    int32_t loaded = f->get(p, i);

    char again[64];
    patch_field_format(f, i, p, again, sizeof again);
    load_text(f, i, p, again);
    int32_t reloaded = f->get(p, i);

    if (loaded != canon || reloaded != loaded || strcmp(text, again) != 0) {
        if (s_failures < 20)
            printf("FAIL %s.%s[%d]: raw %ld -> \"%s\" -> %ld (canonical %ld), "
                   "again \"%s\" -> %ld\n", f->table, f->key, i, (long)raw, text,
                   (long)loaded, (long)canon, again, (long)reloaded);
        s_failures++;
    }
}

// The raw values a field can hold.
static void raw_range(const patch_field_t *f, int32_t *lo, int32_t *hi)
{
    const char *k = f->key;
    if (f->kind == PF_NAME) {
        int32_t n = 0;
        while (f->names[n]) n++;
        *lo = 0; *hi = n - 1;
    } else if (!strcmp(k, "pulse_width")) {
        *lo = -8388608; *hi = 8388608;
    } else if (!strcmp(k, "attack") || !strcmp(k, "decay") || !strcmp(k, "release")
            || !strcmp(k, "velocity") || !strcmp(k, "volume") || !strcmp(k, "bend_range")) {
        *lo = 0; *hi = 255;
    } else if (!strcmp(k, "sustain")) {
        *lo = 0; *hi = 1023;
    } else if (!strcmp(k, "osc_mix") || !strcmp(k, "pan")) {
        *lo = -128; *hi = 127;
    } else if (!strcmp(k, "slope")) {
        *lo = 0; *hi = 1;
    } else if (!strcmp(k, "rate")) {
        *lo = 0; *hi = 65535;
    } else if (!strcmp(k, "resonance")) {
        *lo = 0; *hi = 0x3FFF;
    } else {
        *lo = -32768; *hi = 32767;                 // int16 fields
    }
}

// Every raw value for the first element. The conversions are the same
// for every element, so later elements only check the accessor, on a
// spread of values.
static void check_field(const patch_field_t *f, int i, patch_t *p)
{
    int32_t lo, hi;
    raw_range(f, &lo, &hi);
    int32_t step = (i == 0) ? 1 : (hi - lo) / 997 + 1;
    for (int32_t r = lo; r <= hi; r += step)
        check_raw(f, i, p, r);
}

int main(int argc, char **argv)
{
    size_t n;
    const patch_field_t *fields = patch_fields(&n);
    patch_t p;

    for (size_t k = 0; k < n; k++) {
        const patch_field_t *f = &fields[k];
        for (int i = 0; i < f->count; i++) {
            patch_default(&p);
            if (!strcmp(f->key, "decay")) {
                // decay depends on its envelope's sustain
                int env = !strcmp(f->table, "amp_env") ? 0 : 1;
                for (int s = 0; s <= 1023; s += (s < 960 ? 64 : 1)) {
                    p.env[env].sustain = (uint16_t)s;
                    check_field(f, i, &p);
                }
            } else if (!strcmp(f->table, "lfo") && !strcmp(f->key, "depth")) {
                for (uint8_t d = 0; d < 4; d++) {
                    p.lfo[i].dest = d;
                    check_field(f, i, &p);
                }
            } else {
                check_field(f, i, &p);
            }
        }
        printf("%-8s %-14s %s\n", f->table, f->key, s_failures ? "..." : "ok");
    }

    // The default patch, written and read back.
    patch_t def, back, factory;
    patch_default(&def);
    char *text = NULL;
    size_t text_len = 0;
    FILE *mem = open_memstream(&text, &text_len);
    patch_file_write(mem, &def);
    fclose(mem);
    char err[200];
    if (!patch_file_parse(text, text_len, &back, err, sizeof err)) {
        printf("FAIL reading the written default patch: %s\n", err);
        s_failures++;
    } else if (patch_file_diff(stdout, &def, &back) != 0) {
        printf("FAIL the written default patch reads back different (above)\n");
        s_failures++;
    }
    printf("\ndefault patch, as written:\n%s", text);
    free(text);

    // The factory file must hold the default patch.
    if (argc > 1) {
        if (!patch_file_read(argv[1], &factory, err, sizeof err)) {
            printf("FAIL %s: %s\n", argv[1], err);
            s_failures++;
        } else if (patch_file_diff(stdout, &def, &factory) != 0) {
            printf("FAIL %s differs from the default patch (above)\n", argv[1]);
            s_failures++;
        } else {
            printf("\n%s: equals the default patch\n", argv[1]);
        }
    }

    printf("\n%s (%d failures)\n", s_failures ? "FAIL" : "ALL PASS", s_failures);
    return s_failures ? 1 : 0;
}
