#!/bin/bash
# Persistent ESP32-C3 console logger — the always-on witness for
# panics/reboots (WDT panic + frame pointers are enabled, so a crash
# prints a real backtrace; this catches it when no monitor is open).
#
# Run on the dev host:  nohup tools/console_logger.sh &
# Follow live:          tail -f /tmp/noaidi_console.log
#
# POLITE MODE (2026-09-10, after the first version's 2 s reconnect
# loop raced esptool and Thor had to unplug the board): the logger
# only attaches when the port is FREE, backs off the moment anything
# else wants it, and quietly re-attaches after flashes/monitors end.
# The ESP console port re-enumerates across replugs — discovered by
# vendor, never hardcoded.
LOG=/tmp/noaidi_console.log

find_port() {
    local p
    for p in /dev/ttyACM*; do
        [ -e "$p" ] || continue
        if udevadm info -q property -n "$p" 2>/dev/null \
                | grep -q 'ID_VENDOR=Espressif'; then
            echo "$p"; return 0
        fi
    done
    return 1
}

while true; do
    PORT=$(find_port) || { sleep 5; continue; }
    if fuser "$PORT" >/dev/null 2>&1; then
        sleep 5                     # someone else (esptool/monitor) has it
        continue
    fi
    python3 - "$PORT" "$LOG" <<'PY'
import serial, sys, time, datetime
port, log = sys.argv[1], sys.argv[2]
try:
    p = serial.Serial(port, 115200, timeout=1)
except Exception:
    raise SystemExit(0)             # lost the race - outer loop backs off
with open(log, "a") as f:
    f.write(f"--- logger attached {port} {datetime.datetime.now().isoformat()} ---\n")
    f.flush()
    buf = b""
    try:
        while True:
            data = p.read(4096)
            if data:
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    ts = datetime.datetime.now().strftime("%H:%M:%S")
                    f.write(f"[{ts}] {line.decode('utf-8','replace').rstrip()}\n")
                f.flush()
    except (serial.SerialException, OSError):
        f.write(f"--- port lost {datetime.datetime.now().isoformat()} (flash/replug?) ---\n")
PY
    sleep 5                         # port vanished or was claimed - wait
done
