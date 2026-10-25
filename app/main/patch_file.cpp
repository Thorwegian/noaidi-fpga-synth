// patch_file.cpp — read and write patch files (see patch_file.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "patch_file.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <string>
#include <string_view>

#include "patch_units.h"
#include "safe_file.hpp"
#include "toml.hpp"

namespace {

// The table that holds element i of field f: [table] for a single table,
// the i-th [[table]] for an array of tables.
std::optional<toml::Value> field_table(const toml::Value &top,
                                       const patch_field_t &f, int i) {
    auto t = top.get(f.table);
    if (!t) {
        return std::nullopt;
    }
    if (f.count == 1) {
        return t->is_table() ? t : std::nullopt;
    }
    auto elems = t->elements();
    if (i >= static_cast<int>(elems.size()) || !elems[i].is_table()) {
        return std::nullopt;
    }
    return elems[i];
}

std::string field_text(const patch_field_t &f, int i, const patch_t &p) {
    char text[64];
    patch_field_format(&f, i, &p, text, sizeof text);
    return text;
}

} // namespace

namespace patch_file {

bool parse(std::string_view text, patch_t &p, std::string &error) {
    toml::Document doc(text);
    if (!doc.ok()) {
        error = doc.error();
        return false;
    }
    auto format  = doc.root().get("format");
    auto version = format ? format->as_int() : std::nullopt;
    if (!version || *version < 1 || *version > PATCH_FILE_FORMAT) {
        error = version ? "format " + std::to_string(*version)
                                  + " is newer than "
                                  + std::to_string(PATCH_FILE_FORMAT)
                        : "no format key";
        return false;
    }

    patch_t q;
    patch_init(&q);
    size_t n;
    const patch_field_t *fields = patch_fields(&n);
    for (size_t k = 0; k < n; k++) { // table order: dependencies first
        const patch_field_t &f = fields[k];
        for (int i = 0; i < f.count; i++) {
            auto table = field_table(doc.root(), f, i);
            auto value = table ? table->get(f.key) : std::nullopt;
            if (!value) {
                continue; // the key keeps the init value
            }
            if (f.kind == PF_NAME) {
                if (auto name = value->as_string()) {
                    patch_field_set_name(&f, i, &q, std::string(*name).c_str());
                }
            } else if (auto whole = value->as_int()) {
                patch_field_set_number(&f, i, &q, static_cast<double>(*whole));
            } else if (auto real = value->as_real()) {
                patch_field_set_number(&f, i, &q, *real);
            }
        }
    }
    p = q;
    return true;
}

bool read(const std::string &path, patch_t &p, std::string &error) {
    FILE *in = std::fopen(path.c_str(), "rb");
    if (!in) {
        error = "cannot open " + path;
        return false;
    }
    // Straight into a heap string: these run on tasks with small stacks.
    std::fseek(in, 0, SEEK_END);
    long size = std::ftell(in);
    std::fseek(in, 0, SEEK_SET);
    std::string text(size > 0 ? static_cast<size_t>(size) : 0, '\0');
    bool read_ok =
            size >= 0
            && std::fread(text.data(), 1, text.size(), in) == text.size();
    std::fclose(in);
    if (!read_ok) {
        error = "cannot read " + path;
        return false;
    }
    return parse(text, p, error);
}

std::string to_text(const patch_t &p) {
    size_t n;
    const patch_field_t *fields = patch_fields(&n);
    std::string text = "format = " + std::to_string(PATCH_FILE_FORMAT) + "\n";
    // The fields of one table sit together in the table, so a table is
    // written once per element: [voice], [[osc]] twice, [filter], ...
    for (size_t k = 0; k < n;) {
        size_t end = k;
        while (end < n
               && std::strcmp(fields[end].table, fields[k].table) == 0) {
            end++;
        }
        for (int i = 0; i < fields[k].count; i++) {
            text += fields[k].count == 1 ? "\n[" : "\n[[";
            text += fields[k].table;
            text += fields[k].count == 1 ? "]\n" : "]]\n";
            for (size_t j = k; j < end; j++) {
                text += std::string(fields[j].key) + " = "
                        + field_text(fields[j], i, p) + "\n";
            }
        }
        k = end;
    }
    return text;
}

bool factory_path(std::string_view path) {
    constexpr std::string_view folder = "/patches/factory/";
    auto same                         = [](char a, char b) {
        return std::tolower(static_cast<unsigned char>(a))
               == std::tolower(static_cast<unsigned char>(b));
    };
    return std::search(path.begin(), path.end(), folder.begin(), folder.end(),
                       same)
           != path.end();
}

bool save(const std::string &path, const patch_t &p, std::string &error) {
    const std::string text = to_text(p);
    return safe_file::save(
            path,
            factory_path(path) ? std::string(factory_notice) + text : text,
            error);
}

} // namespace patch_file

// ── The C interface ─────────────────────────────────────────────────
namespace {

bool report(bool ok, const std::string &error, char *err, size_t err_len) {
    if (!ok) {
        std::snprintf(err, err_len, "%s", error.c_str());
    }
    return ok;
}

} // namespace

bool patch_file_parse(const char *text, size_t len, patch_t *p, char *err,
                      size_t err_len) {
    std::string error;
    return report(patch_file::parse(std::string_view(text, len), *p, error),
                  error, err, err_len);
}

bool patch_file_read(const char *path, patch_t *p, char *err, size_t err_len) {
    std::string error;
    return report(patch_file::read(path, *p, error), error, err, err_len);
}

void patch_file_write(FILE *out, const patch_t *p) {
    std::fputs(patch_file::to_text(*p).c_str(), out);
}

bool patch_file_save(const char *path, const patch_t *p, char *err,
                     size_t err_len) {
    std::string error;
    return report(patch_file::save(path, *p, error), error, err, err_len);
}

int patch_file_recover(const char *dir) {
    return safe_file::recover(dir);
}

bool patch_name_valid(const char *name) {
    std::string_view s(name);
    if (s.empty() || s.front() == ' ' || s.back() == ' ' || s.back() == '.') {
        return false;
    }
    size_t chars = 0;
    for (unsigned char c : s) {
        if (c < 0x20 || c == 0x7F || std::strchr("\\/:*?\"<>|", c)) {
            return false;
        }
        if ((c & 0xC0) != 0x80) { // count UTF-8 characters, not bytes
            chars++;
        }
    }
    return chars <= 64;
}

int patch_file_diff(FILE *out, const patch_t *a, const patch_t *b) {
    size_t n;
    const patch_field_t *fields = patch_fields(&n);
    int diffs                   = 0;
    for (size_t k = 0; k < n; k++) {
        const patch_field_t &f = fields[k];
        for (int i = 0; i < f.count; i++) {
            if (patch_field_canonical(&f, i, a, f.get(a, i))
                == patch_field_canonical(&f, i, b, f.get(b, i))) {
                continue;
            }
            const std::string where =
                    f.count == 1
                            ? std::string(f.table) + "." + f.key
                            : std::string(f.table) + "[" + std::to_string(i + 1)
                                      + "]." + f.key;
            std::fprintf(out, "  %s: %s -> %s\n", where.c_str(),
                         field_text(f, i, *a).c_str(),
                         field_text(f, i, *b).c_str());
            diffs++;
        }
    }
    return diffs;
}
