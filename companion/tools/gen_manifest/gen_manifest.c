// gen_manifest.c — the companion's parameter manifest, generated from the
// firmware's patch-file table
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Compiles app/main/patch_units.c and app/main/patch.c unchanged and writes
// one JSON entry per semantic parameter (osc[0].tune, filter.cutoff, ...)
// to stdout. Nothing about a parameter is written down here: everything is
// asked of patch_fields(), so the companion holds no second engine model.
//
//   id        semantic parameter ID: table, [index] for arrays of tables
//             (0-based), key
//   file      where format 1 stores it: TOML table, array index, key
//   kind      "number" or "name"
//   names     a name key's names, by raw value
//   default   the init patch's value (patch_init)
//   integer   a number key that takes whole numbers only
//   range     min and max of the finite values the key can hold. The
//             loader clamps to this range; it is found by loading ±1e300
//   special   values outside the finite range: "inf", "-inf"
//   valueCount  how many distinct values the key can hold
//   values    all of them, ascending, when there are at most VALUES_MAX
//   dependsOn the parameter whose value changes this one's conversion,
//             found by changing every earlier key and watching this one.
//             A name dependency gives "byValue": range, valueCount and
//             values per name. A number dependency gives the union of
//             the ranges and no valueCount or values
//
// Every number is the actual musical value to 6 significant digits, more
// where 6 do not load back to the same raw value (see format_raw). The
// array is in the order the loader applies the keys.
//
// Self-checks: every listed value, every range end and every default loads
// back, through the firmware's own conversions, to the canonical raw value
// it came from, and every ID is unique. A failed check exits non-zero.

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "patch.h"
#include "patch_file.h"
#include "patch_units.h"

#define VALUES_MAX   1024   // list every value of keys with at most this many
#define PROBE_POINTS 17     // raw values compared when looking for dependencies
#define BIG          1e300  // loads as the clamped end of any range

typedef struct {
    int32_t lo, hi;         // raw values of the finite range ends, lo <= hi
    int     num_special;
    int32_t special[2];     // raw values of ±inf
} domain_t;

typedef struct {
    double  min, max;       // finite values
    int32_t min_raw, max_raw;
    long    count;
    int     listed;         // entries in raws[] (count, if count <= VALUES_MAX)
    int32_t raws[VALUES_MAX];
} value_set_t;

static int failures;

static void fail(const char *id, const char *what, const char *text)
{
    fprintf(stderr, "gen_manifest: %s: %s (%s)\n", id, what, text);
    failures++;
}

static void param_id(const patch_field_t *f, int i, char *buf, size_t len)
{
    if (f->count > 1) snprintf(buf, len, "%s[%d].%s", f->table, i, f->key);
    else              snprintf(buf, len, "%s.%s", f->table, f->key);
}

// v to the given significant digits, as a plain decimal (JSON-safe, no
// exponent), trailing zeros removed.
static void format_significant(double v, int digits, char *buf, size_t len)
{
    if (v == 0.0) {
        snprintf(buf, len, "0");
        return;
    }
    int decimals = digits - 1 - (int)floor(log10(fabs(v)));
    snprintf(buf, len, "%.*f", decimals > 0 ? decimals : 0, v);
    if (strchr(buf, '.')) {
        char *end = buf + strlen(buf) - 1;
        while (*end == '0') *end-- = '\0';
        if (*end == '.') *end = '\0';
    }
    if (buf[0] == '-' && strtod(buf, NULL) == 0.0)   // "-0" is zero
        memmove(buf, buf + 1, strlen(buf));
}

// Raw value raw of element i as text: a quoted name, "inf"/"-inf", or its
// actual musical value to SIGNIFICANT_DIGITS, more if that does not load
// back to the same (canonical) raw value. Not the firmware writer's
// shortest decimal: at a clamped range end any value beyond the end loads
// back, so the shortest is not the value (the fastest attack writes as 0,
// the highest tune as 50 instead of 48). The manifest says what the engine
// does; how a value looks on screen is the display layer's business.
#define SIGNIFICANT_DIGITS 6
static void format_raw(const patch_field_t *f, int i, const patch_t *p, int32_t raw,
                       char *buf, size_t len)
{
    patch_t q = *p;
    f->set(&q, i, raw);
    if (f->kind == PF_NAME) {
        patch_field_format(f, i, &q, buf, len);
        return;
    }
    int32_t want = patch_field_canonical(f, i, &q, raw);
    double  v    = f->to_value(&q, i, want);
    if (isinf(v)) {
        snprintf(buf, len, v > 0 ? "inf" : "-inf");
        return;
    }
    for (int digits = SIGNIFICANT_DIGITS; digits <= 17; digits++) {
        format_significant(v, digits, buf, len);
        if (f->to_raw(&q, i, strtod(buf, NULL)) == want)
            break;
    }
}

// Load text back the way the firmware does and compare with raw value raw's
// canonical form.
static void check_loads_back(const patch_field_t *f, int i, const patch_t *p, int32_t raw,
                             const char *text, const char *what)
{
    char id[64];
    param_id(f, i, id, sizeof id);
    patch_t q = *p;
    raw = patch_field_canonical(f, i, p, raw);
    if (f->kind == PF_NAME) {
        char name[64];
        snprintf(name, sizeof name, "%.*s", (int)strlen(text) - 2, text + 1);  // unquote
        if (!patch_field_set_name(f, i, &q, name) || f->get(&q, i) != raw)
            fail(id, what, text);
        return;
    }
    double v = strcmp(text, "inf") == 0 ? INFINITY : strcmp(text, "-inf") == 0 ? -INFINITY
             : strtod(text, NULL);
    patch_field_set_number(f, i, &q, v);
    if (f->get(&q, i) != raw)
        fail(id, what, text);
}

static domain_t domain_of(const patch_field_t *f, int i, const patch_t *p)
{
    domain_t d = {0};
    int32_t a = f->to_raw(p, i, -BIG), b = f->to_raw(p, i, BIG);
    d.lo = a < b ? a : b;
    d.hi = a < b ? b : a;
    const double infs[2] = { -INFINITY, INFINITY };
    for (int k = 0; k < 2; k++) {
        int32_t r = f->to_raw(p, i, infs[k]);
        if ((r < d.lo || r > d.hi) && isinf(f->to_value(p, i, r)))
            d.special[d.num_special++] = r;
    }
    return d;
}

// Every distinct value of element i: the raw values that are their own
// canonical form.
static void value_set(const patch_field_t *f, int i, const patch_t *p, value_set_t *s)
{
    domain_t d = domain_of(f, i, p);
    s->count  = 0;
    s->listed = 0;
    for (int32_t raw = d.lo; ; raw++) {
        if (patch_field_canonical(f, i, p, raw) == raw) {
            double v = f->to_value(p, i, raw);
            if (s->count == 0 || v < s->min) { s->min = v; s->min_raw = raw; }
            if (s->count == 0 || v > s->max) { s->max = v; s->max_raw = raw; }
            if (s->count < VALUES_MAX) s->raws[s->listed++] = raw;
            s->count++;
        }
        if (raw == d.hi) break;
    }
    if (s->count > VALUES_MAX) s->listed = 0;
}

// What a dependency would change: the range ends and the values at a few
// raw values spread over the range.
static void signature(const patch_field_t *f, int i, const patch_t *p, double out[PROBE_POINTS + 2])
{
    domain_t d = domain_of(f, i, p);
    out[0] = d.lo;
    out[1] = d.hi;
    for (int k = 0; k < PROBE_POINTS; k++) {
        int32_t raw = d.lo + (int32_t)(((int64_t)d.hi - d.lo) * k / (PROBE_POINTS - 1));
        out[k + 2] = f->to_value(p, i, raw);
    }
}

static int signature_differs(const double *a, const double *b)
{
    for (int k = 0; k < PROBE_POINTS + 2; k++)
        if (!(a[k] == b[k]) && !(isnan(a[k]) && isnan(b[k])))
            return 1;
    return 0;
}

// The raw values worth trying for element j of g: every name, or a number
// key's range ends.
static int alternatives(const patch_field_t *g, int j, const patch_t *p, int32_t *out, int max)
{
    int n = 0;
    if (g->kind == PF_NAME) {
        for (int32_t k = 0; g->names[k] && n < max; k++) out[n++] = k;
    } else {
        domain_t d = domain_of(g, j, p);
        out[n++] = d.lo;
        out[n++] = d.hi;
    }
    return n;
}

// The one earlier parameter element i of fields[k] depends on, if any.
static int find_dependency(const patch_field_t *fields, size_t k, int i, const patch_t *init,
                           int *dep_j)
{
    const patch_field_t *f = &fields[k];
    double base[PROBE_POINTS + 2], probe[PROBE_POINTS + 2];
    signature(f, i, init, base);
    int found = -1;
    for (size_t g = 0; g < k; g++)
        for (int j = 0; j < fields[g].count; j++) {
            int32_t alt[16];
            int n = alternatives(&fields[g], j, init, alt, 16);
            for (int a = 0; a < n; a++) {
                patch_t q = *init;
                fields[g].set(&q, j, alt[a]);
                signature(f, i, &q, probe);
                if (signature_differs(base, probe)) {
                    char id[64];
                    param_id(f, i, id, sizeof id);
                    if (found >= 0 && (found != (int)g || *dep_j != j))
                        fail(id, "depends on more than one parameter", "not supported");
                    found  = (int)g;
                    *dep_j = j;
                    break;
                }
            }
        }
    return found;
}

// ── JSON output ─────────────────────────────────────────────────────

static void put_string(const char *s)
{
    putchar('"');
    for (; *s; s++) {
        if (*s == '"' || *s == '\\') putchar('\\');
        putchar(*s);
    }
    putchar('"');
}

// qsort has no context argument: the element whose raw values it sorts
static struct { const patch_field_t *f; int i; const patch_t *p; } sort_by;

static int cmp_by_value(const void *a, const void *b)
{
    double va = sort_by.f->to_value(sort_by.p, sort_by.i, *(const int32_t *)a);
    double vb = sort_by.f->to_value(sort_by.p, sort_by.i, *(const int32_t *)b);
    return va < vb ? -1 : va > vb;
}

// "range", "special", "valueCount" and "values" of one value set,
// checking that every value written loads back.
static void put_value_set(const patch_field_t *f, int i, const patch_t *p, value_set_t *s,
                          const char *indent)
{
    char text[64];
    format_raw(f, i, p, s->min_raw, text, sizeof text);
    check_loads_back(f, i, p, s->min_raw, text, "range min does not load back");
    printf("%s\"range\": { \"min\": %s, ", indent, text);
    format_raw(f, i, p, s->max_raw, text, sizeof text);
    check_loads_back(f, i, p, s->max_raw, text, "range max does not load back");
    printf("\"max\": %s }", text);

    domain_t d = domain_of(f, i, p);
    if (d.num_special) {
        printf(",\n%s\"special\": [", indent);
        for (int k = 0; k < d.num_special; k++) {
            format_raw(f, i, p, d.special[k], text, sizeof text);
            check_loads_back(f, i, p, d.special[k], text, "special value does not load back");
            printf("%s\"%s\"", k ? ", " : "", text);
        }
        putchar(']');
    }
    printf(",\n%s\"valueCount\": %ld", indent, s->count + d.num_special);
    if (s->listed) {
        sort_by.f = f; sort_by.i = i; sort_by.p = p;
        qsort(s->raws, (size_t)s->listed, sizeof s->raws[0], cmp_by_value);
        printf(",\n%s\"values\": [", indent);
        for (int k = 0; k < s->listed; k++) {
            format_raw(f, i, p, s->raws[k], text, sizeof text);
            check_loads_back(f, i, p, s->raws[k], text, "value does not load back");
            printf("%s%s", k ? ", " : "", text);
        }
        putchar(']');
    }
}

// The ends of the union of element i's ranges over every value of g[j]:
// each end's raw value and the raw value of g[j] it occurs at.
typedef struct {
    double  min, max;
    int32_t min_raw, max_raw, min_g, max_g;
} union_t;

static void union_over(const patch_field_t *f, int i, const patch_field_t *g, int j,
                       const patch_t *init, union_t *u)
{
    static value_set_t s;
    domain_t gd = { 0 };
    if (g->kind == PF_NAME)
        while (g->names[gd.hi + 1]) gd.hi++;
    else
        gd = domain_of(g, j, init);
    int first = 1;
    for (int32_t graw = gd.lo; ; graw++) {
        if (g->kind == PF_NAME || patch_field_canonical(g, j, init, graw) == graw) {
            patch_t q = *init;
            g->set(&q, j, graw);
            value_set(f, i, &q, &s);
            if (first || s.min < u->min) { u->min = s.min; u->min_raw = s.min_raw; u->min_g = graw; }
            if (first || s.max > u->max) { u->max = s.max; u->max_raw = s.max_raw; u->max_g = graw; }
            first = 0;
        }
        if (graw == gd.hi) break;
    }
}

// "range" of a dependent parameter: the union, each end written in the
// state it occurs in.
static void put_union_range(const patch_field_t *f, int i, const patch_field_t *g, int j,
                            const patch_t *init, const char *indent)
{
    union_t u;
    char text[64];
    union_over(f, i, g, j, init, &u);
    patch_t qa = *init, qb = *init;
    g->set(&qa, j, u.min_g);
    g->set(&qb, j, u.max_g);
    format_raw(f, i, &qa, u.min_raw, text, sizeof text);
    check_loads_back(f, i, &qa, u.min_raw, text, "range min does not load back");
    printf("%s\"range\": { \"min\": %s, ", indent, text);
    format_raw(f, i, &qb, u.max_raw, text, sizeof text);
    check_loads_back(f, i, &qb, u.max_raw, text, "range max does not load back");
    printf("\"max\": %s }", text);
}

static void put_number(const patch_field_t *fields, size_t k, int i, const patch_t *init)
{
    static value_set_t s;
    const patch_field_t *f = &fields[k];
    int dep_j = 0;
    int dep = find_dependency(fields, k, i, init, &dep_j);

    if (dep < 0) {
        value_set(f, i, init, &s);
        put_value_set(f, i, init, &s, "      ");
        printf("\n");
        return;
    }
    const patch_field_t *g = &fields[dep];
    char gid[64];
    param_id(g, dep_j, gid, sizeof gid);
    printf("      \"dependsOn\": ");
    put_string(gid);
    printf(",\n");

    put_union_range(f, i, g, dep_j, init, "      ");
    if (g->kind == PF_NAME) {
        printf(",\n      \"byValue\": {\n");
        for (int32_t n = 0; g->names[n]; n++) {
            patch_t q = *init;
            g->set(&q, dep_j, n);
            value_set(f, i, &q, &s);
            printf("%s        ", n ? ",\n" : "");
            put_string(g->names[n]);
            printf(": {\n");
            put_value_set(f, i, &q, &s, "          ");
            printf("\n        }");
        }
        printf("\n      }");
    }
    printf("\n");
}

int main(void)
{
    patch_t init;
    patch_init(&init);
    size_t n;
    const patch_field_t *fields = patch_fields(&n);

    // unique IDs
    char ids[256][64];
    int num_ids = 0;
    for (size_t k = 0; k < n; k++)
        for (int i = 0; i < fields[k].count; i++) {
            param_id(&fields[k], i, ids[num_ids], sizeof ids[0]);
            for (int m = 0; m < num_ids; m++)
                if (strcmp(ids[m], ids[num_ids]) == 0)
                    fail(ids[num_ids], "duplicate ID", "");
            num_ids++;
        }

    printf("{\n");
    printf("  \"generatedBy\": \"companion/tools/gen_manifest from app/main/patch_units.c; do not edit\",\n");
    printf("  \"patchFileFormat\": %d,\n", PATCH_FILE_FORMAT);
    printf("  \"parameters\": [\n");
    int first = 1;
    for (size_t k = 0; k < n; k++) {
        const patch_field_t *f = &fields[k];
        for (int i = 0; i < f->count; i++) {
            char id[64], text[64];
            param_id(f, i, id, sizeof id);
            printf("%s    {\n", first ? "" : ",\n");
            first = 0;
            printf("      \"id\": ");
            put_string(id);
            printf(",\n      \"file\": { \"table\": ");
            put_string(f->table);
            if (f->count > 1) printf(", \"index\": %d", i);
            printf(", \"key\": ");
            put_string(f->key);
            printf(" },\n");

            format_raw(f, i, &init, f->get(&init, i), text, sizeof text);
            check_loads_back(f, i, &init, f->get(&init, i), text, "default does not load back");

            if (f->kind == PF_NAME) {
                printf("      \"kind\": \"name\",\n      \"names\": [");
                for (int32_t m = 0; f->names[m]; m++) {
                    printf("%s", m ? ", " : "");
                    put_string(f->names[m]);
                }
                printf("],\n      \"default\": %s\n", text);
            } else {
                printf("      \"kind\": \"number\",\n");
                printf("      \"integer\": %s,\n", f->integer ? "true" : "false");
                if (strcmp(text, "inf") == 0 || strcmp(text, "-inf") == 0)
                    printf("      \"default\": \"%s\",\n", text);
                else
                    printf("      \"default\": %s,\n", text);
                put_number(fields, k, i, &init);
            }
            printf("    }");
        }
    }
    printf("\n  ]\n}\n");

    fprintf(stderr, "gen_manifest: %d parameters from %zu keys\n", num_ids, n);
    if (failures) {
        fprintf(stderr, "gen_manifest: %d check(s) failed\n", failures);
        return 1;
    }
    return 0;
}
