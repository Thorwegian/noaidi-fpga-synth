// patch_tool.c — the firmware's patch-file reader and writer, on the
// computer, for the companion's compatibility tests
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Compiles app/main/patch_file.c, patch_units.c, patch.c and tomlc17
// unchanged.
//
//   patch_tool canon <file>     read the file as the synth does and write
//                               it back as the synth would save it
//   patch_tool diff <a> <b>     print every key where the two files load
//                               differently; exit 1 if any
//
// A file the synth would not load exits 2 with the reason.

#include <stdio.h>
#include <string.h>

#include "patch.h"
#include "patch_file.h"

static int read_or_fail(const char *path, patch_t *p)
{
    char err[160];
    if (patch_file_read(path, p, err, sizeof err))
        return 1;
    fprintf(stderr, "patch_tool: %s: %s\n", path, err);
    return 0;
}

int main(int argc, char **argv)
{
    patch_t a, b;
    if (argc == 3 && strcmp(argv[1], "canon") == 0) {
        if (!read_or_fail(argv[2], &a)) return 2;
        patch_file_write(stdout, &a);
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "diff") == 0) {
        if (!read_or_fail(argv[2], &a) || !read_or_fail(argv[3], &b)) return 2;
        return patch_file_diff(stdout, &a, &b) > 0 ? 1 : 0;
    }
    fprintf(stderr, "usage: patch_tool canon <file> | patch_tool diff <a> <b>\n");
    return 2;
}
