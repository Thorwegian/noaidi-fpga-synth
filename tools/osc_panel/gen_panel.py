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
"""
import json
import os

TARGET = "midi:noaidi"
CH = 1

def knob(cc, label, default=64, bipolar=False):
    w = {
        "type": "knob",
        "id": f"cc{cc}",
        "label": f"{label}\n{cc}",
        "address": "/control",
        "preArgs": [CH, cc],
        "target": TARGET,
        "range": {"min": 0, "max": 127},
        "default": default,
        "doubleTap": True,   # double-tap resets to default
    }
    if bipolar:
        w["origin"] = 64     # value bar grows from center
    return w

def fader(cc, label, default=0):
    w = knob(cc, label, default)
    w["type"] = "fader"
    return w

def switch(cc, label, values, default):
    return {
        "type": "switch",
        "id": f"cc{cc}",
        "label": f"{label}\n{cc}",
        "address": "/control",
        "preArgs": [CH, cc],
        "target": TARGET,
        "values": values,
        "default": default,
    }

def button(cc, label, value):
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
    }

def section(label, widgets):
    return {
        "type": "panel",
        "id": f"sec_{label.lower().replace(' ', '_')}",
        "label": label,
        "layout": "horizontal",
        "widgets": widgets,
    }

root_widgets = [
    section("Oscillators", [
        switch(20, "Osc1 Wave", {"Saw": 0, "Pulse": 32, "Tri": 64, "Sine": 96}, 0),
        switch(21, "Osc2 Wave", {"Saw": 0, "Pulse": 32, "Tri": 64, "Sine": 96}, 96),
        knob(22, "Osc2 Coarse", 0),          # 0 = -12 semi (sine sub default)
        knob(23, "Detune", 64, bipolar=True),
        knob(24, "Osc Mix", 64, bipolar=True),
        knob(25, "Duty", 64, bipolar=True),
        switch(26, "Voice Mode", {"2 plain": 0, "7+1": 64, "4+4": 127}, 64),
        knob(27, "Uni Detune", 24),
        switch(28, "Stereo", {"Off": 0, "On": 127}, 127),
    ]),
    section("Filter", [
        knob(74, "Cutoff", 64),
        knob(106, "Cutoff Fine", 0),
        knob(71, "Resonance", 4),            # boot reso r=0x200 = cc 4
        switch(29, "Type", {"LP": 0, "BP": 64, "HP": 127}, 0),
        switch(30, "Slope", {"12 dB": 0, "24 dB": 127}, 127),
        knob(31, "Key Track", 0),
    ]),
    section("Amp Env", [                     # rate CCs invert: up = longer
        knob(73, "Attack", 51),
        knob(75, "Decay", 111),
        knob(79, "Sustain", 120),
        knob(72, "Release", 107),
    ]),
    section("Mod Env", [                     # boot: copy of amp env (#87)
        knob(102, "Attack", 51),
        knob(103, "Decay", 111),
        knob(104, "Sustain", 120),
        knob(105, "Release", 107),
        knob(107, "Depth", 96, bipolar=True),  # 64 = off; 96 = +2 oct boot
        knob(108, "Dest", 0),
    ]),
    section("LFOs", [
        knob(76, "LFO1 Rate", 64),
        knob(77, "LFO1 Depth", 16),
        switch(113, "LFO1 Shape", {"Saw": 0, "Pulse": 32, "Tri": 64, "Sine": 96}, 64),
        knob(109, "LFO2 Rate", 64),
        knob(110, "LFO2 Depth", 0),
        switch(111, "LFO2 Shape", {"Saw": 0, "Pulse": 32, "Tri": 64, "Sine": 96}, 64),
        switch(112, "LFO2 Dest", {"PWM": 0, "Reso": 64, "Pitch": 127}, 0),
    ]),
    section("Global", [
        fader(7, "Volume", 100),
        knob(10, "Pan", 64, bipolar=True),
        fader(1, "Mod Wheel", 0),
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
print(f"wrote {out}: {sum(len(s.get('widgets', [s])) for s in root_widgets)} widgets")
