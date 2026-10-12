// console.c — the serial console (see console.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "console.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "driver/usb_serial_jtag.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define LINE_MAX_BYTES   160 // the input line
#define OUT_LINE_BYTES   256 // one printed line; longer ones split
#define HISTORY_LEN      16
#define MAX_COMMANDS     24
#define MAX_ARGS         8
#define MAX_CANDIDATES   32
#define SIZE_QUERY_US    300000 // no answer by then: keep the size we have
#define SCROLLBACK_LINES 1000
#define SCROLLBACK_BYTES (80 * 1024) // text cap: ~80 bytes a line on average

// ── Terminal state ──────────────────────────────────────────────────
static SemaphoreHandle_t s_lock;     // everything written to the terminal
static int s_rows = 24, s_cols = 80; // until the terminal answers
static int64_t s_query_sent; // when the size query went out, 0 = none pending
static char s_status[128];
static char s_prompt[96] = "$ ";

// Raw output to the USB serial port. Dropped when no host is attached,
// and without waiting once a write has timed out (a host is attached but
// nothing reads the port, e.g. during boot), so a printing task never
// stalls on an absent terminal. The first write that fits again ends
// that.
static bool s_stalled;

static void term_write(const char *buf, size_t len) {
    if (!len || !usb_serial_jtag_is_connected()) {
        return;
    }
    size_t n = (size_t) usb_serial_jtag_write_bytes(
            buf, len, s_stalled ? 0 : pdMS_TO_TICKS(20));
    s_stalled = n < len;
}

static void term_puts(const char *s) {
    term_write(s, strlen(s));
}

static void term_printf(const char *fmt, ...) {
    char buf[64];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    term_write(buf, n < (int) sizeof buf ? (size_t) n : sizeof buf - 1);
}

// Display columns of the first n bytes of UTF-8 text.
static int columns(const char *s, size_t n) {
    int c = 0;
    for (size_t i = 0; i < n; i++) {
        if (((unsigned char) s[i] & 0xC0) != 0x80) {
            c++;
        }
    }
    return c;
}

// ── The input line ──────────────────────────────────────────────────
static char s_line[LINE_MAX_BYTES];
static size_t s_len, s_pos; // bytes; s_pos is the cursor

static void draw_input(void) {
    term_printf("\x1b[%d;1H\x1b[2K", s_rows);
    term_puts(s_prompt);
    term_write(s_line, s_len);
    int col = 1 + columns(s_prompt, strlen(s_prompt)) + columns(s_line, s_pos);
    term_printf("\x1b[%d;%dH", s_rows, col);
}

// ── Scrollback ──────────────────────────────────────────────────────
// Every printed line, newest last: up to SCROLLBACK_LINES lines and
// SCROLLBACK_BYTES of text, the oldest dropped first. s_back is how far
// the view is scrolled back from the newest line; 0 is live output.
static char *s_sb[SCROLLBACK_LINES]; // a ring from s_sb_first
static int s_sb_first, s_sb_count;
static size_t s_sb_bytes;
static int s_back;

static const char *sb_line(int i) // 0 = the oldest held
{
    return s_sb[(s_sb_first + i) % SCROLLBACK_LINES];
}

static void sb_add(const char *text, size_t len) {
    while (s_sb_count
           && (s_sb_count == SCROLLBACK_LINES
               || s_sb_bytes + len + 1 > SCROLLBACK_BYTES)) {
        s_sb_bytes -= strlen(s_sb[s_sb_first]) + 1;
        free(s_sb[s_sb_first]);
        s_sb_first = (s_sb_first + 1) % SCROLLBACK_LINES;
        s_sb_count--;
    }
    char *copy = malloc(len + 1);
    if (!copy) {
        return;
    }
    memcpy(copy, text, len);
    copy[len]                                          = '\0';
    s_sb[(s_sb_first + s_sb_count) % SCROLLBACK_LINES] = copy;
    s_sb_count++;
    s_sb_bytes += len + 1;
    if (s_back) { // scrolled back: the view stays put
        s_back++;
        if (s_back > s_sb_count) {
            s_back = s_sb_count;
        }
    }
}

// Write text cut to the screen width. Escape sequences take no columns.
static void write_clipped(const char *text) {
    const char *p = text;
    int col       = 0;
    while (*p && col < s_cols) {
        const char *q = p;
        if (*q == 0x1B) { // ESC [ … final, passed through
            q++;
            if (*q == '[') {
                q++;
                while (*q && (*q < 0x40 || *q > 0x7E)) {
                    q++;
                }
            }
            if (*q) {
                q++;
            }
        } else {
            q++;
            while (((unsigned char) *q & 0xC0) == 0x80) {
                q++;
            }
            col++;
        }
        p = q;
    }
    term_write(text, (size_t) (p - text));
    term_puts("\x1b[0m");
}

// ── The screen ──────────────────────────────────────────────────────
static int page_rows(void) {
    return s_rows - 2;
}

static void draw_status(void) {
    char row[200];
    int n = s_back ? snprintf(row, sizeof row,
                              " %d lines back, PgDn for live | %s", s_back,
                              s_status)
                   : snprintf(row, sizeof row, " %s", s_status);
    if (n < 0) {
        n = 0;
    }
    if (n > (int) sizeof row - 1) {
        n = (int) sizeof row - 1;
    }
    while (n < s_cols && n < (int) sizeof row - 1) { // pad: reverse video
        row[n++] = ' ';                              // fills the whole row
    }
    if (n > s_cols) {
        n = s_cols;
    }
    term_printf("\x1b"
                "7\x1b[%d;1H\x1b[7m",
                s_rows - 1);
    term_write(row, (size_t) n);
    term_puts("\x1b[0m\x1b"
              "8");
}

// Paint the output rows from the scrollback, ending s_back lines before
// the newest line. Lines are cut to the screen width, so each takes one
// row.
static void draw_output(void) {
    int rows = page_rows();
    int end  = s_sb_count - s_back; // one past the last line shown
    for (int r = 0; r < rows; r++) {
        int i = end - rows + r;
        term_printf("\x1b[%d;1H\x1b[2K", r + 1);
        if (i >= 0 && i < s_sb_count) {
            write_clipped(sb_line(i));
        }
    }
}

// Draw the whole screen: the output rows in a scroll region (DECSTBM),
// the status bar and the input line below. Only on waking the console.
static void draw_screen(void) {
    term_printf("\x1b[r\x1b[2J\x1b[1;%dr", page_rows());
    draw_output();
    draw_status();
    draw_input();
}

// One line of output: into the scrollback, and onto the screen. Live, it
// goes in at the bottom of the scroll region, whose newline scrolls only
// that region: nothing else is redrawn. Scrolled back, only the status
// bar's count changes.
static void emit_line(const char *text, size_t len) {
    sb_add(text, len);
    if (s_back == 0) {
        term_printf("\x1b"
                    "7\x1b[%d;1H\n",
                    page_rows());
        term_write(text, len);
        term_puts("\x1b"
                  "8");
    } else {
        draw_status();
    }
}

// ── stdout and stderr ───────────────────────────────────────────────
// A picolibc stream with one put() per character. Characters gather into
// a line; a newline (or a full buffer) emits it.
static char s_out[OUT_LINE_BYTES];
static size_t s_out_len;

void console_print(const char *buf, size_t len) {
    xSemaphoreTakeRecursive(s_lock, portMAX_DELAY);
    for (size_t i = 0; i < len; i++) {
        char c = buf[i];
        if (c == '\n' || s_out_len == sizeof s_out) {
            emit_line(s_out, s_out_len);
            s_out_len = 0;
        }
        if (c != '\n' && c != '\r') {
            s_out[s_out_len++] = c;
        }
    }
    xSemaphoreGiveRecursive(s_lock);
}

#ifdef FDEV_SETUP_STREAM // picolibc
static int console_put(char c, FILE *f) {
    (void) f;
    console_print(&c, 1);
    return (unsigned char) c;
}

static FILE s_stream =
        FDEV_SETUP_STREAM(console_put, NULL, NULL, _FDEV_SETUP_WRITE);
#endif

// ── Commands ────────────────────────────────────────────────────────
static const console_cmd_t *s_cmds[MAX_COMMANDS];
static int s_ncmds;

void console_register(const console_cmd_t *cmd) {
    if (s_ncmds < MAX_COMMANDS) {
        s_cmds[s_ncmds++] = cmd;
    }
}

int console_commands(const console_cmd_t *const **cmds) {
    *cmds = s_cmds;
    return s_ncmds;
}

void console_set_prompt(const char *prompt) {
    xSemaphoreTakeRecursive(s_lock, portMAX_DELAY);
    snprintf(s_prompt, sizeof s_prompt, "%s", prompt);
    draw_input();
    xSemaphoreGiveRecursive(s_lock);
}

void console_set_status(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    xSemaphoreTakeRecursive(s_lock, portMAX_DELAY);
    vsnprintf(s_status, sizeof s_status, fmt, ap);
    draw_status();
    xSemaphoreGiveRecursive(s_lock);
    va_end(ap);
}

// Split a line into arguments on spaces; "double quotes" keep spaces.
// Modifies line. Returns argc.
static int split_args(char *line, char **argv, int max) {
    int argc = 0;
    char *p  = line;
    while (*p && argc < max) {
        while (*p == ' ') {
            p++;
        }
        if (!*p) {
            break;
        }
        char *out    = p;
        argv[argc++] = out;
        bool quoted  = false;
        while (*p && (quoted || *p != ' ')) {
            if (*p == '"') {
                quoted = !quoted;
            } else {
                *out++ = *p;
            }
            p++;
        }
        if (*p) {
            p++;
        }
        *out = '\0';
    }
    return argc;
}

static void run_line(char *line) {
    char *argv[MAX_ARGS];
    int argc = split_args(line, argv, MAX_ARGS);
    if (argc == 0) {
        return;
    }
    for (int i = 0; i < s_ncmds; i++) {
        if (strcmp(s_cmds[i]->name, argv[0]) == 0) {
            s_cmds[i]->run(argc, argv);
            return;
        }
    }
    printf("unknown command \"%s\"; try help\n", argv[0]);
}

// ── History ─────────────────────────────────────────────────────────
static char s_hist[HISTORY_LEN][LINE_MAX_BYTES];
static int s_hist_n;  // entries stored
static int s_hist_at; // browsing: 0 = the line being typed

static void history_add(const char *line) {
    if (!*line || (s_hist_n && strcmp(s_hist[0], line) == 0)) {
        return;
    }
    memmove(s_hist[1], s_hist[0], sizeof s_hist[0] * (HISTORY_LEN - 1));
    snprintf(s_hist[0], sizeof s_hist[0], "%s", line);
    if (s_hist_n < HISTORY_LEN) {
        s_hist_n++;
    }
}

static void history_show(int at) {
    s_hist_at = at;
    snprintf(s_line, sizeof s_line, "%s", at ? s_hist[at - 1] : "");
    s_len = s_pos = strlen(s_line);
}

// ── Completion ──────────────────────────────────────────────────────
static char s_cand[MAX_CANDIDATES][LINE_MAX_BYTES];
static int s_ncand;

static void add_candidate(const char *c) {
    if (s_ncand < MAX_CANDIDATES) {
        snprintf(s_cand[s_ncand++], sizeof s_cand[0], "%s", c);
    }
}

// Replace bytes [from, s_pos) of the line with text.
static void replace_before_cursor(size_t from, const char *text) {
    size_t tl = strlen(text), tail = s_len - s_pos;
    if (from + tl + tail >= sizeof s_line) {
        return;
    }
    memmove(s_line + from + tl, s_line + s_pos, tail);
    memcpy(s_line + from, text, tl);
    s_len = from + tl + tail;
    s_pos = from + tl;
}

static void complete(void) {
    // the argument under the cursor: its start, its index, its text
    size_t start = 0;
    int argi     = 0;
    bool quoted = false, in_arg = false;
    for (size_t i = 0; i < s_pos; i++) {
        char c = s_line[i];
        if (c == '"') {
            quoted = !quoted;
        }
        if (c == ' ' && !quoted) {
            if (in_arg) {
                argi++;
            }
            in_arg = false;
            continue;
        }
        if (!in_arg) {
            in_arg = true;
            start  = i;
        }
    }
    if (!in_arg) {
        start = s_pos;
    }
    char prefix[LINE_MAX_BYTES];
    size_t pl = 0;
    for (size_t i = start; i < s_pos && pl < sizeof prefix - 1; i++) {
        if (s_line[i] != '"') {
            prefix[pl++] = s_line[i];
        }
    }
    prefix[pl] = '\0';

    s_ncand = 0;
    if (argi == 0) {
        for (int i = 0; i < s_ncmds; i++) {
            if (strncmp(s_cmds[i]->name, prefix, pl) == 0) {
                add_candidate(s_cmds[i]->name);
            }
        }
    } else {
        char first[32] = "";
        sscanf(s_line, "%31s", first);
        for (int i = 0; i < s_ncmds; i++) {
            if (strcmp(s_cmds[i]->name, first) == 0 && s_cmds[i]->complete) {
                s_cmds[i]->complete(argi, prefix, add_candidate);
            }
        }
    }
    if (s_ncand == 0) {
        return;
    }

    // the longest common prefix of the candidates
    size_t common = strlen(s_cand[0]);
    for (int i = 1; i < s_ncand; i++) {
        size_t j = 0;
        while (j < common && s_cand[i][j] == s_cand[0][j]) {
            j++;
        }
        common = j;
    }
    char text[LINE_MAX_BYTES];
    snprintf(text, sizeof text, "%.*s", (int) common, s_cand[0]);
    bool spaces = strchr(text, ' ') != NULL
                  || (start < s_len && s_line[start] == '"');
    bool done = s_ncand == 1 && common > 0 && text[common - 1] != '/';
    char raw[LINE_MAX_BYTES + 4];
    snprintf(raw, sizeof raw, "%s%s%s%s", spaces ? "\"" : "", text,
             (spaces && done) ? "\"" : "", done ? " " : "");

    if (common > pl || s_ncand == 1) {
        replace_before_cursor(start, raw);
    } else {
        // nothing more in common: list them above the prompt
        char list[OUT_LINE_BYTES];
        size_t n = 0;
        for (int i = 0; i < s_ncand && n < sizeof list - 2; i++) {
            n += (size_t) snprintf(list + n, sizeof list - n, "%s  ",
                                   s_cand[i]);
        }
        emit_line(list, n < sizeof list ? n : sizeof list - 1);
    }
}

// ── Keys ────────────────────────────────────────────────────────────
static void query_size(void) {
    // to the far corner, ask where the cursor is, come back
    term_puts("\x1b"
              "7\x1b[999;999H\x1b[6n\x1b"
              "8");
    s_query_sent = esp_timer_get_time();
}

static void insert(const char *bytes, size_t n) {
    if (s_len + n >= sizeof s_line) {
        return;
    }
    memmove(s_line + s_pos + n, s_line + s_pos, s_len - s_pos);
    memcpy(s_line + s_pos, bytes, n);
    s_len += n;
    s_pos += n;
}

static void cursor_left(void) {
    while (s_pos > 0 && (((unsigned char) s_line[--s_pos]) & 0xC0) == 0x80) {
    }
}

static void cursor_right(void) {
    if (s_pos < s_len) {
        while (++s_pos < s_len
               && (((unsigned char) s_line[s_pos]) & 0xC0) == 0x80) {
        }
    }
}

static void delete_range(size_t from, size_t to) {
    memmove(s_line + from, s_line + to, s_len - to);
    s_len -= to - from;
    s_pos = from;
}

static void enter(void) {
    s_line[s_len] = '\0';
    char line[LINE_MAX_BYTES];
    snprintf(line, sizeof line, "%s", s_line);
    s_hist_at = 0;
    s_len = s_pos = 0;
    if (!line[0]) {   // an empty line wakes the console:
        query_size(); // measure, then redraw it all
        return;
    }
    history_add(line);
    // echo the command into the log, then run it
    char echo[LINE_MAX_BYTES + sizeof s_prompt];
    int n = snprintf(echo, sizeof echo, "%s%s", s_prompt, line);
    emit_line(echo, n < (int) sizeof echo ? (size_t) n : sizeof echo - 1);
    draw_input();
    xSemaphoreGiveRecursive(s_lock); // commands print
    run_line(line);
    xSemaphoreTakeRecursive(s_lock, portMAX_DELAY);
}

// A CSI sequence: ESC [ params final.
static void csi(const char *params, char final) {
    int a = 0, b = 0;
    sscanf(params, "%d;%d", &a, &b);
    switch (final) {
    case 'A':
        if (s_hist_at < s_hist_n) {
            history_show(s_hist_at + 1);
        }
        break;
    case 'B':
        if (s_hist_at > 0) {
            history_show(s_hist_at - 1);
        }
        break;
    case 'C':
        cursor_right();
        break;
    case 'D':
        cursor_left();
        break;
    case 'H':
        s_pos = 0;
        break;
    case 'F':
        s_pos = s_len;
        break;
    case '~':
        if (a == 1 || a == 7) {
            s_pos = 0;
        } else if (a == 4 || a == 8) {
            s_pos = s_len;
        } else if (a == 5 || a == 6) { // PgUp / PgDn: a page
            int max_back =
                    s_sb_count > page_rows() ? s_sb_count - page_rows() : 0;
            s_back += (a == 5) ? page_rows() : -page_rows();
            if (s_back > max_back) {
                s_back = max_back;
            }
            if (s_back < 0) {
                s_back = 0; // at the bottom: live again
            }
            draw_output();
            draw_status();
        } else if (a == 3 && s_pos < s_len) {
            size_t p = s_pos;
            cursor_right();
            delete_range(p, s_pos);
        }
        break;
    case 'R': // the size answer: wake up
        if (s_query_sent && a >= 4 && b >= 20) {
            s_rows       = a;
            s_cols       = b;
            s_query_sent = 0;
            s_back       = 0;
            draw_screen();
        }
        break;
    default:
        break;
    }
}

static void console_task(void *arg) {
    (void) arg;
    enum { NORMAL, ESC, CSI, SS3 } state = NORMAL;
    char params[16];
    size_t np = 0;

    xSemaphoreTakeRecursive(s_lock, portMAX_DELAY);
    query_size();
    xSemaphoreGiveRecursive(s_lock);

    while (1) {
        uint8_t c;
        int got = usb_serial_jtag_read_bytes(&c, 1, pdMS_TO_TICKS(100));
        xSemaphoreTakeRecursive(s_lock, portMAX_DELAY);
        if (s_query_sent
            && esp_timer_get_time() - s_query_sent > SIZE_QUERY_US) {
            s_query_sent = 0; // no answer (nothing attached yet):
            draw_screen();    // lay out at the size we have
        }
        if (got <= 0) {
            xSemaphoreGiveRecursive(s_lock);
            continue;
        }
        switch (state) {
        case ESC:
            state = (c == '[') ? CSI : (c == 'O') ? SS3 : NORMAL;
            np    = 0;
            break;
        case CSI:
            if ((c >= '0' && c <= '9') || c == ';') {
                if (np < sizeof params - 1) {
                    params[np++] = (char) c;
                }
            } else {
                params[np] = '\0';
                csi(params, (char) c);
                state = NORMAL;
            }
            break;
        case SS3: // ESC O A … (application keys)
            params[0] = '\0';
            csi(params, (char) c);
            state = NORMAL;
            break;
        case NORMAL:
            switch (c) {
            case 0x1B:
                state = ESC;
                break;
            case '\r':
            case '\n':
                enter();
                break;
            case 0x7F:
            case 0x08: // backspace
                if (s_pos > 0) {
                    size_t p = s_pos;
                    cursor_left();
                    delete_range(s_pos, p);
                }
                break;
            case '\t':
                complete();
                break;
            case 0x01:
                s_pos = 0;
                break; // Ctrl-A
            case 0x05:
                s_pos = s_len;
                break; // Ctrl-E
            case 0x03:
                s_len = s_pos = 0;
                s_hist_at     = 0;
                break; // Ctrl-C
            case 0x15:
                delete_range(0, s_pos);
                break;   // Ctrl-U
            case 0x17: { // Ctrl-W
                size_t p = s_pos;
                while (s_pos > 0 && s_line[s_pos - 1] == ' ') {
                    s_pos--;
                }
                while (s_pos > 0 && s_line[s_pos - 1] != ' ') {
                    s_pos--;
                }
                delete_range(s_pos, p);
            } break;
            default:
                if (c >= 0x20) {
                    insert((const char *) &c, 1);
                }
                break;
            }
            break;
        }
        if (state == NORMAL) {
            draw_input();
        }
        xSemaphoreGiveRecursive(s_lock);
    }
}

void console_init(void) {
    s_lock = xSemaphoreCreateRecursiveMutex();
    // The driver insists on buffers strictly larger than 64 bytes.
    usb_serial_jtag_driver_config_t cfg = {
            .rx_buffer_size = 256,
            .tx_buffer_size = 1024,
    };
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&cfg));
#ifdef FDEV_SETUP_STREAM
    fflush(stdout);
    stdout = &s_stream;
    stderr = &s_stream;
#endif
    xTaskCreate(console_task, "console", 6144, NULL, 2,
                NULL); // commands run here
}
