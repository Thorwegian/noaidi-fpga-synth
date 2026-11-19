// preset_units_test.cpp — host test: a preset file gives its preset back
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A preset's numbers are floats in the file's units, so the writer and the
// loader convert nothing, and the test holds them to it:
//   - every value a field can hold is written so that it loads back as the
//     same float: presets drawn at random over every key's range (its ends,
//     its infinity, the round figures a hand types, any float between) are
//     saved and loaded, and the loaded preset is the saved one, and saves
//     as the same text;
//   - a number outside its key's range loads as the range's end, one between
//     two steps as the nearer, and what is no number or no name of the key
//     leaves the key as it was;
//   - a value typed by hand is written back as it was typed.
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

#include <cmath>
#include <filesystem>
#include <random>
#include <span>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <string_view>
#include <system_error>
#include <unistd.h>
#include <vector>

#include "preset.h"
#include "preset_file.h"
#include "preset_units.hpp"

using preset_units::Range;
using Names = std::span<const char *const>;

static int s_failures;

static void fail(const char *what) {
    printf("FAIL %s\n", what);
    s_failures++;
}

static void check(bool ok, const char *what) {
    if (!ok) {
        fail(what);
    }
}

// Every field of a preset, a name as its enumerator: two presets with the
// same fields are the same preset.
class Fields {
public:
    void table(const char *) {}
    void element(const char *, int) {}
    void number(const char *, const float &field, const Range &) {
        fields_.push_back(field);
    }
    template <typename Name>
    void name(const char *, const Name &field, Names) {
        fields_.push_back(static_cast<float>(field));
    }

    static std::vector<float> of(const preset_t &preset) {
        Fields fields;
        preset_units::visit(preset, fields);
        return fields.fields_;
    }

private:
    std::vector<float> fields_;
};

// A preset drawn at random: each number over its key's range, each name
// from its key's list.
class Draw {
public:
    explicit Draw(std::mt19937 &random) : random_(random) {}

    void table(const char *) {}
    void element(const char *, int) {}

    void number(const char *, float &field, const Range &range) {
        switch (pick(6)) {
        case 0:
            field = range.low;
            break;
        case 1:
            field = range.high;
            break;
        case 2:
            field = range.infinity != 0.0f ? range.infinity : range.low;
            break;
        case 3: // a round figure, as a hand types it
            field = preset_units::within(
                    range, std::round(between(range) * 100.0) / 100.0);
            break;
        default:
            field = preset_units::within(range, between(range));
            break;
        }
    }

    template <typename Name>
    void name(const char *, Name &field, Names names) {
        field = static_cast<Name>(pick(static_cast<int>(names.size())));
    }

private:
    int pick(int count) {
        return std::uniform_int_distribution<int>(0, count - 1)(random_);
    }

    // Any value of the range: evenly over it, or, where it is all above
    // zero, as often evenly over its ratio, so that the small ones come too.
    double between(const Range &range) {
        const double share =
                std::uniform_real_distribution<double>(0.0, 1.0)(random_);
        if (range.low > 0.0f && pick(2) == 0) {
            return range.low * std::pow(range.high / range.low, share);
        }
        return range.low + share * (range.high - range.low);
    }

    std::mt19937 &random_;
};

// What a range does to a number from a file.
class Limits {
public:
    void table(const char *) {}
    void element(const char *, int) {}

    void number(const char *key, const float &, const Range &range) {
        using preset_units::infinity;
        using preset_units::within;
        const double low = range.low, high = range.high;
        bool ok = within(range, low - 1.0) == range.low
                  && within(range, high + 1.0) == range.high
                  && within(range, 1e300) == range.high
                  && within(range, -1e300) == range.low
                  && within(range, infinity)
                             == (range.infinity > 0.0f ? infinity : range.high)
                  && within(range, -infinity)
                             == (range.infinity < 0.0f ? -infinity : range.low);
        if (range.step != 0.0f) {
            // the nearer step, a tie away from zero (no range with steps
            // starts below it)
            const double step = range.step;
            ok = ok && within(range, low + 0.49 * step) == range.low
                 && within(range, low + 0.5 * step) == range.low + range.step
                 && within(range, low + 0.51 * step) == range.low + range.step;
        } else {
            const double middle = (low + high) / 2.0;
            ok = ok && within(range, middle) == static_cast<float>(middle);
        }
        if (!ok) {
            printf("FAIL %s: a value does not load into its range\n", key);
            s_failures++;
        }
    }

    template <typename Name>
    void name(const char *, const Name &, Names) {}
};

static void check_round_trips() {
    constexpr int presets = 2000;
    std::mt19937 random(471);
    int shown = 0;
    for (int n = 0; n < presets; n++) {
        preset_t drawn, loaded;
        preset_init(&drawn);
        preset_units::visit(drawn, Draw(random));
        const std::string text = preset_file::to_text(drawn);
        std::string error;
        if (!preset_file::parse(text, loaded, error)) {
            printf("FAIL a written preset does not read: %s\n%s", error.c_str(),
                   text.c_str());
            s_failures++;
            return;
        }
        if (Fields::of(loaded) != Fields::of(drawn)
            || preset_file::to_text(loaded) != text) {
            if (shown++ < 5) {
                printf("FAIL a preset loads back different:\n");
                preset_file_diff(stdout, &drawn, &loaded);
            }
            s_failures++;
        }
    }
    printf("%d presets drawn over every key's range: %s\n", presets,
           s_failures ? "see above" : "each loads back as it was saved");
}

static void check_loading() {
    preset_t init;
    preset_init(&init);
    preset_units::visit(init, Limits());

    // values out of range, between steps, infinite and of the wrong kind
    const std::string_view odd = "format = 1\n"
                                 "[[osc]]\n"
                                 "wave = \"noise\"\n"
                                 "tune = 7\n"
                                 "[[osc]]\n"
                                 "wave = \"square\"\n"
                                 "tune = \"high\"\n"
                                 "[filter]\n"
                                 "slope = 18\n"
                                 "cutoff = 1e9\n"
                                 "resonance = inf\n"
                                 "[amp_env]\n"
                                 "attack = nan\n"
                                 "sustain = 3\n"
                                 "[[lfo]]\n"
                                 "destination = \"cutoff\"\n"
                                 "depth = 200\n"
                                 "[part]\n"
                                 "volume = -inf\n"
                                 "bend_range = 2.5\n";
    preset_t p;
    std::string error;
    if (!preset_file::parse(odd, p, error)) {
        printf("FAIL %s\n", error.c_str());
        s_failures++;
        return;
    }
    check(p.osc[0].wave == WAVE_NOISE, "a name is its enumerator");
    check(p.osc[0].tune == 7.0f, "a whole number is a number");
    check(p.osc[1].wave == init.osc[1].wave,
          "a name the key does not have leaves the init preset's");
    check(p.osc[1].tune == init.osc[1].tune,
          "a string for a number leaves the init preset's");
    check(p.filter.slope == 24.0f, "a slope between the two is the nearer");
    check(p.filter.cutoff == preset_units::cutoff.high,
          "a cutoff above the range is the range's top");
    check(std::isinf(p.filter.resonance) && p.filter.resonance > 0.0f,
          "a resonance of infinity stays");
    check(p.amp_env.attack == init.amp_env.attack,
          "what is not a number leaves the init preset's");
    check(p.amp_env.sustain == 0.0f, "a sustain above the peak is the peak");
    check(p.lfo[0].depth == preset_units::lfo_depth(LFO_DEST_CUTOFF).high,
          "an LFO's depth has its destination's range, read before it");
    check(std::isinf(p.part.volume) && p.part.volume < 0.0f,
          "a volume of minus infinity stays");
    check(p.part.bend_range == 3.0f, "a tie between steps goes from zero");

    // a value typed by hand is written back as typed
    const char *const typed[] = {
            "cutoff = 1000\n",          "release = 7.2\n",
            "tune = -12.07\n",          "resonance = 2.146\n",
            "pulse_width = 84.61282\n", "rate = 0.1\n"};
    const std::string hand = "format = 1\n[[osc]]\ntune = -12.07\n"
                             "pulse_width = 84.61282\n[filter]\n"
                             "cutoff = 1000\nresonance = 2.146\n[amp_env]\n"
                             "release = 7.2\n[[lfo]]\nrate = 0.1\n";
    if (!preset_file::parse(hand, p, error)) {
        printf("FAIL %s\n", error.c_str());
        s_failures++;
        return;
    }
    const std::string written = preset_file::to_text(p);
    for (const char *line : typed) {
        if (written.find(line) == std::string::npos) {
            printf("FAIL a typed value is not written back as typed: %s", line);
            s_failures++;
        }
    }
    printf("ranges, steps, infinities, names, typed values: %s\n",
           s_failures ? "see above" : "ok");
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
    other.filter.resonance = 2.0f;

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
    check_round_trips();
    check_loading();

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
    } else if (Fields::of(back) != Fields::of(init)) {
        preset_file_diff(stdout, &init, &back);
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
        } else if (Fields::of(back) != Fields::of(factory)) {
            preset_file_diff(stdout, &factory, &back);
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
