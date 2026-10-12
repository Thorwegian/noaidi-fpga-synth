// patch_file.h — read and write patch files (docs/storage_format.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A patch file is TOML in musical units. Reading starts from the init
// patch (patch_init), so a missing key takes the init patch's value, as
// does an unknown name; unknown keys and tables are ignored, and an
// out-of-range value clamps. A file that is not valid TOML, or whose format is newer than
// PATCH_FILE_FORMAT, is not read. The conversions are patch_units.h's.
//
// C++ (patch_file.cpp) with a C interface; plain stdio and POSIX, so
// the host test (app/test) uses it too. Saving goes through safe_file.hpp.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

#include "patch.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PATCH_FILE_FORMAT 1

// Read a patch file into *p. On failure *p is untouched and err holds the
// reason.
bool patch_file_read(const char *path, patch_t *p, char *err, size_t err_len);

// Read a patch file from text already in memory.
bool patch_file_parse(const char *text, size_t len, patch_t *p, char *err,
                      size_t err_len);

// Write *p as a patch file.
void patch_file_write(FILE *out, const patch_t *p);

// Save *p to path safely (docs/storage_format.md "Saving"): write
// path.new ending with the line "# end", flush it to the medium, delete
// path, rename path.new to path. A power loss at any point leaves either
// the old patch or the new one, once patch_file_recover() has run.
bool patch_file_save(const char *path, const patch_t *p, char *err,
                     size_t err_len);

// Finish or undo interrupted saves under dir, recursively: a complete
// .new file (it ends with "# end") replaces its patch, an incomplete one
// is deleted. Returns the number of files repaired.
int patch_file_recover(const char *dir);

// Whether name is a valid patch name: UTF-8, 1-64 characters, none of
// \ / : * ? " < > | or control characters, no leading or trailing space,
// no trailing dot.
bool patch_name_valid(const char *name);

// Print every key where a and b differ as stored, as
// "table.key: <a> -> <b>". Values that behave identically count as
// equal. Returns the number of differences.
int patch_file_diff(FILE *out, const patch_t *a, const patch_t *b);

#ifdef __cplusplus
}

#include <string>
#include <string_view>

// The same, for C++ callers.
namespace patch_file {
bool parse(std::string_view text, patch_t &p, std::string &error);
bool read(const std::string &path, patch_t &p, std::string &error);
std::string to_text(const patch_t &p);
bool save(const std::string &path, const patch_t &p, std::string &error);
} // namespace patch_file
#endif
