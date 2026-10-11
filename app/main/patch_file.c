// patch_file.c — read and write patch files (see patch_file.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "patch_file.h"

#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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
    patch_init(&q);
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

// ── Saving ──────────────────────────────────────────────────────────
#define END_LINE "# end\n"     // the last line of a complete .new file

bool patch_file_save(const char *path, const patch_t *p, char *err, size_t err_len)
{
    char tmp[320];
    if (snprintf(tmp, sizeof tmp, "%s.new", path) >= (int)sizeof tmp) {
        snprintf(err, err_len, "path too long");
        return false;
    }
    FILE *out = fopen(tmp, "w");
    if (!out) {
        snprintf(err, err_len, "cannot create %s", tmp);
        return false;
    }
    patch_file_write(out, p);
    fputs(END_LINE, out);
    bool ok = fflush(out) == 0 && fsync(fileno(out)) == 0;
    ok = (fclose(out) == 0) && ok;
    if (!ok) {
        remove(tmp);
        snprintf(err, err_len, "cannot write %s (storage full?)", tmp);
        return false;
    }
    remove(path);                          // absent for a new patch
    if (rename(tmp, path) != 0) {
        snprintf(err, err_len, "cannot rename %s", tmp);
        return false;
    }
    return true;
}

// Whether a .new file is complete: it ends with END_LINE.
static bool new_file_complete(const char *path)
{
    FILE *in = fopen(path, "rb");
    if (!in)
        return false;
    char tail[sizeof END_LINE] = {0};
    long n = (long)strlen(END_LINE);
    bool ok = fseek(in, -n, SEEK_END) == 0 && fread(tail, 1, (size_t)n, in) == (size_t)n
              && memcmp(tail, END_LINE, (size_t)n) == 0;
    fclose(in);
    return ok;
}

int patch_file_recover(const char *dir)
{
    DIR *d = opendir(dir);
    if (!d)
        return 0;
    int repaired = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.')
            continue;
        char path[320];
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        struct stat st;
        if (stat(path, &st) != 0)
            continue;
        if (S_ISDIR(st.st_mode)) {
            repaired += patch_file_recover(path);
            continue;
        }
        size_t len = strlen(path);
        if (len < 5 || strcmp(path + len - 4, ".new") != 0)
            continue;
        if (new_file_complete(path)) {     // finish the save
            char target[320];
            snprintf(target, sizeof target, "%.*s", (int)(len - 4), path);
            remove(target);
            rename(path, target);
        } else {                            // undo it: the old patch stays
            remove(path);
        }
        repaired++;
    }
    closedir(d);
    return repaired;
}

bool patch_name_valid(const char *name)
{
    size_t len = strlen(name);
    if (len == 0 || name[0] == ' ' || name[len - 1] == ' ' || name[len - 1] == '.')
        return false;
    size_t chars = 0;
    for (const unsigned char *c = (const unsigned char *)name; *c; c++) {
        if (*c < 0x20 || *c == 0x7F || strchr("\\/:*?\"<>|", *c))
            return false;
        if ((*c & 0xC0) != 0x80)           // count UTF-8 characters, not bytes
            chars++;
    }
    return chars <= 64;
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
