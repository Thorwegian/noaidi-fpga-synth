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
#include "esp_vfs_fat.h"
#include "wear_levelling.h"

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
