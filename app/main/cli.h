// cli.h — the serial console's commands
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Patch commands (load, save, ls, rm, patch), ble, and help, on the
// console (console.h). Paths are relative to the storage root and may
// leave out ".toml"; Tab completes them.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Register the commands and show the status bar. Call after
// console_init(), storage_init() and voice_alloc_init().
void cli_init(void);

#ifdef __cplusplus
}
#endif
