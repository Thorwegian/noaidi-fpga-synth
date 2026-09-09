#!/bin/bash
# Persistent ESP32-C3 console logger — the always-on witness for
# panics/reboots (WDT panic + frame pointers are enabled, so a crash
# prints a real backtrace; this catches it when no monitor is open).
#
# Run on the dev host:  nohup tools/console_logger.sh &
# Log: /tmp/noaidi_console.log (timestamped lines, appended)
#
# NOTE: holds /dev/ttyACM0. Kill it before idf.py flash/monitor:
#   fuser -k /dev/ttyACM0
PORT=/dev/ttyACM0
LOG=/tmp/noaidi_console.log
if fuser "$PORT" >/dev/null 2>&1; then
    echo "console_logger: $PORT busy (monitor open?) — not starting" >&2
    exit 1
fi
python3 - "$PORT" "$LOG" <<'PY'
import serial, sys, time, datetime
port, log = sys.argv[1], sys.argv[2]
while True:
    try:
        p = serial.Serial(port, 115200, timeout=1)
        with open(log, "a") as f:
            f.write(f"--- logger attached {datetime.datetime.now().isoformat()} ---\n")
            f.flush()
            buf = b""
            while True:
                data = p.read(4096)
                if data:
                    buf += data
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        ts = datetime.datetime.now().strftime("%H:%M:%S")
                        f.write(f"[{ts}] {line.decode('utf-8','replace').rstrip()}\n")
                    f.flush()
    except serial.SerialException:
        time.sleep(2)   # port vanished (reflash?) — retry until it returns
    except OSError:
        time.sleep(2)
PY
