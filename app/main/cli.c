// cli.c — the serial console's commands (see cli.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "cli.h"

#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#include "esp_app_desc.h"

#include "ble_midi.h"
#include "console.h"
#include "patch.h"
#include "patch_file.h"
#include "storage.h"
#include "voice_alloc.h"

#define PATH_LEN  256

static char s_cwd[PATH_LEN] = "/Patches";       // from the storage root
static char s_current[PATH_LEN] = "init patch"; // the active patch, for the status bar

static void show_status(void)
{
    console_set_status("noaidi %s | %s", esp_app_get_description()->version, s_current);
}

static void show_prompt(void)
{
    char prompt[PATH_LEN + 4];
    snprintf(prompt, sizeof prompt, "%s $ ", s_cwd);
    console_set_prompt(prompt);
}

// ── Paths ───────────────────────────────────────────────────────────
// A path as the user types it, absolute ("/Patches/User") or relative to
// the working directory, resolved to an absolute path from the storage
// root with "." and ".." applied: "/" or "/Patches/User/Pads".
static void resolve(const char *arg, char *out, size_t len)
{
    char tmp[2 * PATH_LEN];
    if (arg[0] == '/') snprintf(tmp, sizeof tmp, "%s", arg);
    else               snprintf(tmp, sizeof tmp, "%s/%s", s_cwd, arg);
    char *parts[24];
    int n = 0;
    for (char *save, *t = strtok_r(tmp, "/", &save); t; t = strtok_r(NULL, "/", &save)) {
        if (strcmp(t, ".") == 0)
            continue;
        if (strcmp(t, "..") == 0) { if (n) n--; continue; }
        if (n < 24) parts[n++] = t;
    }
    size_t o = 0;
    out[0] = '\0';
    for (int i = 0; i < n && o < len; i++)
        o += (size_t)snprintf(out + o, len - o, "/%s", parts[i]);
    if (n == 0) snprintf(out, len, "/");
}

// The file system path of an absolute path.
static void fs_path(const char *abs, char *out, size_t len)
{
    snprintf(out, len, STORAGE_ROOT "%s", abs);
}

// A file argument: resolved, and its file system path.
static void file_path(const char *arg, char *abs, size_t abs_len, char *fs, size_t fs_len)
{
    resolve(arg, abs, abs_len);
    fs_path(abs, fs, fs_len);
}

static bool is_dir(const char *fs)
{
    struct stat st;
    return stat(fs, &st) == 0 && S_ISDIR(st.st_mode);
}

// ── Completion: paths, relative to the working directory ────────────
static void complete_entries(const char *prefix, void (*add)(const char *), bool dirs_only)
{
    const char *slash = strrchr(prefix, '/');
    size_t dl = slash ? (size_t)(slash - prefix + 1) : 0;
    const char *base = prefix + dl;
    size_t bl = strlen(base);

    char dir_arg[PATH_LEN], abs[PATH_LEN], fs[PATH_LEN + 16];
    snprintf(dir_arg, sizeof dir_arg, "%.*s", (int)dl, prefix);
    resolve(dl ? dir_arg : ".", abs, sizeof abs);
    fs_path(abs, fs, sizeof fs);
    DIR *d = opendir(fs);
    if (!d)
        return;
    struct dirent *e;
    while ((e = readdir(d))) {
        const char *name = e->d_name;
        if (name[0] == '.' || strncasecmp(name, base, bl) != 0)
            continue;
        char cand[2 * PATH_LEN];
        if (e->d_type == DT_DIR)
            snprintf(cand, sizeof cand, "%.*s%s/", (int)dl, prefix, name);
        else if (!dirs_only)
            snprintf(cand, sizeof cand, "%.*s%s", (int)dl, prefix, name);
        else
            continue;
        add(cand);
    }
    closedir(d);
}

static void complete_path(int argi, const char *prefix, void (*add)(const char *))
{
    if (argi == 1)
        complete_entries(prefix, add, false);
}

static void complete_dir(int argi, const char *prefix, void (*add)(const char *))
{
    if (argi == 1)
        complete_entries(prefix, add, true);
}

// ── Commands ────────────────────────────────────────────────────────
static int cmd_help(int argc, char **argv)
{
    (void)argc; (void)argv;
    const console_cmd_t *const *cmds;
    int n = console_commands(&cmds);
    for (int i = 0; i < n; i++)
        printf("  %-6s %-14s %s\n", cmds[i]->name, cmds[i]->usage, cmds[i]->help);
    printf("  Paths are relative to the working directory; Tab completes,\n");
    printf("  up/down recall, PgUp/PgDn page the output, Return on an\n");
    printf("  empty line redraws the screen.\n");
    return 0;
}

static int cmd_cd(int argc, char **argv)
{
    char abs[PATH_LEN], fs[PATH_LEN + 16];
    resolve(argc > 1 ? argv[1] : "/Patches", abs, sizeof abs);
    fs_path(abs, fs, sizeof fs);
    if (!is_dir(fs)) {
        printf("cd: no folder %s\n", abs);
        return 1;
    }
    snprintf(s_cwd, sizeof s_cwd, "%s", abs);
    show_prompt();
    return 0;
}

static int cmd_pwd(int argc, char **argv)
{
    (void)argc; (void)argv;
    printf("%s\n", s_cwd);
    return 0;
}

static int cmd_ls(int argc, char **argv)
{
    char abs[PATH_LEN], fs[PATH_LEN + 16];
    resolve(argc > 1 ? argv[1] : ".", abs, sizeof abs);
    fs_path(abs, fs, sizeof fs);
    DIR *d = opendir(fs);
    if (!d) { printf("ls: no folder %s\n", abs); return 1; }
    struct dirent *e;
    int n = 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.')
            continue;
        if (e->d_type == DT_DIR) {
            printf("  %s/\n", e->d_name);
        } else {
            char f[3 * PATH_LEN];
            struct stat st;
            snprintf(f, sizeof f, "%s/%s", fs, e->d_name);
            printf("  %-40s %6ld\n", e->d_name, stat(f, &st) == 0 ? (long)st.st_size : -1L);
        }
        n++;
    }
    closedir(d);
    if (n == 0) printf("  (empty)\n");
    return 0;
}

static int cmd_load(int argc, char **argv)
{
    if (argc != 2) { printf("usage: load <file>\n"); return 1; }
    char abs[PATH_LEN], fs[PATH_LEN + 16], err[200];
    file_path(argv[1], abs, sizeof abs, fs, sizeof fs);
    patch_t p;
    if (!patch_file_read(fs, &p, err, sizeof err)) {
        printf("load: %s\n", err);
        return 1;
    }
    if (!voice_alloc_set_patch(&p)) {
        printf("load: the synth did not answer\n");
        return 1;
    }
    snprintf(s_current, sizeof s_current, "%s", abs);
    show_status();
    printf("loaded %s\n", abs);
    return 0;
}

static int cmd_init(int argc, char **argv)
{
    (void)argc; (void)argv;
    patch_t p;
    patch_init(&p);
    if (!voice_alloc_set_patch(&p)) {
        printf("init: the synth did not answer\n");
        return 1;
    }
    snprintf(s_current, sizeof s_current, "init patch");
    show_status();
    printf("loaded the init patch\n");
    return 0;
}

static int cmd_save(int argc, char **argv)
{
    if (argc != 2) { printf("usage: save <file>\n"); return 1; }
    char abs[PATH_LEN], fs[PATH_LEN + 16], err[200];
    file_path(argv[1], abs, sizeof abs, fs, sizeof fs);
    patch_t p;
    if (!voice_alloc_get_patch(&p)) {
        printf("save: the synth did not answer\n");
        return 1;
    }
    if (!patch_file_save(fs, &p, err, sizeof err)) {
        printf("save: %s\n", err);
        return 1;
    }
    snprintf(s_current, sizeof s_current, "%s", abs);
    show_status();
    printf("saved %s\n", abs);
    return 0;
}

static int cmd_rm(int argc, char **argv)
{
    if (argc != 2) { printf("usage: rm <file>\n"); return 1; }
    char abs[PATH_LEN], fs[PATH_LEN + 16];
    file_path(argv[1], abs, sizeof abs, fs, sizeof fs);
    if (is_dir(fs) || remove(fs) != 0) {
        printf("rm: no file %s\n", abs);
        return 1;
    }
    printf("removed %s\n", abs);
    return 0;
}

static int cmd_mkdir(int argc, char **argv)
{
    if (argc != 2) { printf("usage: mkdir <folder>\n"); return 1; }
    char abs[PATH_LEN], fs[PATH_LEN + 16];
    file_path(argv[1], abs, sizeof abs, fs, sizeof fs);
    if (mkdir(fs, 0775) != 0) {
        printf("mkdir: cannot create %s\n", abs);
        return 1;
    }
    return 0;
}

static int cmd_rmdir(int argc, char **argv)
{
    if (argc != 2) { printf("usage: rmdir <folder>\n"); return 1; }
    char abs[PATH_LEN], fs[PATH_LEN + 16];
    file_path(argv[1], abs, sizeof abs, fs, sizeof fs);
    if (strcmp(abs, s_cwd) == 0 || rmdir(fs) != 0) {
        printf("rmdir: cannot remove %s (not empty, or in use)\n", abs);
        return 1;
    }
    return 0;
}

static int cmd_patch(int argc, char **argv)
{
    (void)argc; (void)argv;
    patch_t p;
    if (!voice_alloc_get_patch(&p)) {
        printf("patch: the synth did not answer\n");
        return 1;
    }
    printf("# %s\n", s_current);
    patch_file_write(stdout, &p);
    fflush(stdout);
    return 0;
}

static int cmd_ble(int argc, char **argv)
{
    (void)argc; (void)argv;
    ble_midi_console_status();
    return 0;
}

static const console_cmd_t s_commands[] = {
    { "help",  "",         "list the commands",                        cmd_help,  NULL },
    { "cd",    "[folder]", "change folder (default /Patches)",         cmd_cd,    complete_dir },
    { "pwd",   "",         "print the working folder",                 cmd_pwd,   NULL },
    { "ls",    "[folder]", "list a folder",                            cmd_ls,    complete_dir },
    { "mkdir", "<folder>", "create a folder",                          cmd_mkdir, complete_dir },
    { "rmdir", "<folder>", "remove an empty folder",                   cmd_rmdir, complete_dir },
    { "load",  "<file>",   "load a patch file",                        cmd_load,  complete_path },
    { "init",  "",         "load the init patch",                      cmd_init,  NULL },
    { "save",  "<file>",   "save the active patch to a file",          cmd_save,  complete_path },
    { "rm",    "<file>",   "delete a file",                            cmd_rm,    complete_path },
    { "patch", "",         "print the active patch as a patch file",   cmd_patch, NULL },
    { "ble",   "",         "BLE MIDI status; re-advertise if needed",  cmd_ble,   NULL },
};

void cli_init(void)
{
    for (size_t i = 0; i < sizeof s_commands / sizeof s_commands[0]; i++)
        console_register(&s_commands[i]);
    cli_system_init();
    const char *startup = storage_startup_patch();
    if (startup[0])
        snprintf(s_current, sizeof s_current, "/%s", startup);
    show_prompt();
    show_status();
}
