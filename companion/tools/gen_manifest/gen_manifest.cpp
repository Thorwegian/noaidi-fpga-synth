// gen_manifest.cpp — the companion's parameter manifest, generated from the
// firmware's preset-file table
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Compiles app/main/preset_units.c and app/main/preset.cpp unchanged and
// writes one JSON entry per semantic parameter (osc[0].tune,
// filter.cutoff, ...) to stdout; with --c-header, the same IDs as a C enum
// for the display. Nothing about a parameter is written down here:
// everything is asked of preset_fields(), so the companion holds no
// second engine model.
//
//   id          semantic parameter ID: table, [index] for arrays of tables
//               (0-based), key
//   file        where format 1 stores it: TOML table, array index, key
//   kind        "number" or "name"
//   names       a name key's names, by raw value
//   initValue   the init preset's value (preset_init): what a file that
//               omits the key loads as. The init preset is a neutral
//               fallback, not a representative sound
//   integer     a number key that takes whole numbers only
//   nearest     how a value converts to the nearest raw value:
//               "difference" (linear units) or "ratio" (seconds, Hz, Q),
//               found by probing the conversion (see nearest_metric)
//   range       min and max of the finite values the key can hold. The
//               loader clamps to this range; it is found by loading ±1e300
//   special     values outside the finite range: "inf", "-inf"
//   valueCount  how many distinct values the key can hold
//   values      all of them, ascending, when there are at most
//               values_max
//   dependsOn   the parameter whose value changes this one's conversion,
//               found by changing every earlier key and watching this
//               one. A name dependency gives "byValue": range, valueCount
//               and values per name. A number dependency gives the union
//               of the ranges and no valueCount or values
//
// Every number is the actual musical value to 6 significant digits, more
// where 6 do not load back to the same raw value (see format_raw). The
// array is in the order the loader applies the keys.
//
// Self-checks: every listed value, every range end and every init value
// loads back, through the firmware's own conversions, to the canonical
// raw value it came from, and every ID is unique. A failed check exits
// non-zero.

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "preset.h"
#include "preset_file.h"
#include "preset_units.h"

namespace {

// List every value of keys with at most this many.
constexpr long values_max = 1024;
// Raw values compared when looking for dependencies.
constexpr int probe_points = 17;
// Loads as the clamped end of any range.
constexpr double big = 1e300;
// Significant digits of a written value (see format_raw).
constexpr int significant_digits = 6;

int failures = 0;

void fail(const std::string &id, std::string_view what, std::string_view text) {
    std::fprintf(stderr, "gen_manifest: %s: %.*s (%.*s)\n", id.c_str(),
                 static_cast<int>(what.size()), what.data(),
                 static_cast<int>(text.size()), text.data());
    failures++;
}

std::string param_id(const preset_field_t &field, int index) {
    std::string id = field.table;
    if (field.count > 1) {
        id += "[" + std::to_string(index) + "]";
    }
    return id + "." + field.key;
}

// The raw values of the finite range ends, and the raw values of ±inf.
struct domain {
    int32_t lo;
    int32_t hi;
    std::vector<int32_t> special;
};

domain domain_of(const preset_field_t &field, int index, const preset_t &p) {
    int32_t a = field.to_raw(&p, index, -big);
    int32_t b = field.to_raw(&p, index, big);
    domain d{std::min(a, b), std::max(a, b), {}};
    for (double infinity : {-INFINITY, INFINITY}) {
        int32_t raw = field.to_raw(&p, index, infinity);
        if ((raw < d.lo || raw > d.hi)
            && std::isinf(field.to_value(&p, index, raw))) {
            d.special.push_back(raw);
        }
    }
    return d;
}

// v to the given significant digits, as a plain decimal (JSON-safe, no
// exponent), trailing zeros removed.
std::string format_significant(double v, int digits) {
    if (v == 0.0) {
        return "0";
    }
    int decimals =
            digits - 1 - static_cast<int>(std::floor(std::log10(std::fabs(v))));
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.*f", std::max(decimals, 0), v);
    std::string text = buf;
    if (text.find('.') != std::string::npos) {
        text.erase(text.find_last_not_of('0') + 1);
        if (text.back() == '.') {
            text.pop_back();
        }
    }
    if (text.front() == '-' && std::strtod(text.c_str(), nullptr) == 0.0) {
        text.erase(0, 1); // "-0" is zero
    }
    return text;
}

// Raw value raw of element index as text: a quoted name, "inf"/"-inf", or
// its actual musical value to significant_digits, more if that does not
// load back to the same (canonical) raw value. Not the firmware writer's
// shortest decimal: at a clamped range end any value beyond the end loads
// back, so the shortest is not the value (the fastest attack writes as 0,
// the highest tune as 50 instead of 48). The manifest says what the
// engine does; how a value looks on screen is the display layer's
// business.
std::string format_raw(const preset_field_t &field, int index,
                       const preset_t &p, int32_t raw) {
    preset_t q = p;
    field.set(&q, index, raw);
    if (field.kind == PF_NAME) {
        char buf[64];
        preset_field_format(&field, index, &q, buf, sizeof buf);
        return buf;
    }
    int32_t want = preset_field_canonical(&field, index, &q, raw);
    double v     = field.to_value(&q, index, want);
    if (std::isinf(v)) {
        return v > 0 ? "inf" : "-inf";
    }
    std::string text;
    for (int digits = significant_digits; digits <= 17; digits++) {
        text = format_significant(v, digits);
        if (field.to_raw(&q, index, std::strtod(text.c_str(), nullptr))
            == want) {
            break;
        }
    }
    return text;
}

// Load text back the way the firmware does and compare with raw value
// raw's canonical form.
void check_loads_back(const preset_field_t &field, int index, const preset_t &p,
                      int32_t raw, const std::string &text,
                      std::string_view what) {
    std::string id = param_id(field, index);
    preset_t q     = p;
    raw            = preset_field_canonical(&field, index, &p, raw);
    if (field.kind == PF_NAME) {
        std::string name = text.substr(1, text.size() - 2); // unquote
        if (!preset_field_set_name(&field, index, &q, name.c_str())
            || field.get(&q, index) != raw) {
            fail(id, what, text);
        }
        return;
    }
    double v = text == "inf"    ? INFINITY
               : text == "-inf" ? -INFINITY
                                : std::strtod(text.c_str(), nullptr);
    preset_field_set_number(&field, index, &q, v);
    if (field.get(&q, index) != raw) {
        fail(id, what, text);
    }
}

// Every distinct value of element index: the raw values that are their own
// canonical form.
struct value_set {
    double min      = 0;
    double max      = 0;
    int32_t min_raw = 0;
    int32_t max_raw = 0;
    long count      = 0;
    std::vector<int32_t> listed; // empty when count > values_max
};

value_set values_of(const preset_field_t &field, int index, const preset_t &p) {
    domain d = domain_of(field, index, p);
    value_set s;
    for (int64_t raw = d.lo; raw <= d.hi; raw++) {
        auto r = static_cast<int32_t>(raw);
        if (preset_field_canonical(&field, index, &p, r) != r) {
            continue;
        }
        double v = field.to_value(&p, index, r);
        if (s.count == 0 || v < s.min) {
            s.min     = v;
            s.min_raw = r;
        }
        if (s.count == 0 || v > s.max) {
            s.max     = v;
            s.max_raw = r;
        }
        if (s.count < values_max) {
            s.listed.push_back(r);
        }
        s.count++;
    }
    if (s.count > values_max) {
        s.listed.clear();
    }
    return s;
}

// What a dependency would change: the range ends and the values at a few
// raw values spread over the range.
std::vector<double> signature(const preset_field_t &field, int index,
                              const preset_t &p) {
    domain d = domain_of(field, index, p);
    std::vector<double> out{static_cast<double>(d.lo),
                            static_cast<double>(d.hi)};
    for (int k = 0; k < probe_points; k++) {
        auto raw = static_cast<int32_t>(d.lo
                                        + (static_cast<int64_t>(d.hi) - d.lo)
                                                  * k / (probe_points - 1));
        out.push_back(field.to_value(&p, index, raw));
    }
    return out;
}

bool signature_differs(const std::vector<double> &a,
                       const std::vector<double> &b) {
    for (size_t k = 0; k < a.size(); k++) {
        if (!(a[k] == b[k]) && !(std::isnan(a[k]) && std::isnan(b[k]))) {
            return true;
        }
    }
    return false;
}

// The raw values worth trying for element index of a field: every name,
// or a number key's range ends.
std::vector<int32_t> alternatives(const preset_field_t &field, int index,
                                  const preset_t &p) {
    std::vector<int32_t> out;
    if (field.kind == PF_NAME) {
        for (int32_t k = 0; field.names[k]; k++) {
            out.push_back(k);
        }
    } else {
        domain d = domain_of(field, index, p);
        out      = {d.lo, d.hi};
    }
    return out;
}

struct dependency {
    size_t field; // index into the field table
    int index;    // element of that field
};

// The one earlier parameter element index of fields[k] depends on, if any.
std::optional<dependency> find_dependency(const preset_field_t *fields,
                                          size_t k, int index,
                                          const preset_t &init) {
    const preset_field_t &field = fields[k];
    std::vector<double> base    = signature(field, index, init);
    std::optional<dependency> found;
    for (size_t g = 0; g < k; g++) {
        for (int j = 0; j < fields[g].count; j++) {
            for (int32_t alt : alternatives(fields[g], j, init)) {
                preset_t q = init;
                fields[g].set(&q, j, alt);
                if (!signature_differs(base, signature(field, index, q))) {
                    continue;
                }
                if (found && (found->field != g || found->index != j)) {
                    fail(param_id(field, index),
                         "depends on more than one parameter", "not supported");
                }
                found = dependency{g, j};
                break;
            }
        }
    }
    return found;
}

// How the loader picks the nearest raw value: by "difference" (linear
// units: semitones, dB, percent) or by "ratio" (seconds, Hz, Q). Found
// between the two smallest positive values a < b: the loader's boundary
// between them lies at (a + b) / 2 by difference and at √(a·b) by ratio,
// and a value halfway between those two points loads as b only by ratio.
// A key without two positive values is "difference".
const char *nearest_metric(const preset_field_t &field, int index,
                           const preset_t &p) {
    domain d = domain_of(field, index, p);
    double a = INFINITY;
    double b = INFINITY;
    for (int64_t raw = d.lo; raw <= d.hi; raw++) {
        auto r = static_cast<int32_t>(raw);
        if (preset_field_canonical(&field, index, &p, r) != r) {
            continue;
        }
        double v = field.to_value(&p, index, r);
        if (v > 0.0 && v < a) {
            b = a;
            a = v;
        } else if (v > 0.0 && v > a && v < b) {
            b = v;
        }
    }
    if (std::isinf(b)) {
        return "difference";
    }
    double between = (std::sqrt(a * b) + (a + b) / 2.0) / 2.0;
    return field.to_raw(&p, index, between) == field.to_raw(&p, index, b)
                   ? "ratio"
                   : "difference";
}

// ── JSON output ─────────────────────────────────────────────────────

std::string quoted(std::string_view s) {
    std::string out = "\"";
    for (char c : s) {
        if (c == '"' || c == '\\') {
            out += '\\';
        }
        out += c;
    }
    return out + "\"";
}

// "range", "special", "valueCount" and "values" of one value set,
// checking that every value written loads back.
void put_value_set(const preset_field_t &field, int index, const preset_t &p,
                   value_set &s, const std::string &indent) {
    std::string min = format_raw(field, index, p, s.min_raw);
    std::string max = format_raw(field, index, p, s.max_raw);
    check_loads_back(field, index, p, s.min_raw, min,
                     "range min does not load back");
    check_loads_back(field, index, p, s.max_raw, max,
                     "range max does not load back");
    std::printf("%s\"range\": { \"min\": %s, \"max\": %s }", indent.c_str(),
                min.c_str(), max.c_str());

    domain d = domain_of(field, index, p);
    if (!d.special.empty()) {
        std::printf(",\n%s\"special\": [", indent.c_str());
        for (size_t k = 0; k < d.special.size(); k++) {
            std::string text = format_raw(field, index, p, d.special[k]);
            check_loads_back(field, index, p, d.special[k], text,
                             "special value does not load back");
            std::printf("%s\"%s\"", k ? ", " : "", text.c_str());
        }
        std::printf("]");
    }
    std::printf(",\n%s\"valueCount\": %ld", indent.c_str(),
                s.count + static_cast<long>(d.special.size()));
    if (s.listed.empty()) {
        return;
    }
    std::sort(s.listed.begin(), s.listed.end(), [&](int32_t a, int32_t b) {
        return field.to_value(&p, index, a) < field.to_value(&p, index, b);
    });
    std::printf(",\n%s\"values\": [", indent.c_str());
    for (size_t k = 0; k < s.listed.size(); k++) {
        std::string text = format_raw(field, index, p, s.listed[k]);
        check_loads_back(field, index, p, s.listed[k], text,
                         "value does not load back");
        std::printf("%s%s", k ? ", " : "", text.c_str());
    }
    std::printf("]");
}

// "range" of a dependent parameter: the union of its ranges over every
// value of the dependency, each end written in the state it occurs in.
void put_union_range(const preset_field_t &field, int index,
                     const preset_field_t &dep, int dep_index,
                     const preset_t &init, const std::string &indent) {
    domain dd{0, 0, {}};
    if (dep.kind == PF_NAME) {
        while (dep.names[dd.hi + 1]) {
            dd.hi++;
        }
    } else {
        dd = domain_of(dep, dep_index, init);
    }
    bool first      = true;
    double min      = 0;
    double max      = 0;
    preset_t at_min = init;
    preset_t at_max = init;
    int32_t min_raw = 0;
    int32_t max_raw = 0;
    for (int64_t raw = dd.lo; raw <= dd.hi; raw++) {
        auto r = static_cast<int32_t>(raw);
        if (dep.kind != PF_NAME
            && preset_field_canonical(&dep, dep_index, &init, r) != r) {
            continue;
        }
        preset_t q = init;
        dep.set(&q, dep_index, r);
        value_set s = values_of(field, index, q);
        if (first || s.min < min) {
            min     = s.min;
            min_raw = s.min_raw;
            at_min  = q;
        }
        if (first || s.max > max) {
            max     = s.max;
            max_raw = s.max_raw;
            at_max  = q;
        }
        first = false;
    }
    std::string min_text = format_raw(field, index, at_min, min_raw);
    std::string max_text = format_raw(field, index, at_max, max_raw);
    check_loads_back(field, index, at_min, min_raw, min_text,
                     "range min does not load back");
    check_loads_back(field, index, at_max, max_raw, max_text,
                     "range max does not load back");
    std::printf("%s\"range\": { \"min\": %s, \"max\": %s }", indent.c_str(),
                min_text.c_str(), max_text.c_str());
}

void put_number(const preset_field_t *fields, size_t k, int index,
                const preset_t &init) {
    const preset_field_t &field   = fields[k];
    std::optional<dependency> dep = find_dependency(fields, k, index, init);
    if (!dep) {
        value_set s = values_of(field, index, init);
        put_value_set(field, index, init, s, "      ");
        std::printf("\n");
        return;
    }
    const preset_field_t &g = fields[dep->field];
    std::printf("      \"dependsOn\": %s,\n",
                quoted(param_id(g, dep->index)).c_str());
    put_union_range(field, index, g, dep->index, init, "      ");
    if (g.kind == PF_NAME) {
        std::printf(",\n      \"byValue\": {\n");
        for (int32_t n = 0; g.names[n]; n++) {
            preset_t q = init;
            g.set(&q, dep->index, n);
            value_set s = values_of(field, index, q);
            std::printf("%s        %s: {\n", n ? ",\n" : "",
                        quoted(g.names[n]).c_str());
            put_value_set(field, index, q, s, "          ");
            std::printf("\n        }");
        }
        std::printf("\n      }");
    }
    std::printf("\n");
}

void put_manifest(const preset_field_t *fields, size_t count,
                  const preset_t &init) {
    std::printf("{\n");
    std::printf("  \"generatedBy\": \"companion/tools/gen_manifest from "
                "app/main/preset_units.c; do not edit\",\n");
    std::printf("  \"presetFileFormat\": %d,\n", PRESET_FILE_FORMAT);
    std::printf("  \"parameters\": [\n");
    bool first = true;
    for (size_t k = 0; k < count; k++) {
        const preset_field_t &field = fields[k];
        for (int i = 0; i < field.count; i++) {
            std::printf("%s    {\n", first ? "" : ",\n");
            first = false;
            std::printf("      \"id\": %s,\n",
                        quoted(param_id(field, i)).c_str());
            std::printf("      \"file\": { \"table\": %s",
                        quoted(field.table).c_str());
            if (field.count > 1) {
                std::printf(", \"index\": %d", i);
            }
            std::printf(", \"key\": %s },\n", quoted(field.key).c_str());

            std::string init_text =
                    format_raw(field, i, init, field.get(&init, i));
            check_loads_back(field, i, init, field.get(&init, i), init_text,
                             "init value does not load back");
            if (field.kind == PF_NAME) {
                std::printf("      \"kind\": \"name\",\n      \"names\": [");
                for (int32_t n = 0; field.names[n]; n++) {
                    std::printf("%s%s", n ? ", " : "",
                                quoted(field.names[n]).c_str());
                }
                std::printf("],\n      \"initValue\": %s\n", init_text.c_str());
            } else {
                std::printf("      \"kind\": \"number\",\n");
                std::printf("      \"integer\": %s,\n",
                            field.integer ? "true" : "false");
                std::printf("      \"nearest\": \"%s\",\n",
                            nearest_metric(field, i, init));
                bool special = init_text == "inf" || init_text == "-inf";
                std::printf(special ? "      \"initValue\": \"%s\",\n"
                                    : "      \"initValue\": %s,\n",
                            init_text.c_str());
                put_number(fields, k, i, init);
            }
            std::printf("    }");
        }
    }
    std::printf("\n  ]\n}\n");
}

// The C enum name of a parameter ID: osc[0].tune → NOAIDI_PARAM_OSC0_TUNE.
std::string enum_name(std::string_view id) {
    std::string name = "NOAIDI_PARAM_";
    for (char c : id) {
        if (c == '[' || c == ']') {
            continue;
        }
        name += c == '.' ? '_'
                         : static_cast<char>(
                                   std::toupper(static_cast<unsigned char>(c)));
    }
    return name;
}

// --c-header: the parameter IDs as a C enum for the display
// (display/include/noaidi_param_ids.h), in manifest order, so an ID's
// value is its index in parameters.json. Written in the layout
// clang-format gives it (make format-check).
void put_c_header(const std::vector<std::string> &ids) {
    std::printf(
            "// noaidi_param_ids.h — the synth's semantic parameter IDs, for C\n"
            "//\n"
            "// Copyright © 2026 Thor H. Linløkken <thj@thj.no>\n"
            "// License: CERN-OHL-S v2\n"
            "//\n"
            "// GENERATED by companion/tools/gen_manifest from "
            "app/main/preset_units.c;\n"
            "// do not edit: run make -C companion manifest.\n"
            "//\n"
            "// The same parameters in the same order as\n"
            "// companion/src/generated/parameters.json: an ID's value is "
            "its index\n"
            "// there. IDs only; what a parameter can hold is in the "
            "manifest.\n"
            "\n"
            "#pragma once\n"
            "\n"
            "typedef enum {\n");
    // clang-format aligns the = signs and the trailing comments
    size_t name_width = std::string_view("NOAIDI_PARAM_NONE").size();
    for (const std::string &id : ids) {
        name_width = std::max(name_width, enum_name(id).size());
    }
    int value_width =
            static_cast<int>(std::to_string(ids.size() - 1).size()) + 1;
    std::printf("    %-*s = -1,\n", static_cast<int>(name_width),
                "NOAIDI_PARAM_NONE");
    for (size_t k = 0; k < ids.size(); k++) {
        std::string value = std::to_string(k) + ",";
        std::printf("    %-*s = %-*s // %s\n", static_cast<int>(name_width),
                    enum_name(ids[k]).c_str(), value_width, value.c_str(),
                    ids[k].c_str());
    }
    std::printf("    NOAIDI_PARAM_COUNT\n"
                "} noaidi_param_t;\n");
}

} // namespace

int main(int argc, char **argv) {
    preset_t init;
    preset_init(&init);
    size_t count                 = 0;
    const preset_field_t *fields = preset_fields(&count);

    std::vector<std::string> ids;
    std::set<std::string> seen;
    for (size_t k = 0; k < count; k++) {
        for (int i = 0; i < fields[k].count; i++) {
            std::string id = param_id(fields[k], i);
            if (!seen.insert(id).second) {
                fail(id, "duplicate ID", "");
            }
            ids.push_back(id);
        }
    }

    if (argc == 2 && std::string_view(argv[1]) == "--c-header") {
        put_c_header(ids);
    } else {
        put_manifest(fields, count, init);
    }

    std::fprintf(stderr, "gen_manifest: %zu parameters from %zu keys\n",
                 ids.size(), count);
    if (failures) {
        std::fprintf(stderr, "gen_manifest: %d check(s) failed\n", failures);
        return 1;
    }
    return 0;
}
