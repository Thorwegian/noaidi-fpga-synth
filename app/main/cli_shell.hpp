// cli_shell.hpp — the console shell's shared state, for its command files
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The working folder, path resolution and the status bar's patch name,
// shared by cli.cpp and cli_banks.cpp.

#pragma once

#include <string>
#include <string_view>
#include <vector>

#include "console.h"

namespace cli {

// A path as typed, absolute ("/Patches/User") or relative to the working
// folder, resolved against it with "." and "..": "/" or
// "/Patches/User/Pads".
std::string resolve(std::string_view arg);

// The file system path of a resolved path: "/storage/Patches/User/Pads".
std::string fs_path(std::string_view abs);

// The patch the status bar names.
void set_current(std::string_view name);

// Tab completion of paths relative to the working folder, for argument
// argi of a command (1 = first).
void complete_path(int argi, const char *prefix, void (*add)(const char *));
void complete_dir(int argi, const char *prefix, void (*add)(const char *));

// Register a table of commands.
template <size_t N>
void register_commands(const console_cmd_t (&commands)[N]) {
    for (const console_cmd_t &c : commands) {
        console_register(&c);
    }
}

// The bank commands (cli_banks.cpp).
void register_bank_commands();

} // namespace cli
