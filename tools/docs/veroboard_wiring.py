#!/usr/bin/python3
# veroboard_wiring.py — draw the prototype veroboard's wiring as an SVG
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# Writes the picture in README.md's Wiring section:
#
#     tools/docs/veroboard_wiring.py docs/images/veroboard-wiring.svg
#
# The parts are placed as on the board, seen from the component side. The
# wires run in lanes of their own, not along their routes on the board.
#
# Where each connection is taken from:
#   - the SPI link, the MIDI inputs and the Tang Nano's pins: README.md's
#     wiring tables and rtl/constraints.cst;
#   - the Tang Nano's header rows: docs/thirdparty/tang-nano-20k-pinout.png,
#     turned so that the USB socket points right;
#   - the socket's rows: docs/thirdparty/esp32-c3-board-pinout.avif, which
#     draws the ESP32-C3 Super Mini's underside, mirrored to the component
#     side and turned so that the USB end points down;
#   - each MIDI input: docs/thirdparty/MIDI-circuit-6N138.png, built without
#     its diode and fed from 3.3 V;
#   - the jumper cable (the wire colours, the socket pin and the module pin
#     of each wire) and the slide potentiometer's three resistances are
#     recorded here and nowhere else in the repository. The potentiometer's
#     left end is its minimum: the wiper's voltage rises with the travel,
#     so that end has the 680 ohm to ground.
import math
import sys
from html import escape

W, H = 1150, 1310
DROP = 80
FONT = "Helvetica, Arial, sans-serif"

COLOURS = {
    "red": ("#e23b3b", "#9a1f1f"),
    "black": ("#2e2e2e", "#000000"),
    "white": ("#fbfbfb", "#8a8a8a"),
    "grey": ("#a3a8ae", "#63686e"),
    "purple": ("#8250c4", "#553080"),
    "blue": ("#2f72d6", "#1d4a91"),
    "green": ("#2fa456", "#1b6b33"),
    "yellow": ("#f4cc24", "#a88a00"),
    "orange": ("#f28c28", "#a85a0c"),
    "pink": ("#e86aa9", "#a13c72"),
    "teal": ("#2a8ea0", "#18606e"),
    "olive": ("#8a9a2b", "#55601a"),
}

head, board, parts, thin, thick, top = [], [], [], [], [], []


def rounded(points, radius):
    d = f"M{points[0][0]},{points[0][1]}"
    for i in range(1, len(points) - 1):
        (x0, y0), (x1, y1), (x2, y2) = points[i - 1], points[i], points[i + 1]
        d1 = math.hypot(x1 - x0, y1 - y0)
        d2 = math.hypot(x2 - x1, y2 - y1)
        r = min(radius, d1 / 2, d2 / 2)
        ax, ay = x1 - (x1 - x0) / d1 * r, y1 - (y1 - y0) / d1 * r
        bx, by = x1 + (x2 - x1) / d2 * r, y1 + (y2 - y1) / d2 * r
        d += f" L{ax:.1f},{ay:.1f} Q{x1},{y1} {bx:.1f},{by:.1f}"
    d += f" L{points[-1][0]},{points[-1][1]}"
    return d


def wire(layer, points, colour, core, casing, radius):
    c, k = COLOURS[colour]
    d = rounded(points, radius)
    common = 'fill="none" stroke-linecap="round" stroke-linejoin="round"'
    layer.append(f'<path d="{d}" stroke="{k}" stroke-width="{casing}" {common}/>')
    layer.append(f'<path d="{d}" stroke="{c}" stroke-width="{core}" {common}/>')


def board_wire(points, colour):
    wire(thin, points, colour, 2.6, 4.6, 5)


def jumper(points, colour):
    wire(thick, points, colour, 5.4, 7.8, 8)


def dot(x, y, colour, r=3.6):
    top.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{COLOURS[colour][1]}"/>')


def text(layer, x, y, s, size=11, fill="#333", anchor="start", weight="normal", rotate=None):
    place = f' transform="translate({x},{y}) rotate({rotate})"' if rotate is not None else f' x="{x}" y="{y}"'
    layer.append(
        f'<text{place} font-family="{FONT}" font-size="{size}" fill="{fill}" '
        f'text-anchor="{anchor}" font-weight="{weight}">{escape(s)}</text>'
    )


def rect(layer, x, y, w, h, fill, stroke="none", rx=0, extra=""):
    layer.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" {extra}/>')


def resistor(x, y, vertical, label=None, label_at=None, anchor="start", size=11):
    w, h = (10, 24) if vertical else (24, 10)
    rect(top, x - w / 2, y - h / 2, w, h, "#ead9ae", "#8a7440", 3)
    for k in (-6, 0, 6):
        if vertical:
            rect(top, x - w / 2, y + k - 1.2, w, 2.4, "#8a5a2b")
        else:
            rect(top, x + k - 1.2, y - h / 2, 2.4, h, "#8a5a2b")
    if label:
        text(top, label_at[0], label_at[1], label, size, "#333", anchor)


def pad(x, y):
    top.append(f'<circle cx="{x}" cy="{y}" r="4.2" fill="#d9b44a" stroke="#7a6520" stroke-width="1"/>')


def module_rows(x0, y_top, y_bottom, top_labels, bottom_labels, used_top, used_bottom):
    for i, label in enumerate(top_labels):
        x = x0 + 20 * i
        pad(x, y_top)
        used = i in used_top
        text(top, x - 3.5, y_top + 12, used_top.get(i, label), 10, "#ffffff" if used else "#aab2bd",
             weight="bold" if used else "normal", rotate=90)
    for i, label in enumerate(bottom_labels):
        x = x0 + 20 * i
        pad(x, y_bottom)
        used = i in used_bottom
        text(top, x + 3.5, y_bottom - 12, used_bottom.get(i, label), 10, "#ffffff" if used else "#aab2bd",
             weight="bold" if used else "normal", rotate=-90)


# Veroboard
rect(board, 35, 75, 1050, 650, "#dcefd8", "#7aa874", 8, 'stroke-width="2"')
for c in range(52):
    for r in range(32):
        board.append(f'<circle cx="{50 + 20 * c}" cy="{90 + 20 * r}" r="2.3" fill="#b4d3ad"/>')

# Tang Nano 20K, USB socket to the right
TX, TT, TB = 650, 330, 470
rect(parts, 628, 312, 447, 176, "#2c313a", "#111", 6)
rect(parts, 622, 372, 66, 56, "#c5cad1", "#777", 3)
rect(parts, 1058, 382, 40, 36, "#c5cad1", "#777", 8)
text(top, 960, 405, "Tang Nano 20K", 15, "#ffffff", "middle", "bold")
module_rows(
    TX, TT, TB,
    ["GND", "3V3", "18", "19", "20", "17", "31", "30", "29", "26", "25", "28", "27", "16", "15", "77", "85", "75", "74", "73"],
    ["52", "53", "71", "72", "3V3", "GND", "79", "86", "49", "55", "48", "51", "54", "56", "41", "42", "80", "76", "GND", "5V"],
    {0: "GND", 8: "29 MISO", 9: "26 MOSI", 10: "25 SCLK", 11: "28 CS", 12: "27 SPDIF"},
    {5: "GND", 7: "86 SPDIF"},
)

# ESP32-C3 socket, USB end down
XL, XR, SY = 470, 590, 530
rect(parts, 461, 520, 138, 160, "#ffffff", "none", 4, 'opacity="0.45"')
for x, labels in ((XL, ["0", "1", "2", "3", "4", "3.3", "G", "5V"]), (XR, ["21", "20", "10", "9", "8", "7", "6", "5"])):
    rect(parts, x - 9, 520, 18, 160, "#1c1c1c", "none", 2)
    for i, label in enumerate(labels):
        y = SY + 20 * i
        rect(top, x - 8, y - 8, 16, 16, "#1c1c1c", "#555", 2)
        text(top, x, y + 3.2, label, 8.5, "#ffffff", "middle", "bold")
text(top, 640, 566, "ESP32-C3 socket", 12, "#333", weight="bold")
text(top, 640, 581, "(the jumper cable", 10.5, "#555")
text(top, 640, 594, "is plugged in here)", 10.5, "#555")
text(top, 545, 703, "USB end", 9.5, "#666", "middle")

# ESP32-S3 module, USB sockets to the right
SX, ST, SB = 386, 840, 1020
rect(parts, 311, 820, 535, 220, "#23272e", "#111", 6)
rect(parts, 322, 898, 148, 64, "#b9bec6", "#777", 3)
text(top, 396, 934, "ESP32-S3", 12, "#333", "middle", "bold")
rect(parts, 832, 862, 34, 30, "#c5cad1", "#777", 5)
rect(parts, 832, 968, 34, 30, "#c5cad1", "#777", 5)
text(top, 655, 935, "ESP32-S3 module (HW-678)", 14, "#ffffff", "middle", "bold")
module_rows(
    SX, ST, SB,
    ["GND", "TX", "RX", "1", "2", "42", "41", "40", "39", "38", "37", "36", "35", "0", "45", "48", "47", "21", "20", "19", "GND", "GND"],
    ["3V3", "3V3", "RST", "4", "5", "6", "7", "15", "16", "17", "18", "8", "3", "46", "9", "10", "11", "12", "13", "14", "5Vin", "GND"],
    {3: "1 din2", 21: "GND"},
    {0: "3V3", 10: "18 din1", 15: "10 CS", 16: "11 MOSI", 17: "12 SCLK", 18: "13 MISO"},
)

# DIN sockets
for name, y in (("DIN1", 420), ("DIN2", 640)):
    rect(parts, 4, y - 35, 86, 70, "#c9ced6", "#777", 8)
    text(top, 36, y - 2, name, 13, "#222", "middle", "bold")
    text(top, 36, y + 13, "MIDI in", 10, "#444", "middle")
    for pin, dy in (("4", -10), ("5", 10)):
        pad(88, y + dy)
        text(top, 78, y + dy + 3.5, pin, 9.5, "#222", "end", "bold")

# Optocouplers
O1, O2 = (230, 490), (190, 610)
for xl, yt in (O1, O2):
    xr = xl + 60
    rect(parts, xl + 8, yt - 10, 44, 80, "#2b2b2b", "#111", 3)
    parts.append(f'<circle cx="{xl + 15}" cy="{yt - 3}" r="2" fill="#888"/>')
    text(top, xl + 26.5, yt + 30, "6N138", 10, "#ffffff", "middle", "bold", rotate=90)
    for i in range(4):
        y = yt + 20 * i
        rect(top, xl - 4, y - 4, 12, 8, "#c5cad1", "#666")
        rect(top, xr - 8, y - 4, 12, 8, "#c5cad1", "#666")
        text(top, xl + 11, y + 3, str(i + 1), 8, "#cfcfcf")
        text(top, xr - 11, y + 3, str(8 - i), 8, "#cfcfcf", "end")

# Slide potentiometer
rect(parts, 80, 225, 300, 40, "#d0d3d8", "#888", 3)
rect(parts, 100, 240, 260, 10, "#6b5b53", "none", 2)
rect(parts, 130, 231, 22, 28, "#444", "#222", 2)
text(top, 80, 205, "10 kΩ slide potentiometer, wiper on GPIO1 of the socket", 10.5, "#333")
text(top, 80, 220, "min", 9.5, "#555")
text(top, 380, 220, "max", 9.5, "#555", "end")
for x in (100, 230, 360):
    pad(x, 265)
board_wire([(230, 265), (230, 316), (486, 316), (486, 550), (XL, 550)], "olive")
board_wire([(100, 265), (100, 345), (404, 345)], "black")
dot(404, 345, "black")
resistor(100, 305, True, "680 Ω", (111, 309))
board_wire([(360, 265), (360, 290), (380, 290), (380, 490)], "red")
dot(380, 490, "red")
resistor(380, 420, True, "3.6 kΩ", (370, 424), "end")

# Coaxial S/PDIF cable
parts.append('<path d="M0,150 L455,150" stroke="#8f8f8f" stroke-width="16" stroke-linecap="butt" fill="none"/>')
parts.append('<path d="M0,150 L455,150" stroke="#f6f6f6" stroke-width="13" stroke-linecap="butt" fill="none"/>')
rect(parts, 414, 141, 12, 18, "#7d7d7d", "#555", 2)
text(top, 60, 128, "S/PDIF 96 kHz, coaxial cable", 12, "#333", weight="bold")

# Ground: the bar, the shield, the socket's G pin, the optocouplers
BUS = 404
thin.append(f'<path d="M{BUS},330 L650,330" stroke="#000" stroke-width="7" stroke-linecap="round" fill="none"/>')
thin.append(f'<path d="M{BUS},330 L650,330" stroke="#2e2e2e" stroke-width="5" stroke-linecap="round" fill="none"/>')
text(top, 452, 348, "GND", 10.5, "#222", "middle", "bold")
board_wire([(420, 158), (420, 330)], "black")
board_wire([(XL, 650), (512, 650), (512, 330)], "black")
board_wire([(BUS, 330), (BUS, 670), (O2[0] + 60, 670)], "black")
board_wire([(BUS, 550), (O1[0] + 60, 550)], "black")
dot(BUS, 550, "black")

# S/PDIF 96 kHz: pin 27, 330 ohm in series, 91 ohm to ground, the coax
board_wire([(TX + 240, TT), (890, 150), (455, 150)], "orange")
board_wire([(478, 150), (478, 330)], "orange")
dot(478, 150, "orange")
resistor(890, 235, True, "330 Ω", (901, 239))
resistor(478, 240, True, "91 Ω", (449, 244), "middle")

# S/PDIF 48 kHz: pin 86, then off the board to 68 ohm and the LED
board_wire([(TX + 140, TB), (790, 506), (1112, 506), (1112, 48), (1010, 48)], "pink")
board_wire([(TX + 100, TB), (750, 518), (1124, 518), (1124, 20), (965, 20), (965, 48), (990, 48)], "black")
resistor(1062, 48, False, "68 Ω", (1062, 38), "middle")
top.append('<circle cx="1000" cy="48" r="10" fill="#ff5d5d" stroke="#a11a1a" stroke-width="1.5"/>')
top.append('<circle cx="996.5" cy="44.5" r="3" fill="#ffd0d0"/>')
text(top, 950, 30, "red LED into the lab's optical input", 10.5, "#333", "end")
text(top, 950, 43, "S/PDIF 48 kHz, off the board", 10.5, "#555", "end")

# SPI: the socket to the Tang Nano
board_wire([(XL, 610), (498, 610), (498, 262), (TX + 200, 262), (TX + 200, TT)], "grey")
board_wire([(XR, 670), (554, 670), (554, 274), (TX + 160, 274), (TX + 160, TT)], "white")
board_wire([(XR, 650), (566, 650), (566, 286), (TX + 180, 286), (TX + 180, TT)], "purple")
board_wire([(XR, 630), (578, 630), (578, 298), (TX + 220, 298), (TX + 220, TT)], "blue")

# MIDI: each DIN socket to its optocoupler, 220 ohm in series
board_wire([(88, 410), (200, 410), (200, 510), (O1[0], 510)], "teal")
board_wire([(88, 430), (150, 430), (150, 530), (O1[0], 530)], "teal")
resistor(125, 410, False, "220 Ω", (125, 400), "middle")
board_wire([(88, 630), (O2[0], 630)], "teal")
board_wire([(88, 650), (O2[0], 650)], "teal")
resistor(125, 630, False, "220 Ω", (125, 620), "middle")

# The optocouplers' supply
RISER = 380
board_wire([(XL, 630), (RISER, 630), (RISER, 490), (O1[0] + 60, 490)], "red")
board_wire([(RISER, 610), (O2[0] + 60, 610)], "red")
dot(RISER, 610, "red")

# Their outputs, each with a 220 ohm pull-up, and 4.7 kilohm from pin 7 to ground
board_wire([(XL, 530), (O1[0] + 60, 530)], "green")
board_wire([(352, 490), (352, 530)], "red")
dot(352, 490, "red")
dot(352, 530, "green")
resistor(352, 510, True, "220", (360, 513.5), size=9.5)
board_wire([(O1[0] + 60, 510), (332, 510), (332, 550)], "black")
dot(332, 550, "black")
resistor(312, 510, False, "4k7", (312, 502), "middle", 9.5)

board_wire([(XL, 570), (392, 570), (392, 650), (O2[0] + 60, 650)], "yellow")
board_wire([(312, 610), (312, 650)], "red")
dot(312, 610, "red")
dot(312, 650, "yellow")
resistor(312, 630, True, "220", (320, 633.5), size=9.5)
board_wire([(O2[0] + 60, 630), (292, 630), (292, 670)], "black")
dot(292, 670, "black")
resistor(272, 630, False, "4k7", (272, 622), "middle", 9.5)

# The jumper cable: the socket to the ESP32-S3
jumper([(XL, 530), (422, 530), (422, 742), (284, 742), (284, 1064), (SX + 200, 1064), (SX + 200, SB)], "green")
jumper([(XL, 570), (446, 570), (446, ST)], "yellow")
jumper([(XL, 630), (434, 630), (434, 754), (296, 754), (296, 1052), (SX, 1052), (SX, SB)], "red")
jumper([(XL, 650), (458, 650), (458, 794), (SX + 420, 794), (SX + 420, ST)], "black")
jumper([(XR, 670), (602, 670), (602, 778), (880, 778), (880, 1052), (SX + 360, 1052), (SX + 360, SB)], "white")
jumper([(XL, 610), (498, 610), (498, 766), (892, 766), (892, 1064), (SX + 340, 1064), (SX + 340, SB)], "grey")
jumper([(XR, 650), (614, 650), (614, 754), (904, 754), (904, 1076), (SX + 320, 1076), (SX + 320, SB)], "purple")
jumper([(XR, 630), (626, 630), (626, 742), (916, 742), (916, 1088), (SX + 300, 1088), (SX + 300, SB)], "blue")
text(top, 934, 900, "10-wire jumper cable", 11.5, "#333", weight="bold")
text(top, 934, 915, "brown and orange", 10.5, "#555")
text(top, 934, 928, "are spare", 10.5, "#555")

# Legend
wire(top, [(60, 1128), (110, 1128)], "blue", 5.4, 7.8, 8)
text(top, 120, 1132, "jumper wire, in the cable's own colour", 11.5, "#333")
wire(top, [(400, 1128), (450, 1128)], "blue", 2.6, 4.6, 5)
text(top, 460, 1132, "wiring on the veroboard, coloured by signal", 11.5, "#333")
top.append(f'<circle cx="790" cy="1128" r="3.6" fill="{COLOURS["blue"][1]}"/>')
text(top, 802, 1132, "joint (wires that only cross are not joined)", 11.5, "#333")
text(top, 60, 1158, "Tang Nano numbers are FPGA package pins. ESP32 numbers are GPIOs, as printed on the boards.", 11.5, "#555")
text(top, 60, 1178, "Each MIDI input is the 6N138 circuit of docs/thirdparty/MIDI-circuit-6N138.png, built without its diode and fed from the ESP32's 3.3 V.", 11.5, "#555")
text(top, 60, 1198, "The slide potentiometer was used during early testing and was later abandoned: the jumper cable has no wire for its wiper.", 11.5, "#555")

# Title
TITLE = "Noaidi Synth prototype: veroboard wiring"
text(head, W / 2, 36, TITLE, 20, "#222", "middle", "bold")
text(head, W / 2, 57, "Component side. The ESP32-S3 module sits on a jumper cable plugged into the socket made for an ESP32-C3 Super Mini.",
     11.5, "#555", "middle")

svg = (
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">\n'
    "<!-- Copyright © 2026 Thor H. Linløkken <thj@thj.no>. License: CERN-OHL-S v2.\n"
    "     Drawn by tools/docs/veroboard_wiring.py. -->\n"
    f"<title>{escape(TITLE)}</title>\n"
    f'<rect width="{W}" height="{H}" fill="#ffffff"/>\n'
    + "\n".join(head)
    + f'\n<g transform="translate(0,{DROP})">\n'
    + "\n".join(board + parts + thin + thick + top)
    + "\n</g>\n</svg>\n"
)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(svg)
