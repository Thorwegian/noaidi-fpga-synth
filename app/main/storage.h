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

#include "patch.h"

#ifdef __cplusplus
extern "C" {
#endif

#define STORAGE_ROOT    "/storage"

// Mount the storage partition and complete its folder layout. Returns
// false if the partition is missing or does not mount; the synth then
// runs on the default patch with no stored patches.
bool storage_init(void);

// Whether storage_init() mounted the file system.
bool storage_mounted(void);

// Read system.toml's startup_patch into *p. Prints where the loaded patch
// differs from the default patch. False, with *p untouched, if there is
// no file system, no startup_patch, or the patch does not read.
bool storage_load_startup(patch_t *p);

#ifdef __cplusplus
}
#endif
