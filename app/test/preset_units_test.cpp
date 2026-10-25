// preset_units_test.cpp — host test: every raw value of every preset file
// key loads back exactly from the value the writer gives it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// For each key and each raw value its preset_t field can hold, the test
// writes the value as the writer does, reads the text back as the
// loader does, and checks
//   - the loaded raw value is the canonical form of the written one, and
//   - the canonical form is stable (writing and loading it again changes
//     nothing),
// which together make load → save → load exact. A key whose conversion
// depends on another key (the LFO depth on its destination) is checked
// across that key's values.
//
// Then it writes the init preset (preset_init) as a preset file and reads it
// back, which must give the init preset. Each factory file given as an
// argument must read, and its values must read back exactly through the
// writer, and its text, comment lines aside, must be the writer's own, so
// that a save on the board changes only what changed. A file under
// Presets/Factory must start with the copyright notice, as a save there
// writes it. Last, saving (a Factory save gets the notice, a User save
// does not), recovery from an interrupted save, and preset-name rules.
//
//   make fw-test

#include <filesystem>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <string_view>
#include <system_error>
#include <unistd.h>

#include "preset.h"
#include "preset_file.h"
#include "preset_units.h"

static int s_failures;

// What the loader does with one written value.
static void load_text(const preset_field_t *f, int i, preset_t *p,
                      const char *text) {
    if (f->kind == PF_NAME) {
        char name[32];
        size_t n = strlen(text);
        snprintf(name, sizeof name, "%.*s", (int) (n - 2),
                 text + 1); // strip quotes
        preset_field_set_name(f, i, p, name);
        return;
    }
    double v = strcmp(text, "inf") == 0    ? INFINITY
               : strcmp(text, "-inf") == 0 ? -INFINITY
                                           : strtod(text, NULL);
    preset_field_set_number(f, i, p, v);
}

static void check_raw(const preset_field_t *f, int i, preset_t *p,
                      int32_t raw) {
    f->set(p, i, raw);
    raw           = f->get(p, i); // as the field stores it
    int32_t canon = preset_field_canonical(f, i, p, raw);

    char text[64];
    preset_field_format(f, i, p, text, sizeof text);
    load_text(f, i, p, text);
    int32_t loaded = f->get(p, i);

    char again[64];
    preset_field_format(f, i, p, again, sizeof again);
    load_text(f, i, p, again);
    int32_t reloaded = f->get(p, i);

    if (loaded != canon || reloaded != loaded || strcmp(text, again) != 0) {
        if (s_failures < 20) {
            printf("FAIL %s.%s[%d]: raw %ld -> \"%s\" -> %ld (canonical %ld), "
                   "again \"%s\" -> %ld\n",
                   f->table, f->key, i, (long) raw, text, (long) loaded,
                   (long) canon, again, (long) reloaded);
        }
        s_failures++;
    }
}

// The raw values a field can hold.
static void raw_range(const preset_field_t *f, int32_t *lo, int32_t *hi) {
    const char *k = f->key;
    if (f->kind == PF_NAME) {
        int32_t n = 0;
        while (f->names[n]) {
            n++;
        }
        *lo = 0;
        *hi = n - 1;
    } else if (!strcmp(k, "pulse_width")) {
        *lo = -8388608;
        *hi = 8388608;
    } else if (!strcmp(k, "attack") || !strcmp(k, "decay")
               || !strcmp(k, "release") || !strcmp(k, "velocity")
               || !strcmp(k, "volume") || !strcmp(k, "bend_range")) {
        *lo = 0;
        *hi = 255;
    } else if (!strcmp(k, "sustain")) {
        *lo = 0;
        *hi = 1023;
    } else if (!strcmp(k, "osc_mix") || !strcmp(k, "pan")) {
        *lo = -128;
        *hi = 127;
    } else if (!strcmp(k, "slope")) {
        *lo = 0;
        *hi = 1;
    } else if (!strcmp(k, "rate")) {
        *lo = 0;
        *hi = 65535;
    } else if (!strcmp(k, "resonance")) {
        *lo = 0;
        *hi = 0x3FFF;
    } else {
        *lo = -32768;
        *hi = 32767; // int16 fields
    }
}

// Every raw value for the first element. The conversions are the same
// for every element, so later elements only check the accessor, on a
// spread of values.
static void check_field(const preset_field_t *f, int i, preset_t *p) {
    int32_t lo, hi;
    raw_range(f, &lo, &hi);
    int32_t step = (i == 0) ? 1 : (hi - lo) / 997 + 1;
    for (int32_t r = lo; r <= hi; r += step) {
        check_raw(f, i, p, r);
    }
}

static void fail(const char *what) {
    printf("FAIL %s\n", what);
    s_failures++;
}

static bool exists(const char *path) {
    return access(path, F_OK) == 0;
}

// The whole of a file, "" if it cannot be read.
static std::string read_file(const char *path) {
    std::string text;
    FILE *in = fopen(path, "rb");
    char buf[4096];
    size_t n;
    while (in && (n = fread(buf, 1, sizeof buf, in)) > 0) {
        text.append(buf, n);
    }
    if (in) {
        fclose(in);
    }
    return text;
}

// text without its comment lines (those that start with '#').
static std::string without_comments(std::string_view text) {
    std::string body;
    while (!text.empty()) {
        size_t newline = text.find('\n');
        std::string_view line =
                text.substr(0, newline == std::string_view::npos ? text.size()
                                                                 : newline + 1);
        if (!line.starts_with('#')) {
            body += line;
        }
        text.remove_prefix(line.size());
    }
    return body;
}

static void write_text(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}

// Save, the four interrupted-save cases, and names.
static void check_saving(void) {
    char dir[] = "/tmp/noaidi_save_XXXXXX";
    if (!mkdtemp(dir)) {
        fail("mkdtemp");
        return;
    }
    char a[320], a_new[340], b[320], b_new[340], err[200];
    snprintf(a, sizeof a, "%s/A.toml", dir);
    snprintf(a_new, sizeof a_new, "%s.new", a);
    snprintf(b, sizeof b, "%s/B.toml", dir);
    snprintf(b_new, sizeof b_new, "%s.new", b);

    preset_t init, other, back;
    preset_init(&init);
    preset_init(&other);
    other.filter.resonance = 1024;

    // a plain save: the file reads back, no .new remains
    if (!preset_file_save(a, &init, err, sizeof err)) {
        fail(err);
    }
    if (!preset_file_read(a, &back, err, sizeof err)
        || preset_file_diff(stdout, &init, &back)) {
        fail("saved preset does not read back");
    }
    if (exists(a_new)) {
        fail("save left a .new file");
    }

    // a complete .new beside the old preset: the save finishes
    char *text;
    size_t len;
    FILE *m = open_memstream(&text, &len);
    preset_file_write(m, &other);
    fputs("# end\n", m);
    fclose(m);
    write_text(a_new, text);
    preset_file_recover(dir);
    if (exists(a_new) || !preset_file_read(a, &back, err, sizeof err)
        || preset_file_diff(stdout, &other, &back)) {
        fail("complete .new beside the old preset was not finished");
    }

    // an incomplete .new beside the old preset: the old preset stays
    write_text(a_new, "format = 1\n[filter]\nresonance = 4\n");
    preset_file_recover(dir);
    if (exists(a_new) || !preset_file_read(a, &back, err, sizeof err)
        || preset_file_diff(stdout, &other, &back)) {
        fail("incomplete .new beside the old preset was not undone");
    }

    // a complete .new with no old preset: it becomes the preset
    write_text(b_new, text);
    preset_file_recover(dir);
    if (exists(b_new) || !exists(b)) {
        fail("complete new .new was not renamed");
    }

    // an incomplete .new with no old preset: deleted, no preset appears
    remove(b);
    write_text(b_new, "format = 1\n");
    preset_file_recover(dir);
    if (exists(b_new) || exists(b)) {
        fail("incomplete new .new was not deleted");
    }
    free(text);

    // a Factory save starts with the copyright notice, a User save does
    // not; both end with "# end" and read back
    const std::string root    = std::string(dir) + "/Presets";
    const std::string factory = root + "/Factory/Pads/C.toml";
    const std::string user    = root + "/User/Pads/C.toml";
    std::error_code ignored;
    std::filesystem::create_directories(root + "/Factory/Pads", ignored);
    std::filesystem::create_directories(root + "/User/Pads", ignored);
    for (const std::string &path : {factory, user}) {
        const bool in_factory = path == factory;
        if (!preset_file_save(path.c_str(), &other, err, sizeof err)) {
            fail(err);
        }
        const std::string saved = read_file(path.c_str());
        if (saved.starts_with(preset_file::factory_notice) != in_factory) {
            fail(in_factory ? "Factory save lacks the copyright notice"
                            : "User save carries the copyright notice");
        }
        if (!saved.ends_with("# end\n")) {
            fail("save does not end with # end");
        }
        if (!preset_file_read(path.c_str(), &back, err, sizeof err)
            || preset_file_diff(stdout, &other, &back)) {
            fail("saved preset does not read back");
        }
    }
    std::filesystem::remove_all(root, ignored);

    remove(a);
    rmdir(dir);

    // names
    const char *good[] = {
            "Arctic Ice", "Ærlig Gjøk", "RnB Whistle", "a",
            "1234567890123456789012345678901234567890123456789012345678901234"};
    const char *bad[] = {
            "",
            " lead",
            "lead ",
            "lead.",
            "a/b",
            "a\\b",
            "what?",
            "x:y",
            "q\"",
            "<a>",
            "pipe|",
            "tab\t",
            "12345678901234567890123456789012345678901234567890123456789012345"};
    for (size_t i = 0; i < sizeof good / sizeof good[0]; i++) {
        if (!preset_name_valid(good[i])) {
            printf("FAIL name \"%s\" rejected\n", good[i]);
            s_failures++;
        }
    }
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        if (preset_name_valid(bad[i])) {
            printf("FAIL name \"%s\" accepted\n", bad[i]);
            s_failures++;
        }
    }
    printf("saving, recovery, names: %s\n", s_failures ? "see above" : "ok");
}

int main(int argc, char **argv) {
    size_t n;
    const preset_field_t *fields = preset_fields(&n);
    preset_t p;

    for (size_t k = 0; k < n; k++) {
        const preset_field_t *f = &fields[k];
        for (int i = 0; i < f->count; i++) {
            preset_init(&p);
            if (!strcmp(f->table, "lfo") && !strcmp(f->key, "depth")) {
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

    // The init preset, written and read back.
    preset_t init, back;
    preset_init(&init);
    char *text      = NULL;
    size_t text_len = 0;
    FILE *mem       = open_memstream(&text, &text_len);
    preset_file_write(mem, &init);
    fclose(mem);
    char err[200];
    if (!preset_file_parse(text, text_len, &back, err, sizeof err)) {
        printf("FAIL reading the written init preset: %s\n", err);
        s_failures++;
    } else if (preset_file_diff(stdout, &init, &back) != 0) {
        printf("FAIL the written init preset reads back different (above)\n");
        s_failures++;
    }
    free(text);

    // Each factory file reads, and its values read back exactly through
    // the writer. Text that differs from the writer's is a warning.
    for (int a = 1; a < argc; a++) {
        preset_t factory;
        if (!preset_file_read(argv[a], &factory, err, sizeof err)) {
            printf("FAIL %s: %s\n", argv[a], err);
            s_failures++;
            continue;
        }
        mem = open_memstream(&text, &text_len);
        preset_file_write(mem, &factory);
        fclose(mem);
        preset_t back;
        if (!preset_file_parse(text, text_len, &back, err, sizeof err)) {
            printf("FAIL %s: the writer's text does not read: %s\n", argv[a],
                   err);
            s_failures++;
        } else if (preset_file_diff(stdout, &factory, &back) != 0) {
            printf("FAIL %s reads back different through the writer (above)\n",
                   argv[a]);
            s_failures++;
        }
        // A Factory file is source: it starts with the copyright notice,
        // as a save into Factory writes it.
        const std::string file = read_file(argv[a]);
        if (preset_file::factory_path(argv[a])
            && !file.starts_with(preset_file::factory_notice)) {
            printf("FAIL %s lacks the copyright notice\n", argv[a]);
            s_failures++;
        }
        // The file is the writer's text, comment lines aside.
        if (without_comments(file) != text) {
            printf("FAIL %s is not in the writer's form; the writer gives:\n%s",
                   argv[a], text);
            s_failures++;
        } else {
            printf("%s: reads back exactly\n", argv[a]);
        }
        free(text);
    }

    check_saving();

    printf("\n%s (%d failures)\n", s_failures ? "FAIL" : "ALL PASS",
           s_failures);
    return s_failures ? 1 : 0;
}
