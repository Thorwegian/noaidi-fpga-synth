#!/usr/bin/env python3
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
"""gen_panel.py -- generate the Noaidi Open Stage Control session.

The panel IS the CC map (docs/midi_schema.md) rendered as knobs: each
entry below is one widget, so extending the schema means adding a line
here and rerunning. Emits noaidi-panel.json next to itself.

    python3 tools/osc_panel/gen_panel.py

Conventions: /control preArgs are [channel(1-based), cc]; every widget
targets the 'noaidi' MIDI device declared by run.sh (--midi noaidi:...).
Defaults mirror the boot patch (app/storage/Patches/Factory/Pads/
Supersaw.toml) so the panel opens showing it (widgets send nothing
until touched).

Layout notes (o-s-c v1.31): panel widgets do NOT render their label,
so every section carries an explicit text-widget header; children of
flex panels need expand:true to share space, fixed height otherwise.
"""
import json
import os

TARGET = "midi:noaidi"
CH = 1

# Widget labels do not render for knobs/faders/switches in v1.31
# (buttons and text widgets do), so every control is wrapped with an
# explicit text caption underneath.
# The caption's @{ccNN} reference is o-s-c's live-value syntax: the
# readout updates as the control moves.

def captioned(widget, caption):
    return {
        "type": "panel",
        "id": f"wrap_{widget['id']}",
        "layout": "vertical",
        "expand": True,
        "widgets": [
            widget,
            {
                "type": "text",
                "id": f"cap_{widget['id']}",
                "value": caption,
                "default": caption,
                "align": "center",
                "height": 34,
                "wrap": True,
                "css": "font-size: 11px;",
            },
        ],
    }

def knob(cc, label, default=64, bipolar=False):
    w = {
        "type": "knob",
        "id": f"cc{cc}",
        "label": False,
        "address": "/control",
        "preArgs": [CH, cc],
        "target": TARGET,
        "range": {"min": 0, "max": 127},
        "default": default,
        "doubleTap": True,   # double-tap resets to default
        "expand": True,
    }
    if bipolar:
        w["origin"] = 64     # value bar grows from center
    return captioned(w, f"{label} ({cc}): @{{cc{cc}}}")

def fader(cc, label, default=0):
    wrapped = knob(cc, label, default)
    wrapped["widgets"][0]["type"] = "fader"
    return wrapped

def switch(cc, label, values, default):
    w = {
        "type": "switch",
        "id": f"cc{cc}",
        "label": False,
        "address": "/control",
        "preArgs": [CH, cc],
        "target": TARGET,
        "values": values,
        "default": default,
        "expand": True,
    }
    return captioned(w, f"{label} ({cc})")

def button(cc, label, value):
    # buttons DO render their label (in-widget) - no caption needed
    return {
        "type": "button",
        "id": f"cc{cc}",
        "label": label,
        "mode": "push",
        "address": "/control",
        "preArgs": [CH, cc],
        "target": TARGET,
        "on": value,
        "off": None,         # nothing on release
        "expand": True,
    }

def number_input(widget_id, caption):
    # a typed number, sent by the Select button rather than on its own
    w = {
        "type": "input",
        "id": widget_id,
        "label": False,
        "numeric": True,
        # commit every keystroke: otherwise the value commits only on
        # Enter or blur, and SELECT would read the previous number
        "asYouType": True,
        "default": 0,
        "bypass": True,
        "expand": True,
        "css": "font-size: 18px;",
    }
    return captioned(w, caption)

def program_select():
    # Bank Select (CC 0 = bank // 128, CC 32 = bank % 128) then Program
    # Change, in that order: a bank applies at the next Program Change
    # (docs/storage_format.md "Banks").
    script = (
        "if (value !== 1) return\n"
        "var bank = Math.max(0, Math.min(16383, Math.round(get('bank_number') || 0)))\n"
        "var program = Math.max(0, Math.min(127, Math.round(get('program_number') || 0)))\n"
        f"send('{TARGET}', '/control', {CH}, 0, Math.floor(bank / 128))\n"
        f"send('{TARGET}', '/control', {CH}, 32, bank % 128)\n"
        f"send('{TARGET}', '/program', {CH}, program)\n"
    )
    return [
        number_input("bank_number", "Bank"),
        number_input("program_number", "Program"),
        {
            "type": "button",
            "id": "program_select",
            "label": "SELECT",
            "mode": "push",
            "on": 1,
            "off": 0,
            "bypass": True,      # the script sends; the button itself does not
            "onValue": script,
            "expand": True,
        },
    ]

def section(title, widgets):
    slug = title.lower().replace(" ", "_").replace("&", "and")
    return {
        "type": "panel",
        "id": f"sec_{slug}",
        "layout": "vertical",
        "expand": True,
        "widgets": [
            {
                "type": "text",
                "id": f"hdr_{slug}",
                "value": title.upper(),
                "default": title.upper(),
                "align": "center",
                "height": 26,
                "css": "font-size: 13px; letter-spacing: 3px; opacity: 0.7;",
            },
            {
                "type": "panel",
                "id": f"row_{slug}",
                "layout": "horizontal",
                "expand": True,
                "widgets": widgets,
            },
        ],
    }

WAVES = {"Saw": 0, "Pulse": 32, "Tri": 64, "Sine": 96}

root_widgets = [
    {
        # three oscillator subsections sharing one row, one per
        # oscillator
        "type": "panel",
        "id": "osc_row",
        "layout": "horizontal",
        "expand": True,
        "widgets": [
            # PITCH/FINE default 64 = center: double-tap is the way
            # back to unison. NOTE: osc2 BOOTS at -12 (the sine sub),
            # so its Pitch dial reads center until first touched: the
            # double-tap home wins over boot-state display.
            section("Oscillator 1", [
                switch(20, "Wave", WAVES, 0),
                knob(14, "Pitch", 64, bipolar=True),
                knob(15, "Fine", 64, bipolar=True),
                knob(25, "Pulse Width", 0),   # unipolar: 0=square, 127=5%
            ]),
            section("Oscillator 2", [
                switch(21, "Wave", WAVES, 96),
                knob(22, "Pitch", 64, bipolar=True),
                knob(23, "Fine", 64, bipolar=True),
                knob(85, "Pulse Width", 0),   # unipolar
            ]),
            section("Mix and Unison", [
                knob(24, "Osc Balance", 64, bipolar=True),
                switch(26, "Voice Mode",
                       {"2 plain": 0, "7+1": 64, "4+4": 127}, 64),
                knob(27, "Unison Spread", 24),
                knob(28, "Stereo Spread", 127),   # continuous:
                                                  # 0 centered, 127 hard pan
            ]),
        ],
    },
    section("Filter", [
        knob(74, "Cutoff", 64),
        knob(106, "Cutoff Fine", 0),
        knob(71, "Resonance", 12),           # boot reso r=0x200 ≈ cc 12 (532)
        switch(29, "Type", {"LP": 0, "BP": 64, "HP": 127}, 0),
        switch(30, "Slope", {"12 dB": 0, "24 dB": 127}, 127),
        knob(31, "Key Track", 64, bipolar=True),   # center = 100%
    ]),
    section("Amp Envelope  -  knob up = longer", [
        knob(73, "Attack", 51),
        knob(75, "Decay", 111),
        knob(79, "Sustain", 120),
        knob(72, "Release", 107),
    ]),
    section("Filter (MOD) Envelope", [
        knob(102, "Attack", 51),
        knob(103, "Decay", 111),
        knob(104, "Sustain", 120),
        knob(105, "Release", 107),
        knob(107, "Env>Cutoff", 87, bipolar=True),  # 64 = off; square-law
                                                    #: 87 ~ boot +2 oct
        # CC 108 (env dest) deliberately absent: stored-only in firmware,
        # cutoff is the sole implemented destination - a knob that
        # does nothing erodes trust in the panel.
    ]),
    section("LFOs", [
        knob(76, "Vibrato Rate", 64),
        knob(77, "Vibrato Coarse", 0),       # pitch: span in whole semitones
        knob(115, "Vibrato Fine", 24),       # + fine/128 semitone; startup
                                             # depth 16 = span 0.1875 = 0 + 24
        switch(113, "LFO1 Shape", WAVES, 64),
        switch(114, "LFO1 Dest",
               {"PWM": 0, "Reso": 32, "Pitch": 64, "Cutoff": 96}, 64),
        knob(109, "LFO2 Rate", 64),
        knob(110, "LFO2 Coarse", 0),
        knob(116, "LFO2 Fine", 0),
        switch(111, "LFO2 Shape", WAVES, 64),
        switch(112, "LFO2 Dest",
               {"PWM": 0, "Reso": 32, "Pitch": 64, "Cutoff": 96}, 0),
    ]),
    section("Global", [
        # knobs, because vertical sliders are nearly unusable here.
        # No mod-wheel control: the physical keyboard has it, and
        # wheel→cutoff is a temporary hardwiring anyway, due to become
        # a routable per-channel destination.
        knob(7, "Volume", 103),              # boot volume 0xCF ≈ cc 103 (206)
        knob(10, "Pan", 64, bipolar=True),
        knob(86, "Vel>Vol", 64),        # amp-env AMOUNT (OB-8 "Vol")
        knob(87, "Vel>Filt", 64),       # MOD-env AMOUNT (OB-8 "Filt")
                                        # 0 = velocity OFF, full patch amount
        switch(119, "Test Tone", {"Off": 0, "On": 127}, 0),
        button(123, "NOTES OFF", 0),
        button(120, "SOUND OFF", 0),
    ] + program_select()),
    # No virtual keyboard: the physical keyboard covers notes,
    # velocity and both wheels. This panel exists precisely for the
    # MIDI a keyboard CANNOT send.
]

session = {
    "version": "1.31.1",
    "content": {
        "type": "root",
        "id": "root",
        "layout": "vertical",
        "widgets": root_widgets,
    },
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "noaidi-panel.json")
with open(out, "w") as f:
    json.dump(session, f, indent=2)

def count(w):
    if "preArgs" in w:
        return 1
    return sum(count(x) for x in w.get("widgets", []))

print(f"wrote {out}: {sum(count(s) for s in root_widgets)} controls")
