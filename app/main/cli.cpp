// cli.cpp — the serial console's file and patch commands (see cli.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "cli.h"
#include "cli_shell.hpp"

#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#include "esp_app_desc.h"

#include "ble_midi.h"
#include "patch.h"
#include "patch_file.h"
#include "storage.h"
#include "voice_alloc.h"

namespace cli {

namespace {

std::string g_cwd     = "/Patches";   // from the storage root
std::string g_current = "init patch"; // the active patch, for the status bar

void show_status() {
    console_set_status("noaidi %s | %s", esp_app_get_description()->version,
                       g_current.c_str());
}

void show_prompt() {
    console_set_prompt((g_cwd + " $ ").c_str());
}

bool is_dir(const std::string &fs) {
    struct stat st;
    return stat(fs.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

void complete_entries(const char *prefix, void (*add)(const char *),
                      bool dirs_only) {
    std::string_view typed(prefix);
    size_t slash = typed.rfind('/');
    std::string_view dir_part =
            slash == std::string_view::npos ? "" : typed.substr(0, slash + 1);
    std::string_view base = typed.substr(dir_part.size());

    DIR *d = opendir(
            fs_path(resolve(dir_part.empty() ? "." : dir_part)).c_str());
    if (!d) {
        return;
    }
    while (dirent *e = readdir(d)) {
        if (e->d_name[0] == '.'
            || strncasecmp(e->d_name, base.data(), base.size()) != 0) {
            continue;
        }
        bool dir = e->d_type == DT_DIR;
        if (dirs_only && !dir) {
            continue;
        }
        std::string candidate =
                std::string(dir_part) + e->d_name + (dir ? "/" : "");
        add(candidate.c_str());
    }
    closedir(d);
}

// ── Commands ────────────────────────────────────────────────────────
int cmd_help(int, char **) {
    const console_cmd_t *const *cmds;
    int n = console_commands(&cmds);
    for (int i = 0; i < n; i++) {
        std::printf("  %-6s %-22s %s\n", cmds[i]->name, cmds[i]->usage,
                    cmds[i]->help);
    }
    std::printf(
            "  Paths are relative to the working directory; Tab completes,\n");
    std::printf("  up/down recall, PgUp/PgDn page the output, Return on an\n");
    std::printf("  empty line redraws the screen.\n");
    return 0;
}

int cmd_cd(int argc, char **argv) {
    std::string abs = resolve(argc > 1 ? argv[1] : "/Patches");
    if (!is_dir(fs_path(abs))) {
        std::printf("cd: no folder %s\n", abs.c_str());
        return 1;
    }
    g_cwd = abs;
    show_prompt();
    return 0;
}

int cmd_pwd(int, char **) {
    std::printf("%s\n", g_cwd.c_str());
    return 0;
}

int cmd_ls(int argc, char **argv) {
    std::string abs = resolve(argc > 1 ? argv[1] : ".");
    std::string fs  = fs_path(abs);
    DIR *d          = opendir(fs.c_str());
    if (!d) {
        std::printf("ls: no folder %s\n", abs.c_str());
        return 1;
    }
    int n = 0;
    while (dirent *e = readdir(d)) {
        if (e->d_name[0] == '.') {
            continue;
        }
        if (e->d_type == DT_DIR) {
            std::printf("  %s/\n", e->d_name);
        } else {
            struct stat st;
            bool ok = stat((fs + "/" + e->d_name).c_str(), &st) == 0;
            std::printf("  %-40s %6ld\n", e->d_name,
                        ok ? static_cast<long>(st.st_size) : -1L);
        }
        n++;
    }
    closedir(d);
    if (n == 0) {
        std::printf("  (empty)\n");
    }
    return 0;
}

int cmd_load(int argc, char **argv) {
    if (argc != 2) {
        std::printf("usage: load <file>\n");
        return 1;
    }
    std::string abs = resolve(argv[1]), error;
    patch_t p;
    if (!patch_file::read(fs_path(abs), p, error)) {
        std::printf("load: %s\n", error.c_str());
        return 1;
    }
    if (!voice_alloc_set_patch(&p)) {
        std::printf("load: the synth did not answer\n");
        return 1;
    }
    set_current(abs);
    std::printf("loaded %s\n", abs.c_str());
    return 0;
}

int cmd_init(int, char **) {
    patch_t p;
    patch_init(&p);
    if (!voice_alloc_set_patch(&p)) {
        std::printf("init: the synth did not answer\n");
        return 1;
    }
    set_current("init patch");
    std::printf("loaded the init patch\n");
    return 0;
}

int cmd_save(int argc, char **argv) {
    if (argc != 2) {
        std::printf("usage: save <file>\n");
        return 1;
    }
    std::string abs = resolve(argv[1]), error;
    patch_t p;
    if (!voice_alloc_get_patch(&p)) {
        std::printf("save: the synth did not answer\n");
        return 1;
    }
    if (!patch_file::save(fs_path(abs), p, error)) {
        std::printf("save: %s\n", error.c_str());
        return 1;
    }
    set_current(abs);
    std::printf("saved %s\n", abs.c_str());
    return 0;
}

int cmd_rm(int argc, char **argv) {
    if (argc != 2) {
        std::printf("usage: rm <file>\n");
        return 1;
    }
    std::string abs = resolve(argv[1]), fs = fs_path(abs);
    if (is_dir(fs) || std::remove(fs.c_str()) != 0) {
        std::printf("rm: no file %s\n", abs.c_str());
        return 1;
    }
    std::printf("removed %s\n", abs.c_str());
    return 0;
}

int cmd_mkdir(int argc, char **argv) {
    if (argc != 2) {
        std::printf("usage: mkdir <folder>\n");
        return 1;
    }
    std::string abs = resolve(argv[1]);
    if (mkdir(fs_path(abs).c_str(), 0775) != 0) {
        std::printf("mkdir: cannot create %s\n", abs.c_str());
        return 1;
    }
    return 0;
}

int cmd_rmdir(int argc, char **argv) {
    if (argc != 2) {
        std::printf("usage: rmdir <folder>\n");
        return 1;
    }
    std::string abs = resolve(argv[1]);
    if (abs == g_cwd || rmdir(fs_path(abs).c_str()) != 0) {
        std::printf("rmdir: cannot remove %s (not empty, or in use)\n",
                    abs.c_str());
        return 1;
    }
    return 0;
}

int cmd_patch(int, char **) {
    patch_t p;
    if (!voice_alloc_get_patch(&p)) {
        std::printf("patch: the synth did not answer\n");
        return 1;
    }
    std::printf("# %s\n%s", g_current.c_str(), patch_file::to_text(p).c_str());
    std::fflush(stdout);
    return 0;
}

int cmd_ble(int, char **) {
    ble_midi_console_status();
    return 0;
}

const console_cmd_t commands[] = {
        {"help", "", "list the commands", cmd_help, nullptr},
        {"cd", "[folder]", "change folder (default /Patches)", cmd_cd,
         complete_dir},
        {"pwd", "", "print the working folder", cmd_pwd, nullptr},
        {"ls", "[folder]", "list a folder", cmd_ls, complete_dir},
        {"mkdir", "<folder>", "create a folder", cmd_mkdir, complete_dir},
        {"rmdir", "<folder>", "remove an empty folder", cmd_rmdir,
         complete_dir},
        {"load", "<file>", "load a patch file", cmd_load, complete_path},
        {"init", "", "load the init patch", cmd_init, nullptr},
        {"save", "<file>", "save the active patch to a file", cmd_save,
         complete_path},
        {"rm", "<file>", "delete a file", cmd_rm, complete_path},
        {"patch", "", "print the active patch as a patch file", cmd_patch,
         nullptr},
        {"ble", "", "BLE MIDI status; re-advertise if needed", cmd_ble,
         nullptr},
};

} // namespace

// ── Shared with the other command files (cli_shell.hpp) ─────────────
std::string resolve(std::string_view arg) {
    std::string joined = (!arg.empty() && arg.front() == '/')
                                 ? std::string(arg)
                                 : g_cwd + "/" + std::string(arg);
    std::vector<std::string> parts;
    size_t start = 0;
    while (start <= joined.size()) {
        size_t end = joined.find('/', start);
        if (end == std::string::npos) {
            end = joined.size();
        }
        std::string part = joined.substr(start, end - start);
        if (part == "..") {
            if (!parts.empty()) {
                parts.pop_back();
            }
        } else if (!part.empty() && part != ".") {
            parts.push_back(std::move(part));
        }
        start = end + 1;
    }
    std::string out;
    for (const std::string &part : parts) {
        out += "/" + part;
    }
    return out.empty() ? "/" : out;
}

std::string fs_path(std::string_view abs) {
    return std::string(STORAGE_ROOT)
           + (abs == "/" ? std::string() : std::string(abs));
}

void set_current(std::string_view name) {
    g_current = std::string(name);
    show_status();
}

void complete_path(int argi, const char *prefix, void (*add)(const char *)) {
    if (argi == 1) {
        complete_entries(prefix, add, false);
    }
}

void complete_dir(int argi, const char *prefix, void (*add)(const char *)) {
    if (argi == 1) {
        complete_entries(prefix, add, true);
    }
}

} // namespace cli

void cli_init(void) {
    cli::register_commands(cli::commands);
    cli::register_bank_commands();
    cli_system_init();
    cli_csp_init();
    // A Program Change names its patch on the status bar.
    voice_alloc_set_patch_listener([](const char *name) {
        cli::set_current(std::string("/") + name);
    });
    const char *startup = storage_startup_patch();
    cli::set_current(startup[0] ? std::string("/") + startup
                                : std::string("init patch"));
    cli::show_prompt();
}
