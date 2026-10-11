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
// Then it writes the init patch (patch_init) as a patch file and reads it
// back, which must give the init patch. Each factory file given as an
// argument must read, and must already hold the writer's own text for
// its values (comment lines aside), so it reads back exactly. Last,
// saving, recovery from an interrupted save, and patch-name rules.
//
//   make fw-test

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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

static void fail(const char *what)
{
    printf("FAIL %s\n", what);
    s_failures++;
}

static bool exists(const char *path)
{
    return access(path, F_OK) == 0;
}

static void write_text(const char *path, const char *text)
{
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}

// Save, the four interrupted-save cases, and names.
static void check_saving(void)
{
    char dir[] = "/tmp/noaidi_save_XXXXXX";
    if (!mkdtemp(dir)) { fail("mkdtemp"); return; }
    char a[320], a_new[340], b[320], b_new[340], err[200];
    snprintf(a, sizeof a, "%s/A.toml", dir);
    snprintf(a_new, sizeof a_new, "%s.new", a);
    snprintf(b, sizeof b, "%s/B.toml", dir);
    snprintf(b_new, sizeof b_new, "%s.new", b);

    patch_t init, other, back;
    patch_init(&init);
    patch_init(&other);
    other.filter.resonance = 1024;

    // a plain save: the file reads back, no .new remains
    if (!patch_file_save(a, &init, err, sizeof err)) fail(err);
    if (!patch_file_read(a, &back, err, sizeof err) || patch_file_diff(stdout, &init, &back))
        fail("saved patch does not read back");
    if (exists(a_new)) fail("save left a .new file");

    // a complete .new beside the old patch: the save finishes
    char *text; size_t len;
    FILE *m = open_memstream(&text, &len);
    patch_file_write(m, &other);
    fputs("# end\n", m);
    fclose(m);
    write_text(a_new, text);
    patch_file_recover(dir);
    if (exists(a_new) || !patch_file_read(a, &back, err, sizeof err) ||
        patch_file_diff(stdout, &other, &back))
        fail("complete .new beside the old patch was not finished");

    // an incomplete .new beside the old patch: the old patch stays
    write_text(a_new, "format = 1\n[filter]\nresonance = 4\n");
    patch_file_recover(dir);
    if (exists(a_new) || !patch_file_read(a, &back, err, sizeof err) ||
        patch_file_diff(stdout, &other, &back))
        fail("incomplete .new beside the old patch was not undone");

    // a complete .new with no old patch: it becomes the patch
    write_text(b_new, text);
    patch_file_recover(dir);
    if (exists(b_new) || !exists(b)) fail("complete new .new was not renamed");

    // an incomplete .new with no old patch: deleted, no patch appears
    remove(b);
    write_text(b_new, "format = 1\n");
    patch_file_recover(dir);
    if (exists(b_new) || exists(b)) fail("incomplete new .new was not deleted");
    free(text);

    remove(a);
    rmdir(dir);

    // names
    const char *good[] = { "Arctic Ice", "Ærlig Gjøk", "RnB Whistle", "a",
        "1234567890123456789012345678901234567890123456789012345678901234" };
    const char *bad[] = { "", " lead", "lead ", "lead.", "a/b", "a\\b", "what?",
        "x:y", "q\"", "<a>", "pipe|", "tab\t",
        "12345678901234567890123456789012345678901234567890123456789012345" };
    for (size_t i = 0; i < sizeof good / sizeof good[0]; i++)
        if (!patch_name_valid(good[i])) { printf("FAIL name \"%s\" rejected\n", good[i]); s_failures++; }
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++)
        if (patch_name_valid(bad[i])) { printf("FAIL name \"%s\" accepted\n", bad[i]); s_failures++; }
    printf("saving, recovery, names: %s\n", s_failures ? "see above" : "ok");
}

int main(int argc, char **argv)
{
    size_t n;
    const patch_field_t *fields = patch_fields(&n);
    patch_t p;

    for (size_t k = 0; k < n; k++) {
        const patch_field_t *f = &fields[k];
        for (int i = 0; i < f->count; i++) {
            patch_init(&p);
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

    // The init patch, written and read back.
    patch_t init, back;
    patch_init(&init);
    char *text = NULL;
    size_t text_len = 0;
    FILE *mem = open_memstream(&text, &text_len);
    patch_file_write(mem, &init);
    fclose(mem);
    char err[200];
    if (!patch_file_parse(text, text_len, &back, err, sizeof err)) {
        printf("FAIL reading the written init patch: %s\n", err);
        s_failures++;
    } else if (patch_file_diff(stdout, &init, &back) != 0) {
        printf("FAIL the written init patch reads back different (above)\n");
        s_failures++;
    }
    free(text);

    // Each factory file reads, and holds exactly the writer's text.
    for (int a = 1; a < argc; a++) {
        patch_t factory;
        if (!patch_file_read(argv[a], &factory, err, sizeof err)) {
            printf("FAIL %s: %s\n", argv[a], err);
            s_failures++;
            continue;
        }
        mem = open_memstream(&text, &text_len);
        patch_file_write(mem, &factory);
        fclose(mem);
        // the file without its comment lines
        FILE *in = fopen(argv[a], "r");
        char line[256], *body = NULL;
        size_t body_len = 0;
        FILE *bm = open_memstream(&body, &body_len);
        while (in && fgets(line, sizeof line, in))
            if (line[0] != '#')
                fputs(line, bm);
        if (in) fclose(in);
        fclose(bm);
        if (strcmp(body, text) != 0) {
            printf("FAIL %s is not in the writer's form; the writer gives:\n%s", argv[a], text);
            s_failures++;
        } else {
            printf("%s: reads back exactly\n", argv[a]);
        }
        free(body);
        free(text);
    }

    check_saving();

    printf("\n%s (%d failures)\n", s_failures ? "FAIL" : "ALL PASS", s_failures);
    return s_failures ? 1 : 0;
}
