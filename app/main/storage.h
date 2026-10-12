// storage.h — the patch file system (docs/storage_format.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The "storage" partition holds FAT on the wear-levelling layer,
// mounted at STORAGE_ROOT. storage_init() mounts it and creates the
// folders the layout requires (the User category folders among
// them). It never formats: a partition that does not mount is
// reported and left alone, so a fault cannot erase user patches. The
// partition image is written by "make fw-storage-flash".

#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "patch.h"

#ifdef __cplusplus
extern "C" {
#endif

#define STORAGE_ROOT "/storage"

// Mount the storage partition and complete its folder layout. Returns
// false if the partition is missing or does not mount; the synth then
// runs on the init patch with no stored patches.
bool storage_init(void);

// Whether storage_init() mounted the file system.
bool storage_mounted(void);

// Read system.toml's startup_patch into *p. False, with *p untouched, if
// there is no file system, no startup_patch, or the patch does not read.
bool storage_load_startup(patch_t *p);

// The startup patch's path from the storage root, as storage_load_startup
// loaded it, or "" if it loaded none.
const char *storage_startup_patch(void);

// Save *p as Patches/User/<category>/<name>.toml, replacing a patch of
// that name (FAT compares names case-insensitively). The category folder
// must exist and the name must be valid (patch_name_valid). False, with
// the reason in err, otherwise.
bool storage_save_patch(const char *category, const char *name,
                        const patch_t *p, char *err, size_t err_len);

#ifdef __cplusplus
}
#endif
