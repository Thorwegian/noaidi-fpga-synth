#!/usr/bin/env python3
"""runner.py -- keep Open Stage Control linked to the Noaidi across board resets (#287).

    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2

Open Stage Control opens its MIDI ports by number at startup and never re-opens
one that vanished, and BlueZ's MIDI plugin tears the "Noaidi Bluetooth" ALSA
client down with every disconnect and creates a new one on reconnect. So O.S.C.
talks to this runner instead, through one ALSA port that never goes away, and
the runner owns the synth's side of the link:

  - one ALSA client, "Noaidi O.S.C.", with the port "surface" that O.S.C.
    reads from and writes to; everything O.S.C. writes is relayed to the synth,
    everything the synth sends is relayed to O.S.C.'s subscription;
  - the Noaidi kept trusted and a persistent bluetoothctl session that
    reconnects it whenever its port is gone (BlueZ drops a connection nobody
    references; the session is the reference);
  - the sequencer's announce port watched for the "Noaidi Bluetooth" client
    appearing and vanishing: when it appears the runner waits LINK_DELAY
    (BlueZ's plugin subscribes to the synth's notifications about a second after
    the connection, and enumerating the sequencer during that setup leaves it
    unsubscribed, #284), links both ways and asks the synth for its state
    (a SysEx state request, docs/midi_schema.md), so the panel's knobs move to the loaded patch;
  - every reconnect logged with the time it took.

    ~/.noaidi-blenv/bin/python3 tools/osc_panel/runner.py [--mac 10:00:3B:B0:4D:A6]

Needs alsa_midi (the lab box's ~/.noaidi-blenv) and bluetoothctl. run.sh starts
it beside O.S.C.
"""
import argparse
import subprocess
import sys
import time

NOAIDI_MAC = "10:00:3B:B0:4D:A6"
LINK_DELAY = 3.0      # seconds after the Noaidi's ALSA port appears, before linking to it
RECONNECT_EVERY = 5.0 # seconds between connect attempts while the port is gone
STATE_REQUEST = bytes([0xF0, 0x7D, 0x4E, 0x4F, 0x10, 0xF7])  # SysEx op 0x10 (docs/midi_schema.md): the synth answers with the whole patch


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


class Runner:
    def __init__(self, mac):
        from alsa_midi import SYSTEM_ANNOUNCE, PortCaps, SequencerClient

        self.mac = mac
        self.client = SequencerClient("Noaidi O.S.C.")
        self.surface = self.client.create_port("surface")  # O.S.C. reads from and writes to this
        self.to_synth = self.client.create_port("to synth", caps=PortCaps.READ | PortCaps.SUBS_READ)
        self.from_synth = self.client.create_port("from synth", caps=PortCaps.WRITE | PortCaps.SUBS_WRITE)
        self.announce = self.client.create_port("announce", caps=PortCaps.WRITE | PortCaps.SUBS_WRITE | PortCaps.NO_EXPORT)
        self.announce.connect_from(SYSTEM_ANNOUNCE)
        self.noaidi = None        # the Noaidi's ALSA port while linked
        self.link_at = None       # when to link, after the port appeared
        self.gone_since = None    # when the port vanished (for the reconnect timing)
        self.next_connect = 0.0
        self.btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
        self.bt(f"trust {mac}")

    def bt(self, command):
        self.btctl.stdin.write(command + "\n")
        self.btctl.stdin.flush()

    def noaidi_port(self):
        for p in self.client.list_ports():
            if "Noaidi" in (p.client_name or "") and "Bluetooth" in (p.name or ""):
                return p
        return None

    def link(self, port):
        self.to_synth.connect_to(port)
        self.from_synth.connect_from(port)
        self.noaidi = port
        took = f" after {time.time() - self.gone_since:.1f} s" if self.gone_since else ""
        log(f"linked to '{port.client_name}:{port.name}'{took}; asking for the state")
        self.gone_since = None
        self.request_state()

    def request_state(self):
        from alsa_midi import SysExEvent

        self.client.event_output(SysExEvent(data=STATE_REQUEST), port=self.to_synth)
        self.client.drain_output()

    def unlinked(self):
        if self.noaidi is not None:
            log("the Noaidi's port is gone: reconnecting")
        self.noaidi = None
        self.link_at = None
        self.gone_since = self.gone_since or time.time()
        self.next_connect = time.time()  # try at once, then every RECONNECT_EVERY

    def on_announce(self, ev):
        from alsa_midi import ClientExitEvent, PortExitEvent, PortStartEvent

        if isinstance(ev, PortStartEvent):
            port = self.noaidi_port()
            if port is not None and self.noaidi is None and self.link_at is None:
                log(f"'{port.client_name}' appeared; linking in {LINK_DELAY:.0f} s")
                self.link_at = time.time() + LINK_DELAY
        elif isinstance(ev, (PortExitEvent, ClientExitEvent)):
            if self.noaidi is not None and self.noaidi_port() is None:
                self.unlinked()

    def surface_got_reader(self, ev):
        """The sequencer's notice that a client subscribed to read from the
        surface port (O.S.C. opening its input), delivered to the port."""
        from alsa_midi import PortSubscribedEvent

        if not isinstance(ev, PortSubscribedEvent):
            return False
        sender = getattr(ev, "connect_sender", None)
        return sender is not None and sender.client_id == self.client.client_id and sender.port_id == self.surface.port_id

    @staticmethod
    def fresh(ev):
        """A new event with the received one's musical content and nothing
        else: a received event carries the sender's flags, queue and time, and
        O.S.C.'s (RtMidi's) re-sent as they are are refused by the sequencer
        with EINVAL."""
        from alsa_midi import (ChannelPressureEvent, ControlChangeEvent, KeyPressureEvent, NoteOffEvent,
                               NoteOnEvent, PitchBendEvent, ProgramChangeEvent, SysExEvent)

        if isinstance(ev, NoteOnEvent):
            return NoteOnEvent(note=ev.note, channel=ev.channel, velocity=ev.velocity)
        if isinstance(ev, NoteOffEvent):
            return NoteOffEvent(note=ev.note, channel=ev.channel, velocity=ev.velocity)
        if isinstance(ev, ControlChangeEvent):
            return ControlChangeEvent(channel=ev.channel, param=ev.param, value=ev.value)
        if isinstance(ev, ProgramChangeEvent):
            return ProgramChangeEvent(channel=ev.channel, value=ev.value)
        if isinstance(ev, PitchBendEvent):
            return PitchBendEvent(channel=ev.channel, value=ev.value)
        if isinstance(ev, ChannelPressureEvent):
            return ChannelPressureEvent(channel=ev.channel, value=ev.value)
        if isinstance(ev, KeyPressureEvent):
            return KeyPressureEvent(note=ev.note, channel=ev.channel, value=ev.value)
        if isinstance(ev, SysExEvent):
            return SysExEvent(data=bytes(ev.data))
        return None  # the sequencer's own notices (a client subscribing) are not relayed

    def relay(self, ev):
        """O.S.C.'s events to the synth, the synth's to O.S.C., MIDI messages
        only, as fresh events to the port's subscribers. A refusal is logged,
        never fatal: the link outlives one bad event."""
        from alsa_midi import ALL_SUBSCRIBERS, ALSAError

        dest = getattr(ev, "dest", None)
        out = self.fresh(ev)
        if dest is None or out is None:
            return
        if dest.port_id == self.surface.port_id:
            port = self.to_synth if self.noaidi is not None else None
        elif dest.port_id == self.from_synth.port_id:
            port = self.surface
        else:
            return
        if port is None:
            return
        try:
            self.client.event_output(out, port=port, dest=ALL_SUBSCRIBERS)
            self.client.drain_output()
        except ALSAError as error:
            log(f"relay refused {type(ev).__name__}: {error}")

    def run(self):
        log(f"'Noaidi O.S.C.:surface' is the panel's port; the Noaidi is {self.mac}")
        port = self.noaidi_port()
        if port is not None:
            self.link_at = time.time() + LINK_DELAY
        else:
            self.unlinked()
        while True:
            ev = self.client.event_input(timeout=0.25)
            now = time.time()
            if ev is not None:
                dest = getattr(ev, "dest", None)
                if dest is not None and dest.port_id == self.announce.port_id:
                    self.on_announce(ev)
                elif self.surface_got_reader(ev):
                    # O.S.C. (a reader) subscribed to the surface port, maybe
                    # seconds after the link: it is the one to be told the state
                    if self.noaidi is not None:
                        log("a surface subscribed; asking for the state")
                        self.request_state()
                else:
                    self.relay(ev)
            if self.link_at is not None and now >= self.link_at:
                self.link_at = None
                port = self.noaidi_port()
                if port is not None:
                    self.link(port)
                else:
                    self.unlinked()
            if self.noaidi is None and self.link_at is None and now >= self.next_connect:
                self.next_connect = now + RECONNECT_EVERY
                self.bt(f"connect {self.mac}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac", default=NOAIDI_MAC, help="the Noaidi's BLE address")
    args = ap.parse_args()
    runner = Runner(args.mac)
    try:
        runner.run()
    except KeyboardInterrupt:
        pass
    finally:
        runner.btctl.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
