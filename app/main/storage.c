// storage.c — mount the preset file system and complete its layout
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

#include "preset_file.h"
#include "tomlc17.h"

#define TAG "storage"

#define STORAGE_PARTITION "storage"

// The category folders every Presets/User has (storage_format.md
// "Layout"). Other folders a user adds are categories too.
static const char *const s_categories[] = {
        "Arps",  "Basses", "Bells", "Brass",      "FX",     "Keys",
        "Leads", "Organs", "Pads",  "Percussion", "Plucks", "Strings",
};

static wl_handle_t s_wl = WL_INVALID_HANDLE;
static bool s_mounted;
static char s_startup[320]; // the startup preset loaded, from the root

// mkdir that treats an existing folder as success.
static bool make_dir(const char *path) {
    if (mkdir(path, 0775) == 0 || errno == EEXIST) {
        return true;
    }
    ESP_LOGE(TAG, "mkdir %s: %s", path, strerror(errno));
    return false;
}

bool storage_init(void) {
    const esp_vfs_fat_mount_config_t cfg = {
            .format_if_mount_failed = false, // never erase user presets
            .max_files              = 4,
            .allocation_unit_size   = 512, // one sector per cluster
    };
    esp_err_t err = esp_vfs_fat_spiflash_mount_rw_wl(
            STORAGE_ROOT, STORAGE_PARTITION, &cfg, &s_wl);
    if (err != ESP_OK) {
        ESP_LOGE(TAG,
                 "partition \"%s\" does not mount (%s): no stored "
                 "presets; write it with make fw-storage-flash",
                 STORAGE_PARTITION, esp_err_to_name(err));
        return false;
    }
    s_mounted = true;

    bool ok = make_dir(STORAGE_ROOT "/Presets")
              && make_dir(STORAGE_ROOT "/Presets/Factory")
              && make_dir(STORAGE_ROOT "/Presets/User")
              && make_dir(STORAGE_ROOT "/Performances");
    char path[64];
    for (size_t i = 0; ok && i < sizeof s_categories / sizeof s_categories[0];
         i++) {
        snprintf(path, sizeof path, STORAGE_ROOT "/Presets/User/%s",
                 s_categories[i]);
        ok = make_dir(path);
    }

    // Finish or undo saves a power loss interrupted, anywhere: the
    // console and banks.toml write outside Presets/User too.
    int repaired = preset_file_recover(STORAGE_ROOT);
    if (repaired) {
        ESP_LOGW(TAG, "repaired %d interrupted save%s", repaired,
                 repaired == 1 ? "" : "s");
    }

    uint64_t total = 0, free_bytes = 0;
    if (esp_vfs_fat_info(STORAGE_ROOT, &total, &free_bytes) == ESP_OK) {
        ESP_LOGI(TAG, "mounted at %s: %llu of %llu bytes free", STORAGE_ROOT,
                 (unsigned long long) free_bytes, (unsigned long long) total);
    }
    return ok;
}

bool storage_mounted(void) {
    return s_mounted;
}

// system.toml's startup_preset, a path from the root. False if absent.
static bool startup_preset_path(char *path, size_t len) {
    toml_result_t r = toml_parse_file_ex(STORAGE_ROOT "/system.toml");
    if (!r.ok) {
        ESP_LOGW(TAG, "system.toml: %s", r.errmsg);
        toml_free(r);
        return false;
    }
    toml_datum_t sp = toml_get(r.toptab, "startup_preset");
    bool ok         = sp.type == TOML_STRING;
    if (ok) {
        snprintf(path, len, STORAGE_ROOT "/%s", sp.u.s);
    }
    toml_free(r);
    return ok;
}

bool storage_load_startup(preset_t *p) {
    char path[320], err[200];
    if (!s_mounted || !startup_preset_path(path, sizeof path)) {
        return false;
    }
    preset_t loaded;
    int64_t t0 = esp_timer_get_time();
    if (!preset_file_read(path, &loaded, err, sizeof err)) {
        ESP_LOGE(TAG, "%s: %s; keeping the init preset", path, err);
        return false;
    }
    int64_t t1 = esp_timer_get_time();
    ESP_LOGI(TAG, "%s loaded in %lld ms", path, (long long) ((t1 - t0) / 1000));
    snprintf(s_startup, sizeof s_startup, "%s",
             path + strlen(STORAGE_ROOT "/"));
    *p = loaded;
    return true;
}

const char *storage_startup_preset(void) {
    return s_startup;
}
