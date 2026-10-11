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

#include "esp_app_desc.h"

#include "ble_midi.h"
#include "console.h"
#include "patch.h"
#include "patch_file.h"
#include "storage.h"
#include "voice_alloc.h"

#define USER_DIR "Patches/User/"

static char s_current[200] = "init patch";   // the active patch, for the status bar

static void show_status(void)
{
    console_set_status("noaidi %s | %s", esp_app_get_description()->version, s_current);
}

// STORAGE_ROOT/arg, with ".toml" added if the name has none.
static void patch_path(const char *arg, char *out, size_t len)
{
    size_t n = strlen(arg);
    bool has_ext = n > 5 && strcasecmp(arg + n - 5, ".toml") == 0;
    snprintf(out, len, STORAGE_ROOT "/%s%s", arg, has_ext ? "" : ".toml");
}

// The path without a leading "/" and without ".toml", for display.
static void display_name(const char *arg, char *out, size_t len)
{
    while (*arg == '/') arg++;
    size_t n = strlen(arg);
    if (n > 5 && strcasecmp(arg + n - 5, ".toml") == 0) n -= 5;
    snprintf(out, len, "%.*s", (int)n, arg);
}

// ── Completion: paths under the storage root ────────────────────────
static void complete_path(int argi, const char *prefix, void (*add)(const char *))
{
    if (argi != 1)
        return;
    const char *slash = strrchr(prefix, '/');
    size_t dl = slash ? (size_t)(slash - prefix + 1) : 0;
    const char *base = prefix + dl;
    size_t bl = strlen(base);

    char dir[200];
    snprintf(dir, sizeof dir, STORAGE_ROOT "/%.*s", (int)dl, prefix);
    DIR *d = opendir(dir);
    if (!d)
        return;
    struct dirent *e;
    while ((e = readdir(d))) {
        const char *name = e->d_name;
        if (name[0] == '.' || strncasecmp(name, base, bl) != 0)
            continue;
        size_t nl = strlen(name);
        char cand[320];
        if (e->d_type == DT_DIR) {
            snprintf(cand, sizeof cand, "%.*s%s/", (int)dl, prefix, name);
        } else if (nl > 5 && strcasecmp(name + nl - 5, ".toml") == 0) {
            snprintf(cand, sizeof cand, "%.*s%.*s", (int)dl, prefix, (int)(nl - 5), name);
        } else {
            continue;                   // .new files, anything else
        }
        add(cand);
    }
    closedir(d);
}

// ── Commands ────────────────────────────────────────────────────────
static int cmd_help(int argc, char **argv)
{
    (void)argc; (void)argv;
    const console_cmd_t *const *cmds;
    int n = console_commands(&cmds);
    for (int i = 0; i < n; i++)
        printf("  %-6s %-16s %s\n", cmds[i]->name, cmds[i]->usage, cmds[i]->help);
    printf("  Tab completes, up/down recall, Ctrl-L redraws.\n");
    return 0;
}

static int cmd_load(int argc, char **argv)
{
    if (argc != 2) { printf("usage: load <path>\n"); return 1; }
    char path[256], err[200], name[128];
    patch_path(argv[1], path, sizeof path);
    patch_t p;
    if (!patch_file_read(path, &p, err, sizeof err)) {
        printf("load: %s\n", err);
        return 1;
    }
    if (!voice_alloc_set_patch(&p)) {
        printf("load: the synth did not answer\n");
        return 1;
    }
    display_name(argv[1], name, sizeof name);
    snprintf(s_current, sizeof s_current, "%s", name);
    show_status();
    printf("loaded %s\n", name);
    return 0;
}

static int cmd_save(int argc, char **argv)
{
    if (argc != 2) { printf("usage: save " USER_DIR "<category>/<name>\n"); return 1; }
    // accept "Patches/User/Pads/Name" or "Pads/Name"
    char rel[128];
    display_name(argv[1], rel, sizeof rel);
    const char *r = rel;
    if (strncasecmp(r, USER_DIR, strlen(USER_DIR)) == 0)
        r += strlen(USER_DIR);
    const char *slash = strchr(r, '/');
    if (!slash || strchr(slash + 1, '/')) {
        printf("save: give " USER_DIR "<category>/<name>\n");
        return 1;
    }
    char category[64], name[96], err[200];
    snprintf(category, sizeof category, "%.*s", (int)(slash - r), r);
    snprintf(name, sizeof name, "%s", slash + 1);
    patch_t p;
    if (!voice_alloc_get_patch(&p)) {
        printf("save: the synth did not answer\n");
        return 1;
    }
    if (!storage_save_patch(category, name, &p, err, sizeof err)) {
        printf("save: %s\n", err);
        return 1;
    }
    snprintf(s_current, sizeof s_current, USER_DIR "%s/%s", category, name);
    show_status();
    printf("saved %s\n", s_current);
    return 0;
}

static int cmd_ls(int argc, char **argv)
{
    const char *rel = argc > 1 ? argv[1] : "Patches";
    char dir[200];
    snprintf(dir, sizeof dir, STORAGE_ROOT "/%s", rel);
    DIR *d = opendir(dir);
    if (!d) { printf("ls: no folder %s\n", rel); return 1; }
    struct dirent *e;
    int n = 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.')
            continue;
        size_t nl = strlen(e->d_name);
        if (e->d_type == DT_DIR)
            printf("  %s/\n", e->d_name);
        else if (nl > 5 && strcasecmp(e->d_name + nl - 5, ".toml") == 0)
            printf("  %.*s\n", (int)(nl - 5), e->d_name);
        else
            printf("  %s\n", e->d_name);
        n++;
    }
    closedir(d);
    if (n == 0) printf("  (empty)\n");
    return 0;
}

static int cmd_rm(int argc, char **argv)
{
    if (argc != 2) { printf("usage: rm " USER_DIR "<category>/<name>\n"); return 1; }
    char rel[128], path[256];
    display_name(argv[1], rel, sizeof rel);
    if (strncasecmp(rel, USER_DIR, strlen(USER_DIR)) != 0) {
        printf("rm: only patches under " USER_DIR "\n");
        return 1;
    }
    patch_path(rel, path, sizeof path);
    if (remove(path) != 0) {
        printf("rm: no patch %s\n", rel);
        return 1;
    }
    printf("removed %s\n", rel);
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
    { "help",  "",        "list the commands",                         cmd_help,  NULL },
    { "load",  "<path>",  "load a patch, e.g. Patches/Factory/Pads/Supersaw", cmd_load, complete_path },
    { "save",  "<path>",  "save the active patch under " USER_DIR "<category>/", cmd_save, complete_path },
    { "ls",    "[folder]", "list a folder (default Patches)",           cmd_ls,    complete_path },
    { "rm",    "<path>",  "delete a patch under " USER_DIR,             cmd_rm,    complete_path },
    { "patch", "",        "print the active patch as a patch file",     cmd_patch, NULL },
    { "ble",   "",        "BLE MIDI status; re-advertise if needed",    cmd_ble,   NULL },
};

void cli_init(void)
{
    for (size_t i = 0; i < sizeof s_commands / sizeof s_commands[0]; i++)
        console_register(&s_commands[i]);
    if (storage_startup_patch()[0]) {
        char name[128];
        display_name(storage_startup_patch(), name, sizeof name);
        snprintf(s_current, sizeof s_current, "%s", name);
    }
    show_status();
}
