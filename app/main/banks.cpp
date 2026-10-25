// banks.cpp — the bank map (see banks.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "banks.hpp"

#include <algorithm>
#include <charconv>
#include <cstdio>

#include "safe_file.hpp"
#include "toml.hpp"

namespace banks {

namespace {

constexpr int file_format = 1;

// A bank's key, "0" … "16383", as a number.
std::optional<int> bank_number(std::string_view key) {
    int n          = 0;
    auto [end, ec] = std::from_chars(key.data(), key.data() + key.size(), n);
    if (ec != std::errc() || end != key.data() + key.size() || n < 0
        || n > max_bank) {
        return std::nullopt;
    }
    return n;
}

// A TOML basic string.
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

} // namespace

bool parse(std::string_view text, BankMap &banks, std::string &error) {
    toml::Document doc(text);
    if (!doc.ok()) {
        error = doc.error();
        return false;
    }
    auto format  = doc.root().get("format");
    auto version = format ? format->as_int() : std::nullopt;
    if (!version || *version < 1 || *version > file_format) {
        error = version ? "format " + std::to_string(*version)
                                  + " is newer than "
                                  + std::to_string(file_format)
                        : "no format key";
        return false;
    }
    BankMap out;
    if (auto table = doc.root().get("bank")) {
        for (const auto &[key, value] : table->entries()) {
            auto number = bank_number(key);
            if (!number || !value.is_table()) {
                continue;
            }
            Bank bank;
            if (auto name = value.get("name"); name && name->as_string()) {
                bank.name = *name->as_string();
            }
            if (auto programs = value.get("programs")) {
                for (const toml::Value &entry : programs->elements()) {
                    if (auto path = entry.as_string();
                        path
                        && static_cast<int>(bank.programs.size())
                                   < max_programs) {
                        bank.programs.emplace_back(*path);
                    }
                }
            }
            out[*number] = std::move(bank);
        }
    }
    banks = std::move(out);
    return true;
}

bool read(const std::string &path, BankMap &banks, std::string &error) {
    FILE *in = std::fopen(path.c_str(), "rb");
    if (!in) { // no file: no banks
        banks.clear();
        return true;
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
    return parse(text, banks, error);
}

std::string to_text(const BankMap &banks) {
    std::string text = "format = " + std::to_string(file_format) + "\n";
    for (const auto &[number, bank] : banks) {
        text += "\n[bank." + std::to_string(number) + "]\n";
        text += "name = " + quoted(bank.name) + "\n";
        if (bank.programs.empty()) {
            text += "programs = []\n";
            continue;
        }
        // One program per line, its number in a comment; the comments
        // line up one column past the longest path.
        size_t widest = 0;
        for (const std::string &program : bank.programs) {
            widest = std::max(widest, quoted(program).size());
        }
        text += "programs = [\n";
        for (size_t p = 0; p < bank.programs.size(); p++) {
            const std::string entry = quoted(bank.programs[p]) + ",";
            text += "    " + entry + std::string(widest + 2 - entry.size(), ' ')
                    + "# " + std::to_string(p) + "\n";
        }
        text += "]\n";
    }
    return text;
}

bool save(const std::string &path, const BankMap &banks, std::string &error) {
    return safe_file::save(path, to_text(banks), error);
}

std::optional<std::string> program_path(const BankMap &banks, int bank,
                                        int program) {
    auto it = banks.find(bank);
    if (it == banks.end() || program < 0
        || program >= static_cast<int>(it->second.programs.size())) {
        return std::nullopt;
    }
    return it->second.programs[static_cast<size_t>(program)];
}

} // namespace banks

bool banks_program_path(const char *banks_path, int bank, int program,
                        char *path, size_t len) {
    banks::BankMap map;
    std::string error;
    if (!banks::read(banks_path, map, error)) {
        return false;
    }
    auto found = banks::program_path(map, bank, program);
    if (!found) {
        return false;
    }
    std::snprintf(path, len, "%s", found->c_str());
    return true;
}
