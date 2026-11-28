// preset_file.cpp — read and write preset files (see preset_file.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "preset_file.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include <dirent.h>
#include <strings.h>

#include "preset_units.hpp"
#include "safe_file.hpp"
#include "toml.hpp"

namespace {

using preset_units::Range;
using Names = std::span<const char *const>;

// The loader, a visitor of the keys: a key the file has goes into its field;
// one it lacks, or that holds something else than the key's kind (a string
// for a number, a name the key does not have, a number that is not one),
// leaves the field as it is.
class Loader {
public:
    explicit Loader(const toml::Value &root) : root_(root) {}

    void table(const char *name) {
        table_ = root_.get(name);
    }

    void element(const char *name, int index) {
        const auto array = root_.get(name);
        const std::vector<toml::Value> elements =
                array ? array->elements() : std::vector<toml::Value>{};
        table_ = static_cast<size_t>(index) < elements.size()
                         ? std::optional(elements[static_cast<size_t>(index)])
                         : std::nullopt;
    }

    void number(const char *key, float &field, const Range &range) {
        const auto value = table_ ? table_->get(key) : std::nullopt;
        if (!value) {
            return;
        }
        if (const auto whole = value->as_int()) {
            field = preset_units::within(range, static_cast<double>(*whole));
        } else if (const auto real = value->as_real();
                   real && !std::isnan(*real)) {
            field = preset_units::within(range, *real);
        }
    }

    template <typename Name>
    void name(const char *key, Name &field, Names names) {
        const auto value = table_ ? table_->get(key) : std::nullopt;
        const auto text  = value ? value->as_string() : std::nullopt;
        if (!text) {
            return;
        }
        const auto found = std::ranges::find(names, *text, [](const char *n) {
            return std::string_view(n);
        });
        if (found != names.end()) {
            field = static_cast<Name>(found - names.begin());
        }
    }

private:
    toml::Value root_;
    std::optional<toml::Value> table_;
};

// A key as the writer writes it, and where it is.
struct Entry {
    std::string table;
    int element; // of an array of tables, from 0; −1 in a table of its own
    std::string key;
    std::string text;

    bool same_table(const Entry &other) const {
        return table == other.table && element == other.element;
    }
};

// The writer's side of the keys, a visitor too: every key's text, in order.
class Entries {
public:
    void table(const char *name) {
        table_   = name;
        element_ = -1;
    }

    void element(const char *name, int index) {
        table_   = name;
        element_ = index;
    }

    void number(const char *key, const float &field, const Range &range) {
        entries_.push_back(
                {table_, element_, key, preset_units::text(range, field)});
    }

    template <typename Name>
    void name(const char *key, const Name &field, Names names) {
        entries_.push_back(
                {table_, element_, key,
                 preset_units::text(names, static_cast<int>(field))});
    }

    static std::vector<Entry> of(const preset_t &preset) {
        Entries entries;
        preset_units::visit(preset, entries);
        return std::move(entries.entries_);
    }

private:
    std::string table_;
    int element_ = -1;
    std::vector<Entry> entries_;
};

} // namespace

namespace preset_file {

bool parse(std::string_view text, preset_t &p, std::string &error) {
    toml::Document doc(text);
    if (!doc.ok()) {
        error = doc.error();
        return false;
    }
    auto format  = doc.root().get("format");
    auto version = format ? format->as_int() : std::nullopt;
    if (!version || *version < 1 || *version > PRESET_FILE_FORMAT) {
        error = version ? "format " + std::to_string(*version)
                                  + " is newer than "
                                  + std::to_string(PRESET_FILE_FORMAT)
                        : "no format key";
        return false;
    }

    preset_t loaded;
    preset_init(&loaded);
    preset_units::visit(loaded, Loader(doc.root()));
    p = loaded;
    return true;
}

bool read(const std::string &path, preset_t &p, std::string &error) {
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

std::string to_text(const preset_t &p) {
    std::string text = "format = " + std::to_string(PRESET_FILE_FORMAT) + "\n";
    const Entry *previous = nullptr;
    for (const Entry &entry : Entries::of(p)) {
        if (previous == nullptr || !entry.same_table(*previous)) {
            text += entry.element < 0 ? "\n[" + entry.table + "]\n"
                                      : "\n[[" + entry.table + "]]\n";
        }
        text += entry.key + " = " + entry.text + "\n";
        previous = &entry;
    }
    return text;
}

bool factory_path(const std::string &path) {
    return strcasestr(path.c_str(), "/Presets/Factory/") != nullptr;
}

bool save(const std::string &path, const preset_t &p, std::string &error) {
    const std::string text = to_text(p);
    return safe_file::save(
            path,
            factory_path(path) ? std::string(factory_notice) + text : text,
            error);
}

} // namespace preset_file

// ── The C interface ─────────────────────────────────────────────────
bool preset_file_read(const char *path, preset_t *p, char *err,
                      size_t err_len) {
    std::string error;
    const bool ok = preset_file::read(path, *p, error);
    if (!ok) {
        std::snprintf(err, err_len, "%s", error.c_str());
    }
    return ok;
}

int preset_file_recover(const char *dir) {
    return safe_file::recover(dir);
}

// Why storage_format.md's name rule refuses a name, in the console's
// words; nullptr when the rule allows it.
static const char *name_fault(std::string_view s) {
    if (s.empty()) {
        return "a name is 1 to 64 characters";
    }
    if (s.front() == ' ' || s.back() == ' ' || s.back() == '.') {
        return "a name does not start or end with a space, and does not end "
               "with a dot";
    }
    size_t chars = 0;
    for (unsigned char c : s) {
        if (c < 0x20 || c == 0x7F || std::strchr("\\/:*?\"<>|", c)) {
            return "a name holds none of \\ / : * ? \" < > | and no control "
                   "character";
        }
        if ((c & 0xC0) != 0x80) { // count UTF-8 characters, not bytes
            chars++;
        }
    }
    if (chars > 64) {
        return "a name is 1 to 64 characters";
    }
    return nullptr;
}

// Why the storage refuses name as a new preset in folder (a filesystem
// path); nullptr when it may be written. A file already holding the name
// is the caller's to judge.
const char *preset_name_refusal(const char *folder, const char *name) {
    const std::string_view stem(name);
    if (const char *fault = name_fault(stem)) {
        return fault;
    }
    DIR *d = opendir(folder);
    if (!d) {
        return nullptr; // no folder to compare with; the save reports it
    }
    while (dirent *e = readdir(d)) {
        const size_t len = std::strlen(e->d_name);
        if (len < 6 || strcasecmp(e->d_name + len - 5, ".toml") != 0) {
            continue;
        }
        const std::string_view other(e->d_name, len - 5);
        if (other.size() != stem.size()
            || strncasecmp(other.data(), stem.data(), stem.size()) != 0
            || std::memcmp(other.data(), stem.data(), stem.size()) == 0) {
            continue;
        }
        closedir(d);
        // FAT compares names case-insensitively: two names a letter case
        // apart are one file to the storage and two to the player.
        return "a name differs from every other in the folder by more than "
               "letter case";
    }
    closedir(d);
    return nullptr;
}
