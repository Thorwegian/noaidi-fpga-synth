# The benchmark: the synth before the CSP-as-processor work

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

The reference every CSP build is judged against (issue #222, 2026-10-17):
the synth as of `main` just before the first CSP-as-processor merge
(`7c959b4`, 2026-10-12), rebuilt with the pinned flow (seed 4, 122.7 MHz)
and the 2026-10-17 bitstream generator, its own firmware and patch
storage, playing the Galaxy patch (Factory bank program 1: a two-note
arpeggio from LFO 1 on the pitch, a tremolo from LFO 2 on the pulse
width, both LFOs free-running) through `tools/lab/baseline_recording.py`
— at 60 BPM, C5 … C6 as quarter notes, the C6 held a full bar, a bar of
silence, C4 E4 G4 held four beats and released, the release recorded to
its end — from the S/PDIF output, 48 kHz, 16-bit, stereo.

- the recording: `baseline_galaxy_7c959b4.wav` and `.m4a` on the GitHub
  pre-release `baseline-20261017` (8.6 MB, kept out of the tree);
- `baseline_galaxy_7c959b4.essentia.txt` — `tools/lab/baseline_check.py`'s
  table: per beat the level and the pitch clusters, the bar of silence,
  the triad's peaks, the release;
- `baseline_galaxy_7c959b4.essentia.json` — the same, as data;
- `baseline_galaxy_7c959b4.envelope.csv` — the level envelope, dBFS every
  50 ms, 45 s.

Because the LFOs are free-running, a build is compared on the shape (the
envelope, the per-beat levels) and the spectrum (the pitch classes, the
triad's peaks), not sample by sample.
