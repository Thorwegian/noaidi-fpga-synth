// patch_file.c — read and write patch files (see patch_file.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "patch_file.h"

#include <stdlib.h>
#include <string.h>

#include "patch_units.h"
#include "tomlc17.h"

// Element i of the table that holds field f: [table] for a single table,
// the i-th [[table]] for an array of tables. TOML_UNKNOWN if absent.
static toml_datum_t field_table(toml_datum_t top, const patch_field_t *f, int i)
{
    toml_datum_t t = toml_get(top, f->table);
    if (f->count == 1)
        return t.type == TOML_TABLE ? t : (toml_datum_t){0};
    if (t.type != TOML_ARRAY || i >= t.u.arr.size || t.u.arr.elem[i].type != TOML_TABLE)
        return (toml_datum_t){0};
    return t.u.arr.elem[i];
}

bool patch_file_parse(const char *text, size_t len, patch_t *p, char *err, size_t err_len)
{
    toml_result_t r = toml_parse(text, (int)len);
    if (!r.ok) {
        snprintf(err, err_len, "%s", r.errmsg);
        toml_free(r);
        return false;
    }
    toml_datum_t fmt = toml_get(r.toptab, "format");
    if (fmt.type != TOML_INT64 || fmt.u.int64 < 1 || fmt.u.int64 > PATCH_FILE_FORMAT) {
        snprintf(err, err_len, fmt.type == TOML_INT64 ? "format %lld is newer than %d"
                                                      : "no format key",
                 fmt.type == TOML_INT64 ? (long long)fmt.u.int64 : 0LL, PATCH_FILE_FORMAT);
        toml_free(r);
        return false;
    }

    patch_t q;
    patch_default(&q);
    size_t n;
    const patch_field_t *fields = patch_fields(&n);
    for (size_t k = 0; k < n; k++) {               // table order: dependencies first
        const patch_field_t *f = &fields[k];
        for (int i = 0; i < f->count; i++) {
            toml_datum_t v = toml_get(field_table(r.toptab, f, i), f->key);
            if (f->kind == PF_NAME && v.type == TOML_STRING)
                patch_field_set_name(f, i, &q, v.u.s);
            else if (f->kind == PF_NUMBER && v.type == TOML_INT64)
                patch_field_set_number(f, i, &q, (double)v.u.int64);
            else if (f->kind == PF_NUMBER && v.type == TOML_FP64)
                patch_field_set_number(f, i, &q, v.u.fp64);
            // anything else: the key keeps its default
        }
    }
    toml_free(r);
    *p = q;
    return true;
}

bool patch_file_read(const char *path, patch_t *p, char *err, size_t err_len)
{
    FILE *in = fopen(path, "rb");
    if (!in) {
        snprintf(err, err_len, "cannot open %s", path);
        return false;
    }
    fseek(in, 0, SEEK_END);
    long size = ftell(in);
    fseek(in, 0, SEEK_SET);
    char *text = (size >= 0) ? malloc((size_t)size + 1) : NULL;
    if (!text || fread(text, 1, (size_t)size, in) != (size_t)size) {
        snprintf(err, err_len, "cannot read %s", path);
        free(text);
        fclose(in);
        return false;
    }
    fclose(in);
    text[size] = '\0';
    bool ok = patch_file_parse(text, (size_t)size, p, err, err_len);
    free(text);
    return ok;
}

void patch_file_write(FILE *out, const patch_t *p)
{
    size_t n;
    const patch_field_t *fields = patch_fields(&n);
    fprintf(out, "format = %d\n", PATCH_FILE_FORMAT);
    // The fields of one table sit together in the table, so a table is
    // written once per element: [voice], [[osc]] twice, [filter], ...
    for (size_t k = 0; k < n; ) {
        size_t end = k;
        while (end < n && strcmp(fields[end].table, fields[k].table) == 0)
            end++;
        for (int i = 0; i < fields[k].count; i++) {
            fprintf(out, fields[k].count == 1 ? "\n[%s]\n" : "\n[[%s]]\n", fields[k].table);
            for (size_t j = k; j < end; j++) {
                char text[64];
                patch_field_format(&fields[j], i, p, text, sizeof text);
                fprintf(out, "%s = %s\n", fields[j].key, text);
            }
        }
        k = end;
    }
}

int patch_file_diff(FILE *out, const patch_t *a, const patch_t *b)
{
    size_t n;
    const patch_field_t *fields = patch_fields(&n);
    int diffs = 0;
    for (size_t k = 0; k < n; k++) {
        const patch_field_t *f = &fields[k];
        for (int i = 0; i < f->count; i++) {
            if (patch_field_canonical(f, i, a, f->get(a, i)) ==
                patch_field_canonical(f, i, b, f->get(b, i)))
                continue;
            char ta[64], tb[64];
            patch_field_format(f, i, a, ta, sizeof ta);
            patch_field_format(f, i, b, tb, sizeof tb);
            if (f->count == 1)
                fprintf(out, "  %s.%s: %s -> %s\n", f->table, f->key, ta, tb);
            else
                fprintf(out, "  %s[%d].%s: %s -> %s\n", f->table, i + 1, f->key, ta, tb);
            diffs++;
        }
    }
    return diffs;
}
