# The benchmark: the synth on its second CSP revision, playing Galaxy

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

The reference every build is judged against (issue #222; re-recorded for
#304 on 2026-10-25 and for #321 on 2026-10-28): `main` at `d03e915`, the
CSP's second revision with its RC envelopes and the #176 release law, the
48 kHz lab path through the half-band decimator (#320: flat to 20 kHz
where the pair average it replaced was 2 dB down), its own firmware and
preset storage, playing the Galaxy preset (Factory bank program 1: a two-note arpeggio from
LFO 1 on the pitch, a tremolo from LFO 2 on the pulse width, both LFOs
free-running) through `tools/lab/baseline_recording.py`, the MIDI over BLE
(`--port 128:0`) — at 60 BPM, C5 … C6 as quarter notes, the C6 held a full
bar, a bar of silence, C4 E4 G4 held four beats and released, the release
recorded to its end — from the S/PDIF output, 48 kHz, 16-bit, stereo.

> **Galaxy is a work in progress, not a fixture (#305).** It is a Factory
> preset that is still being voiced on the bench. This benchmark is valid
> only for the file it was recorded with,
> `app/storage/Presets/Factory/Pads/Galaxy.toml` at git blob
> `621fbf545a99671677887d50c93e5196ec3d0025` (`git rev-parse HEAD:app/storage/Presets/Factory/Pads/Galaxy.toml`
> shows today's). After a change to that file, a failed comparison may be the
> preset, not the synth: re-record the benchmark in the same commit.

The first benchmark, `main@7c959b4` of 2026-10-17 (the synth before the
CSP-as-processor work, the reference for the goal of sounding like before),
stays on the GitHub pre-release `baseline-20261017` as
`baseline_galaxy_d03e915.wav` and `.m4a`; its RC-less release fell faster,
so its tail no longer matches the instrument.

- the recording: `baseline_galaxy_d03e915.mp3` (320 kbps) at
  https://thj.no/synth-claude-uploads/, linked from #321; the WAV is kept on
  the lab computer, out of the tree;
- `baseline_galaxy_d03e915.essentia.txt` — `tools/lab/baseline_check.py`'s
  table: per beat the level and the pitch clusters, the bar of silence,
  the triad's peaks, the release;
- `baseline_galaxy_d03e915.essentia.json` — every measurement behind it:
  per segment the level, the pitch clusters, the spectral centroid, the
  valley floor (the level between the harmonics, 300–8000 Hz, the test
  for a gritty sound: −45 to −78 dB below the strongest line on this
  take), the expected notes' peaks and a single note's first sixteen
  partials (an exception in `.gitignore` keeps it in the tree, where
  `*.json` is otherwise the flow's output);
- `baseline_galaxy_d03e915.envelope.csv` — the level envelope, dBFS every
  50 ms, 29 s.

Because the LFOs are free-running, a build is compared on the shape (the
envelope, the per-beat levels) and the spectrum (the pitch classes, the
centroid, the partials, the triad's peaks), not sample by sample:
`tools/lab/benchmark_compare.py <take.wav>` measures a take the same way
and puts every number against this folder's, with tolerances for the
tremolo's phase (3 dB on a sounding segment's level, 6 dB on a quiet
one, half an octave on the centroid, a mean of 6 dB over the partials,
0.9 on the envelope's correlation); `--plot` draws the envelopes and the
held C6's partials. A take has to pass both the check and the comparison
before anyone listens to it.

**Choosing the take.** Five takes were recorded on 2026-10-28 through the
half-band path. Every segment's level stays within 1.5 dB across them,
except the first note of the scale, which spans 2.1 dB: where the
free-running LFOs stand when the first note starts decides it. The
benchmark is the take whose first note sits on the five takes' median
(take 4). Three of the other four pass every row of the comparison
against it (envelope correlation 0.980–0.994); the fifth misses one row by
one point, the B5 pitch-class share at 32 % against the 33 % the check
asks, the row Galaxy's pitch arpeggio makes marginal (#305). A re-recording
picks its take the same way.
