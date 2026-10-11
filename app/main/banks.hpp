// banks.hpp — the bank map: MIDI Bank Select and Program Change → patch files
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// banks.toml (docs/storage_format.md "Banks") holds numbered banks, each a
// name and a list of patch paths whose positions are the program numbers.
// This module reads, edits and writes it; saving goes through
// safe_file.hpp. A C interface below lets the C modules look a program up.
//
// Plain C++ with stdio: the host test (app/test) uses it too.

#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace banks {

constexpr int max_bank = 16383;      // MSB × 128 + LSB
constexpr int max_programs = 128;    // per bank: programs 0 … 127

struct Bank {
    std::string name;
    std::vector<std::string> programs;   // paths from the storage root
};

using BankMap = std::map<int, Bank>;

// Read banks.toml text. Unknown keys are ignored, as are banks numbered
// outside 0 … max_bank and programs beyond max_programs.
bool parse(std::string_view text, BankMap &banks, std::string &error);

// Read a banks file. A missing file is an empty map, not an error.
bool read(const std::string &path, BankMap &banks, std::string &error);

// The file text for banks.
std::string to_text(const BankMap &banks);

// Save banks to path the safe way.
bool save(const std::string &path, const BankMap &banks, std::string &error);

// The path of a program, if bank and program exist.
std::optional<std::string> program_path(const BankMap &banks, int bank, int program);

} // namespace banks

extern "C" {
#endif

// Look a program up in the banks file at banks_path: copies the patch's
// path (from the storage root) to path. False if the file, the bank or the
// program does not exist.
bool banks_program_path(const char *banks_path, int bank, int program, char *path, size_t len);

#ifdef __cplusplus
}
#endif
