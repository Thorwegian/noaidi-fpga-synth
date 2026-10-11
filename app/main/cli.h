// cli.h — the serial console's commands
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The developers' shell on the console (console.h): files (cd, pwd, ls,
// mkdir, rmdir, rm), patches (load, save, init, patch), ble and help in
// cli.cpp; banks in cli_banks.cpp; system commands in cli_system.c. Paths are absolute from the
// storage root ("/Patches/User") or relative to the working folder,
// which the prompt shows, and are taken literally: save writes any
// file, since this shell is for developers, factory patches included.
// Tab completes them.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Register the commands and show the status bar. Call after
// console_init(), storage_init() and voice_alloc_init().
void cli_init(void);

// The system commands (cli_system.c); cli_init() calls it.
void cli_system_init(void);

#ifdef __cplusplus
}
#endif
