// preset_tool.cpp — the firmware's preset-file reader and writer, on the
// computer, for the companion's compatibility tests
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Compiles app/main/preset_file.cpp, preset_units.c, preset.cpp,
// safe_file.cpp and tomlc17 unchanged.
//
//   preset_tool canon <file>     read the file as the synth does and write
//                                it back as the synth would save it
//   preset_tool diff <a> <b>     print every key where the two files load
//                                differently; exit 1 if any
//   preset_tool name <name>      exit 0 if name is a valid preset name
//                                (preset_name_valid), 1 if not
//
// A file the synth would not load exits 2 with the reason.

#include <cstdio>
#include <string>
#include <string_view>

#include "preset.h"
#include "preset_file.h"

namespace {

bool read_or_fail(const char *path, preset_t &p) {
    std::string error;
    if (preset_file::read(path, p, error)) {
        return true;
    }
    std::fprintf(stderr, "preset_tool: %s: %s\n", path, error.c_str());
    return false;
}

} // namespace

int main(int argc, char **argv) {
    preset_t a;
    preset_t b;
    if (argc == 3 && std::string_view(argv[1]) == "canon") {
        if (!read_or_fail(argv[2], a)) {
            return 2;
        }
        std::string text = preset_file::to_text(a);
        std::fwrite(text.data(), 1, text.size(), stdout);
        return 0;
    }
    if (argc == 4 && std::string_view(argv[1]) == "diff") {
        if (!read_or_fail(argv[2], a) || !read_or_fail(argv[3], b)) {
            return 2;
        }
        return preset_file_diff(stdout, &a, &b) > 0 ? 1 : 0;
    }
    if (argc == 3 && std::string_view(argv[1]) == "name") {
        return preset_name_valid(argv[2]) ? 0 : 1;
    }
    std::fprintf(stderr, "usage: preset_tool canon <file> | preset_tool diff "
                         "<a> <b> | preset_tool name <name>\n");
    return 2;
}
