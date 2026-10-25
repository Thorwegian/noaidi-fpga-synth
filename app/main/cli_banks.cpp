// cli_banks.cpp — the serial console's bank commands
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// bank                               list the banks
// bank <n>                           list bank n's programs
// bank add <n> <file>                append a preset to bank n
// bank insert <n> <program> <file>   insert at program; later ones move up
// bank rm <n> <program>              delete program; later ones move down
// bank new <n> <name>                create bank n
// bank del <n>                       delete bank n
// bank build <n> <folder>            a new bank from the .toml files in a
//                                    folder and its subfolders, in path
//                                    order
//
// Every change reads banks.toml, edits it and saves it the safe way.
// Preset paths are typed like any other path and stored from the storage
// root.

#include "cli_shell.hpp"

#include <algorithm>
#include <charconv>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <optional>
#include <strings.h>

#include "banks.hpp"
#include "preset_file.h"
#include "storage.h"

namespace cli {

namespace {

const std::string banks_file = std::string(STORAGE_ROOT) + "/banks.toml";

std::optional<int> number(const char *text, int max) {
    int n           = 0;
    const char *end = text + std::strlen(text);
    auto [ptr, ec]  = std::from_chars(text, end, n);
    if (ec != std::errc() || ptr != end || n < 0 || n > max) {
        return std::nullopt;
    }
    return n;
}

// A preset argument as stored in banks.toml: resolved, without the
// leading "/". Empty if it is not a readable preset file.
std::string preset_entry(const char *arg) {
    std::string abs = resolve(arg), error;
    preset_t p;
    if (!preset_file::read(fs_path(abs), p, error)) {
        std::printf("bank: %s: %s\n", abs.c_str(), error.c_str());
        return {};
    }
    return abs.substr(1);
}

bool load(banks::BankMap &banks) {
    std::string error;
    if (!banks::read(banks_file, banks, error)) {
        std::printf("bank: banks.toml: %s\n", error.c_str());
        return false;
    }
    return true;
}

bool store(const banks::BankMap &banks) {
    std::string error;
    if (!banks::save(banks_file, banks, error)) {
        std::printf("bank: %s\n", error.c_str());
        return false;
    }
    return true;
}

void list_banks(const banks::BankMap &banks) {
    if (banks.empty()) {
        std::printf("  no banks\n");
    }
    for (const auto &[n, bank] : banks) {
        std::printf("  %5d  %-24s %3zu program%s\n", n, bank.name.c_str(),
                    bank.programs.size(), bank.programs.size() == 1 ? "" : "s");
    }
}

void list_programs(const banks::Bank &bank) {
    std::printf("  %s\n", bank.name.c_str());
    if (bank.programs.empty()) {
        std::printf("  (empty)\n");
    }
    for (size_t p = 0; p < bank.programs.size(); p++) {
        std::printf("  %3zu  %s\n", p, bank.programs[p].c_str());
    }
}

// The .toml files in a folder and its subfolders, as stored in
// banks.toml (from the storage root), in path order (case-insensitive).
void collect_presets(const std::string &abs, std::vector<std::string> &out) {
    DIR *d = opendir(fs_path(abs).c_str());
    if (!d) {
        return;
    }
    const std::string prefix = abs == "/" ? std::string() : abs.substr(1) + "/";
    while (dirent *e = readdir(d)) {
        if (e->d_name[0] == '.') {
            continue;
        }
        size_t len = std::strlen(e->d_name);
        if (e->d_type == DT_DIR) {
            collect_presets((abs == "/" ? "" : abs) + "/" + e->d_name, out);
        } else if (len > 5 && strcasecmp(e->d_name + len - 5, ".toml") == 0) {
            out.push_back(prefix + e->d_name);
        }
    }
    closedir(d);
}

std::vector<std::string> folder_presets(const char *arg) {
    std::vector<std::string> paths;
    collect_presets(resolve(arg), paths);
    std::sort(paths.begin(), paths.end(),
              [](const std::string &a, const std::string &b) {
                  return strcasecmp(a.c_str(), b.c_str()) < 0;
              });
    return paths;
}

int usage() {
    std::printf(
            "usage: bank [<n> | add <n> <file> | insert <n> <program> <file> |\n"
            "             rm <n> <program> | new <n> <name> | del <n> | build <n> <folder>]\n");
    return 1;
}

int cmd_bank(int argc, char **argv) {
    banks::BankMap banks;
    if (!load(banks)) {
        return 1;
    }
    if (argc == 1) {
        list_banks(banks);
        return 0;
    }
    if (auto n = number(argv[1], banks::max_bank); n && argc == 2) {
        auto it = banks.find(*n);
        if (it == banks.end()) {
            std::printf("bank: no bank %d\n", *n);
            return 1;
        }
        list_programs(it->second);
        return 0;
    }
    const std::string op = argv[1];
    auto n = argc > 2 ? number(argv[2], banks::max_bank) : std::nullopt;
    if (!n) {
        return usage();
    }
    auto it     = banks.find(*n);
    bool exists = it != banks.end();

    if (op == "new" && argc == 4) {
        if (exists) {
            std::printf("bank: bank %d exists\n", *n);
            return 1;
        }
        banks[*n].name = argv[3];
    } else if (op == "del" && argc == 3) {
        if (!exists) {
            std::printf("bank: no bank %d\n", *n);
            return 1;
        }
        banks.erase(it);
    } else if (op == "build" && argc == 4) {
        if (exists && !it->second.programs.empty()) {
            std::printf("bank: bank %d is not empty; bank del %d first\n", *n,
                        *n);
            return 1;
        }
        std::vector<std::string> presets = folder_presets(argv[3]);
        if (presets.empty()) {
            std::printf("bank: no .toml files in %s or below\n", argv[3]);
            return 1;
        }
        if (presets.size() > banks::max_programs) {
            presets.resize(banks::max_programs);
        }
        banks::Bank &bank = banks[*n];
        if (bank.name.empty()) {
            std::string folder = resolve(argv[3]);
            bank.name          = folder.substr(folder.rfind('/') + 1);
        }
        bank.programs = std::move(presets);
    } else if ((op == "add" && argc == 4) || (op == "insert" && argc == 5)) {
        if (!exists) {
            std::printf("bank: no bank %d; bank new %d <name> first\n", *n, *n);
            return 1;
        }
        auto &programs = it->second.programs;
        if (programs.size() >= banks::max_programs) {
            std::printf("bank: bank %d is full\n", *n);
            return 1;
        }
        std::optional<int> at = static_cast<int>(programs.size());
        if (op == "insert") {
            at = number(argv[3], static_cast<int>(programs.size()));
        }
        if (!at) {
            std::printf("bank: program out of range\n");
            return 1;
        }
        std::string entry = preset_entry(argv[op == "insert" ? 4 : 3]);
        if (entry.empty()) {
            return 1;
        }
        programs.insert(programs.begin() + *at, entry);
    } else if (op == "rm" && argc == 4) {
        if (!exists) {
            std::printf("bank: no bank %d\n", *n);
            return 1;
        }
        auto &programs = it->second.programs;
        auto p         = number(argv[3], static_cast<int>(programs.size()) - 1);
        if (!p) {
            std::printf("bank: no program %s in bank %d\n", argv[3], *n);
            return 1;
        }
        programs.erase(programs.begin() + *p);
    } else {
        return usage();
    }

    if (!store(banks)) {
        return 1;
    }
    if (op == "del") {
        std::printf("deleted bank %d\n", *n);
    } else {
        list_programs(banks[*n]);
    }
    return 0;
}

// Completion: the subcommands, then paths where a path goes.
void complete_bank(int argi, const char *prefix, void (*add)(const char *)) {
    static const char *const ops[] = {"add", "insert", "rm",
                                      "new", "del",    "build"};
    if (argi == 1) {
        for (const char *op : ops) {
            if (std::strncmp(op, prefix, std::strlen(prefix)) == 0) {
                add(op);
            }
        }
        return;
    }
    // bank add <n> <file> / bank build <n> <folder>: argument 3;
    // bank insert <n> <program> <file>: argument 4. The command line is
    // not available here, so offer paths at both.
    if (argi == 3 || argi == 4) {
        complete_path(1, prefix, add);
    }
}

const console_cmd_t commands[] = {
        {"bank", "[<n> | <op> ...]", "list and edit the banks (banks.toml)",
         cmd_bank, complete_bank},
};

} // namespace

void register_bank_commands() {
    register_commands(commands);
}

} // namespace cli
