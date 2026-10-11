// storage.c — mount the patch file system and complete its layout
// (see storage.h and docs/storage_format.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "storage.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "esp_vfs_fat.h"
#include "wear_levelling.h"

#include "patch_file.h"
#include "tomlc17.h"

#define TAG "storage"

#define STORAGE_PARTITION   "storage"

// The category folders every Patches/User has (storage_format.md
// "Layout"). Other folders a user adds are categories too.
static const char *const s_categories[] = {
    "Arps", "Basses", "Bells", "Brass", "FX", "Keys",
    "Leads", "Organs", "Pads", "Percussion", "Plucks", "Strings",
};

static wl_handle_t s_wl = WL_INVALID_HANDLE;
static bool        s_mounted;
static char        s_startup[320];   // the startup patch loaded, from the root

// mkdir that treats an existing folder as success.
static bool make_dir(const char *path)
{
    if (mkdir(path, 0775) == 0 || errno == EEXIST)
        return true;
    ESP_LOGE(TAG, "mkdir %s: %s", path, strerror(errno));
    return false;
}

bool storage_init(void)
{
    const esp_vfs_fat_mount_config_t cfg = {
        .format_if_mount_failed = false,   // never erase user patches
        .max_files              = 4,
        .allocation_unit_size   = 512,     // one sector per cluster
    };
    esp_err_t err = esp_vfs_fat_spiflash_mount_rw_wl(STORAGE_ROOT,
                                                     STORAGE_PARTITION,
                                                     &cfg, &s_wl);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "partition \"%s\" does not mount (%s): no stored "
                      "patches; write it with make fw-storage-flash",
                 STORAGE_PARTITION, esp_err_to_name(err));
        return false;
    }
    s_mounted = true;

    bool ok = make_dir(STORAGE_ROOT "/Patches")
           && make_dir(STORAGE_ROOT "/Patches/Factory")
           && make_dir(STORAGE_ROOT "/Patches/User")
           && make_dir(STORAGE_ROOT "/Performances");
    char path[64];
    for (size_t i = 0; ok && i < sizeof s_categories / sizeof s_categories[0]; i++) {
        snprintf(path, sizeof path, STORAGE_ROOT "/Patches/User/%s",
                 s_categories[i]);
        ok = make_dir(path);
    }

    // Finish or undo saves a power loss interrupted, anywhere: the
    // console and banks.toml write outside Patches/User too.
    int repaired = patch_file_recover(STORAGE_ROOT);
    if (repaired)
        ESP_LOGW(TAG, "repaired %d interrupted save%s", repaired, repaired == 1 ? "" : "s");

    uint64_t total = 0, free_bytes = 0;
    if (esp_vfs_fat_info(STORAGE_ROOT, &total, &free_bytes) == ESP_OK)
        ESP_LOGI(TAG, "mounted at %s: %llu of %llu bytes free",
                 STORAGE_ROOT, (unsigned long long)free_bytes,
                 (unsigned long long)total);
    return ok;
}

bool storage_mounted(void)
{
    return s_mounted;
}

// system.toml's startup_patch, a path from the root. False if absent.
static bool startup_patch_path(char *path, size_t len)
{
    toml_result_t r = toml_parse_file_ex(STORAGE_ROOT "/system.toml");
    if (!r.ok) {
        ESP_LOGW(TAG, "system.toml: %s", r.errmsg);
        toml_free(r);
        return false;
    }
    toml_datum_t sp = toml_get(r.toptab, "startup_patch");
    bool ok = sp.type == TOML_STRING;
    if (ok)
        snprintf(path, len, STORAGE_ROOT "/%s", sp.u.s);
    toml_free(r);
    return ok;
}

bool storage_save_patch(const char *category, const char *name, const patch_t *p,
                        char *err, size_t err_len)
{
    if (!s_mounted) {
        snprintf(err, err_len, "no storage");
        return false;
    }
    if (!patch_name_valid(name) || !patch_name_valid(category)) {
        snprintf(err, err_len, "invalid name");
        return false;
    }
    char path[320];
    struct stat st;
    snprintf(path, sizeof path, STORAGE_ROOT "/Patches/User/%s", category);
    if (stat(path, &st) != 0 || !S_ISDIR(st.st_mode)) {
        snprintf(err, err_len, "no category folder User/%s", category);
        return false;
    }
    snprintf(path, sizeof path, STORAGE_ROOT "/Patches/User/%s/%s.toml", category, name);
    return patch_file_save(path, p, err, err_len);
}

bool storage_load_startup(patch_t *p)
{
    char path[320], err[200];
    if (!s_mounted || !startup_patch_path(path, sizeof path))
        return false;
    patch_t loaded;
    int64_t t0 = esp_timer_get_time();
    if (!patch_file_read(path, &loaded, err, sizeof err)) {
        ESP_LOGE(TAG, "%s: %s; keeping the init patch", path, err);
        return false;
    }
    int64_t t1 = esp_timer_get_time();
    ESP_LOGI(TAG, "%s loaded in %lld ms", path, (long long)((t1 - t0) / 1000));
    snprintf(s_startup, sizeof s_startup, "%s", path + strlen(STORAGE_ROOT "/"));
    *p = loaded;
    return true;
}

const char *storage_startup_patch(void)
{
    return s_startup;
}
