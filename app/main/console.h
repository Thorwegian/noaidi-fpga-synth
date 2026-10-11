// console.h — the serial console: a line editor on the USB serial port
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One task owns the USB-Serial/JTAG port. On a VT100 terminal (screen,
// tio, picocom; "make fw-console") the screen is split like an IRC
// client's:
//
//   rows 1 … N−2   log region: everything printed scrolls here
//   row  N−1       status bar
//   row  N         input line: prompt and line editor
//
// The log region is a scroll region (DECSTBM), so a line printed by
// any task scrolls only that region: the status bar and a half-typed
// command never move. The terminal size is asked for at start, on
// Ctrl-L and on the first key after a quiet start; a terminal that does
// not answer gets plain lines with the prompt reprinted below them.
//
// stdout and stderr are this console's stream, so printf and ESP_LOG
// both land in the log region. The line editor has cursor keys,
// Home/End, Delete, Ctrl-A/E/U/W/C/L, ↑/↓ history and Tab completion.

#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *name;
    const char *usage;      // arguments, for help: "<path>"
    const char *help;       // one line
    int  (*run)(int argc, char **argv);
    // Offer completions for argument argi (1 = first) starting with
    // prefix, by calling add() for each. NULL: no completion.
    void (*complete)(int argi, const char *prefix, void (*add)(const char *candidate));
} console_cmd_t;

// Take over the USB serial port and stdout/stderr, and start the
// console task. Call early in app_main, before other tasks print.
void console_init(void);

// Add a command. The table entry must outlive the console.
void console_register(const console_cmd_t *cmd);

// Set the status bar text.
void console_set_status(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// The registered commands, for help.
int console_commands(const console_cmd_t *const **cmds);

#ifdef __cplusplus
}
#endif
