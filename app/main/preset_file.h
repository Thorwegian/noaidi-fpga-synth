// preset_file.h — read and write preset files (docs/storage_format.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A preset file is TOML in musical units. Reading starts from the init
// preset (preset_init), so a missing key takes the init preset's value, as
// does an unknown name; unknown keys and tables are ignored, and an
// out-of-range value clamps. A file that is not valid TOML, or whose format is newer than
// PRESET_FILE_FORMAT, is not read. The conversions are preset_units.h's.
//
// C++ (preset_file.cpp) with a C interface; plain stdio and POSIX, so
// the host test (app/test) uses it too. Saving goes through safe_file.hpp.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

#include "preset.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PRESET_FILE_FORMAT 1

// Read a preset file into *p. On failure *p is untouched and err holds the
// reason.
bool preset_file_read(const char *path, preset_t *p, char *err, size_t err_len);

// Read a preset file from text already in memory.
bool preset_file_parse(const char *text, size_t len, preset_t *p, char *err,
                       size_t err_len);

// Write *p as a preset file.
void preset_file_write(FILE *out, const preset_t *p);

// Save *p to path safely (docs/storage_format.md "Saving"): write
// path.new ending with the line "# end", flush it to the medium, delete
// path, rename path.new to path. A power loss at any point leaves either
// the old preset or the new one, once preset_file_recover() has run. A
// path under Presets/Factory/ starts with the copyright notice
// (preset_file::factory_notice): Factory presets are source files.
bool preset_file_save(const char *path, const preset_t *p, char *err,
                      size_t err_len);

// Finish or undo interrupted saves under dir, recursively: a complete
// .new file (it ends with "# end") replaces its preset, an incomplete one
// is deleted. Returns the number of files repaired.
int preset_file_recover(const char *dir);

// Whether name is a valid preset name: UTF-8, 1-64 characters, none of
// \ / : * ? " < > | or control characters, no leading or trailing space,
// no trailing dot.
bool preset_name_valid(const char *name);

// Print every key where a and b differ as stored, as
// "table.key: <a> -> <b>". Values that behave identically count as
// equal. Returns the number of differences.
int preset_file_diff(FILE *out, const preset_t *a, const preset_t *b);

#ifdef __cplusplus
}

#include <string>
#include <string_view>

// The same, for C++ callers.
namespace preset_file {

// The notice every source file carries (AGENTS.md). save() starts a
// Factory preset with it, so a preset saved on the board and committed to
// the repo keeps it; the loader ignores it, like any comment.
inline constexpr std::string_view factory_notice =
        "# Copyright © 2026 Thor H. Linløkken <thj@thj.no>\n"
        "# License: CERN-OHL-S v2\n";

// Whether path lies under Presets/Factory/ (compared as FAT does,
// ignoring case).
bool factory_path(const std::string &path);

bool parse(std::string_view text, preset_t &p, std::string &error);
bool read(const std::string &path, preset_t &p, std::string &error);
std::string to_text(const preset_t &p); // the values alone, no notice
bool save(const std::string &path, const preset_t &p, std::string &error);

} // namespace preset_file
#endif
