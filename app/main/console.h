// console.h — the serial console: a line editor on the USB serial port
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One task owns the USB-Serial/JTAG port. On a VT100 terminal (screen,
// tio, picocom; "make fw-console") the screen is split like an IRC
// client's:
//
//   rows 1 … N−2   output, a scroll region (DECSTBM)
//   row  N−1       status bar
//   row  N         input line: prompt and line editor
//
// A line printed by any task goes in at the bottom of the scroll region,
// which scrolls only that region: the status bar and a half-typed
// command never move, and nothing else is redrawn. Every line is also
// kept in a scrollback of 1000 lines (at most 80 KB of text); PgUp and
// PgDn page through it, and PgDn past the newest line returns to live
// output.
//
// Return on an empty line wakes the console: it asks the terminal for
// its size (a cursor-position report) and redraws the whole screen from
// the scrollback. That is the only full redraw; the size is also asked
// for at boot. The console assumes a VT100 terminal; until one answers,
// it lays out 24 × 80.
//
// stdout and stderr are this console's stream, so printf and ESP_LOG
// both land in the output. The line editor has cursor keys, Home/End,
// Delete, Ctrl-A/E/U/W/C, ↑/↓ history and Tab completion.

#pragma once

#include <stdbool.h>
#include <stddef.h>

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

// Print text through the console (what stdout does).
void console_print(const char *buf, size_t len);

// Set the prompt, e.g. "/Patches $ ".
void console_set_prompt(const char *prompt);

// Set the status bar text.
void console_set_status(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// The registered commands, for help.
int console_commands(const console_cmd_t *const **cmds);

#ifdef __cplusplus
}
#endif
