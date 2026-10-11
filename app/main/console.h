// console.h — the serial console: a line editor on the USB serial port
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One task owns the USB-Serial/JTAG port. On a VT100 terminal (screen,
// tio, picocom; "make fw-console") the screen is split like an IRC
// client's:
//
//   rows 1 … N−2   output: everything printed scrolls up here
//   row  N−1       status bar
//   row  N         input line: prompt and line editor
//
// A line printed by any task goes over the status bar and scrolls the
// whole screen up; the status bar and input line, half-typed command
// included, are drawn again below it. Scrolling the whole screen (no
// scroll region) keeps the output in the terminal's own scrollback.
// The terminal size is asked for at start, on Ctrl-L, and on any key
// while the layout is not up (so Return wakes it after attaching); a
// terminal that does not answer gets plain lines with the prompt
// reprinted below them.
//
// stdout and stderr are this console's stream, so printf and ESP_LOG
// both land in the output above the status bar. The line editor has cursor keys,
// Home/End, Delete, Ctrl-A/E/U/W/C/L, ↑/↓ history and Tab completion.

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
