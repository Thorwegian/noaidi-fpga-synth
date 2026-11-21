#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""console_port.py -- find the firmware's console port.

The console is the CH343 bridge in the module's socket marked COM, and its
device name is not stable: with the USB device cabled as well the CH343 is
/dev/ttyACM1, and without it /dev/ttyACM0. The USB serial number is stable, so
the port is looked up by that first and by the usual names only as a fallback.
"""

import glob

# The CH343 on the module's COM socket; the serial number is the chip's own.
CH343_BY_ID = "/dev/serial/by-id/usb-1a86_USB_Single_Serial_*-if00"


def find_console() -> str:
    """The console's device path, or the first ACM/usbmodem port as a fallback."""
    for path in sorted(glob.glob(CH343_BY_ID)):
        return path
    for pattern in ("/dev/ttyACM*", "/dev/cu.usbmodem*"):
        for path in sorted(glob.glob(pattern)):
            return path
    return "/dev/ttyACM0"
