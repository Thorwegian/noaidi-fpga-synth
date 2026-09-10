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
    {
        # three oscillator subsections sharing one row (Thor: each
        # oscillator its own subsection)
        "type": "panel",
        "id": "osc_row",
        "layout": "horizontal",
        "expand": True,
        "widgets": [
            # PITCH/FINE default 64 = center: double-tap is the way
            # back to unison (Thor 2026-09-10). NOTE: osc2 BOOTS at
            # -12 (the sine sub), so its Pitch dial reads center until
            # first touched - the double-tap home wins over boot-state
            # display, per Thor.
            section("Oscillator 1", [
                switch(20, "Wave", WAVES, 0),
                knob(14, "Pitch", 64, bipolar=True),
                knob(15, "Fine", 64, bipolar=True),
                knob(25, "Pulse Width", 0),   # unipolar: 0=square, 127=5% (#94)
            ]),
            section("Oscillator 2", [
                switch(21, "Wave", WAVES, 96),
                knob(22, "Pitch", 64, bipolar=True),
                knob(23, "Fine", 64, bipolar=True),
                knob(85, "Pulse Width", 0),   # unipolar (#94)
            ]),
            section("Mix and Unison", [
                knob(24, "Osc Balance", 64, bipolar=True),
                switch(26, "Voice Mode",
                       {"2 plain": 0, "7+1": 64, "4+4": 127}, 64),
                knob(27, "Unison Spread", 24),
                switch(28, "Uni Stereo", {"Off": 0, "On": 127}, 127),
            ]),
        ],
    },
    section("Filter", [
        knob(74, "Cutoff", 64),
        knob(106, "Cutoff Fine", 0),
        knob(71, "Resonance", 4),            # boot reso r=0x200 = cc 4
        switch(29, "Type", {"LP": 0, "BP": 64, "HP": 127}, 0),
        switch(30, "Slope", {"12 dB": 0, "24 dB": 127}, 127),
        knob(31, "Key Track", 64, bipolar=True),   # center = 100% (#94)
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
                                                    # (#94): 87 ~ boot +2 oct
        # CC 108 (env dest) deliberately absent: stored-only in firmware,
        # cutoff is the sole implemented destination (#42) - a knob that
        # does nothing erodes trust in the panel (Thor, 2026-09-10).
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
        # knobs, not faders (Thor: vertical sliders nearly unusable).
        # No mod-wheel control here: Thor has it on the physical
        # keyboard, and wheel→cutoff is a temporary hardwiring anyway —
        # it becomes a routable per-channel destination (#92 note).
        knob(7, "Volume", 100),
        knob(10, "Pan", 64, bipolar=True),
        knob(86, "Vel>Amp", 64),        # 64 = historical, 0 = OFF (#89)
        knob(87, "Vel>Cutoff", 64),
        switch(119, "Test Tone", {"Off": 0, "On": 127}, 0),
        button(123, "NOTES OFF", 0),
        button(120, "SOUND OFF", 0),
    ]),
    # No virtual keyboard: Thor's physical keyboard covers notes /
    # velocity / both wheels — the panel exists precisely for the MIDI
    # the physical keyboard CANNOT send (Thor, 2026-09-10).
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
