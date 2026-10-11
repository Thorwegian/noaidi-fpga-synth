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
// Plain C with stdio: the host test (app/test) uses it too.

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
bool patch_file_parse(const char *text, size_t len, patch_t *p, char *err, size_t err_len);

// Write *p as a patch file.
void patch_file_write(FILE *out, const patch_t *p);

// Print every key where a and b differ as stored, as
// "table.key: <a> -> <b>". Values that behave identically count as
// equal. Returns the number of differences.
int patch_file_diff(FILE *out, const patch_t *a, const patch_t *b);

#ifdef __cplusplus
}
#endif
