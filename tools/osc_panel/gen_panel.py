#!/usr/bin/env python3
"""gen_panel.py -- generate the Noaidi Open Stage Control session (#90).

The panel IS the CC map (docs/midi_schema.md) rendered as knobs: each
entry below is one widget, so extending the schema means adding a line
here and rerunning. Emits noaidi-panel.json next to itself.

    python3 tools/osc_panel/gen_panel.py

Conventions: /control preArgs are [channel(1-based), cc]; every widget
targets the 'noaidi' MIDI device declared by run.sh (--midi noaidi:...).
Defaults mirror patch_default() so the panel opens showing the boot
patch (widgets send nothing until touched).

Layout notes (o-s-c v1.31): panel widgets do NOT render their label,
so every section carries an explicit text-widget header; children of
flex panels need expand:true to share space, fixed height otherwise.
"""
import json
import os

TARGET = "midi:noaidi"
CH = 1

# Widget labels turned out not to render for knobs/faders/switches in
# v1.31 (buttons and text widgets do - measured on Thor's screen), so
# every control is wrapped with an explicit text caption underneath.
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
    section("Oscillators", [
        switch(20, "Osc1 Wave", WAVES, 0),
        switch(21, "Osc2 Wave", WAVES, 96),
        knob(22, "Osc2 Pitch", 0),           # 0 = -12 semi (sine sub default)
        knob(23, "Osc2 Fine", 64, bipolar=True),
        knob(24, "Osc Balance", 64, bipolar=True),
        knob(25, "Pulse Width", 64, bipolar=True),
        switch(26, "Voice Mode", {"2 plain": 0, "7+1": 64, "4+4": 127}, 64),
        knob(27, "Unison Spread", 24),
        switch(28, "Uni Stereo", {"Off": 0, "On": 127}, 127),
    ]),
    section("Filter", [
        knob(74, "Cutoff", 64),
        knob(106, "Cutoff Fine", 0),
        knob(71, "Resonance", 4),            # boot reso r=0x200 = cc 4
        switch(29, "Type", {"LP": 0, "BP": 64, "HP": 127}, 0),
        switch(30, "Slope", {"12 dB": 0, "24 dB": 127}, 127),
        knob(31, "Key Track", 0),
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
        knob(107, "Env>Cutoff", 96, bipolar=True),  # 64 = off; 96 = +2 oct
        knob(108, "Env Dest", 0),
    ]),
    section("LFOs", [
        knob(76, "Vibrato Rate", 64),
        knob(77, "Vibrato Depth", 16),
        switch(113, "LFO1 Shape", WAVES, 64),
        knob(109, "LFO2 Rate", 64),
        knob(110, "LFO2 Depth", 0),
        switch(111, "LFO2 Shape", WAVES, 64),
        switch(112, "LFO2 Dest", {"PWM": 0, "Reso": 64, "Pitch": 127}, 0),
    ]),
    section("Global", [
        fader(7, "Volume", 100),
        knob(10, "Pan", 64, bipolar=True),
        fader(1, "Wheel > Cutoff", 0),
        switch(119, "Test Tone", {"Off": 0, "On": 127}, 0),
        button(123, "NOTES OFF", 0),
        button(120, "SOUND OFF", 0),
    ]),
    {
        # test keyboard: /note channel note velocity (o-s-c MIDI spec)
        "type": "keyboard",
        "id": "kbd",
        "keys": 25,
        "start": 48,
        "address": "/note",
        "preArgs": [CH],
        "target": TARGET,
        "on": 100,
        "off": 0,
        "expand": True,
    },
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

n = 0
for s in root_widgets:
    rows = s.get("widgets", [])
    n += len(rows[1]["widgets"]) if len(rows) == 2 and "widgets" in rows[1] else 1
print(f"wrote {out}: {n} controls")
