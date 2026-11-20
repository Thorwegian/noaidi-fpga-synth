# The benchmarks: the synth playing the lab's presets

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

One benchmark for each of the lab's baselines (`tools/lab/baselines.py`):
a recording of the baseline's preset playing the fixed sequence, kept here
as the WAV and its measurements, `baseline_<preset>_<commit>.*`, the commit
being the firmware's that played it. Each section says when its recording
was approved as the benchmark. The presets are the
files of `app/storage/Presets/Factory/Tests`, kept for the lab, and a
benchmark is valid for its file as it is there: after a change to one of
those files, re-record its benchmark in the same commit.

## Galaxy

The reference every build is judged against (issue #222; re-recorded for
#304 on 2026-10-25 and for #321 on 2026-10-28): `main` at `d03e915`, the
CSP's second revision with its RC envelopes and the #176 release law, the
48 kHz lab path through the half-band decimator (#320: flat to 20 kHz
where the pair average it replaced was 2 dB down), its own firmware and
preset storage, playing the Galaxy preset (a two-note arpeggio from
LFO 1 on the pitch, a tremolo from LFO 2 on the pulse width, both LFOs
free-running) through `tools/lab/baseline_recording.py`, the MIDI over BLE
(`--port 128:0`) — at 60 BPM, C5 … C6 as quarter notes, the C6 held a full
bar, a bar of silence, C4 E4 G4 held four beats and released, the release
recorded to its end — from the S/PDIF output, 48 kHz, 16-bit, stereo.

Its file is `app/storage/Presets/Factory/Tests/Galaxy.toml`, git blob
`716ffefd63d73b6203f37fc2600ab710d906aaa5`
(`git rev-parse HEAD:app/storage/Presets/Factory/Tests/Galaxy.toml` shows
today's): takes of that file pass every row against this benchmark.

The first benchmark, `main@7c959b4` of 2026-10-17 (the synth before the
CSP-as-processor work, the reference for the goal of sounding like before),
is lost: the GitHub pre-release it was put on was deleted and no copy
survives on either machine (#367). Its RC-less release fell faster, so its
tail no longer matched the instrument anyway.

**What the reference is.** The reference is the JSON and the CSV below:
`benchmark_compare.py` reads those two files and nothing else. The WAV they
were made from is `baseline_galaxy_d03e915.wav` in this folder (md5
`2b4d7e2044b11b66090ee45a45354615`; the JSON's `file` field names it): take
4 of the 2026-10-28 session, approved as the benchmark when Thor merged
PR #323 (merge `2409560`, 2026-10-28 22:44 +01:00). A file is the
benchmark if `baseline_check.py` on it reproduces this folder's JSON and CSV
exactly. After a change to the checker, remake the derived files from it
with the Essentia interpreter (`~/.noaidi-blenv/bin/python` on the lab box)
and commit them with the checker:

```
cd tools/lab/benchmark
~/.noaidi-blenv/bin/python ../baseline_check.py baseline_galaxy_d03e915.wav \
    --json baseline_galaxy_d03e915.essentia.json \
    --envelope baseline_galaxy_d03e915.envelope.csv \
    > baseline_galaxy_d03e915.essentia.txt
```

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
(take 4). The other four pass every row of the comparison against it
(envelope correlation 0.980–0.994); the row Galaxy's pitch arpeggio makes
marginal (#305), the B5 pitch-class share, reads 52–79 % on them against
the 33 % the check asks now that the share counts every cluster the
detector finds (#354: counted over the three largest only, one take read
32 %). A re-recording picks its take the same way.

## SawBass

`main` at `b158923`, the firmware built from it and the gateware the board
was running on 2026-11-20, playing the SawBass preset (the PowerBass with
one oscillator sounding: the `1+1` voice structure with the mix at
oscillator 1, a saw, through the 24 dB low-pass at 523 Hz with full key
tracking, the mod envelope bringing the cutoff down over 1.3 s, the
amplitude falling over 5.2 s to a sustain 60 dB down, both LFOs at no
depth) through the same sequence two octaves down: C3 … C4 as quarter
notes, the C4 held a full bar, a bar of silence, C2 E2 G2 held four beats
and released. The preset was loaded from the Tests bank by Bank Select
127/127 and Program Change 1 over the wired DIN input (the CH345,
`--port 16:0`), the recording is from the S/PDIF output, 48 kHz, 16-bit,
stereo, 29 s. Thor chose the sound by ear.

Its file is `app/storage/Presets/Factory/Tests/SawBass.toml`, git blob
`c676c519b9e8b688cc9d2b70cec38e540def130f`.

The reference is `baseline_sawbass_b158923.essentia.json` and
`baseline_sawbass_b158923.envelope.csv`, with the checker's table as
`baseline_sawbass_b158923.essentia.txt`. The WAV they were made from is
`baseline_sawbass_b158923.wav` in this folder (md5
`3f255bfe3217086ae5422abb430ca974`; the JSON's `file` field names it),
recorded on 2026-11-20 and approved as the benchmark when Thor merged
PR #516 (merge `07803b9`, 2026-11-20 01:13 +01:00). The files are
remade from it with the transposition the take was played at:

```
cd tools/lab/benchmark
~/.noaidi-blenv/bin/python ../baseline_check.py baseline_sawbass_b158923.wav --transpose -24 \
    --json baseline_sawbass_b158923.essentia.json \
    --envelope baseline_sawbass_b158923.envelope.csv \
    > baseline_sawbass_b158923.essentia.txt
```

What the take reads:

- every note of the scale at its pitch, by all of the confident frames; the
  triad's three notes within 2.9 dB of the spectrum's strongest line;
- the scale's notes at −24.1 to −24.3 dBFS over the middle of their beats,
  the held C4 at −35.4 dBFS over the middle of its bar, where the note has
  mostly decayed, the triad at −30.4 dBFS; the lead-in, the bar of silence
  and the release are digital silence, so the release's two rows say that
  nothing sounds and nothing more;
- valley floors of −87 to −99 dB: the low-pass leaves almost nothing
  between the harmonics above 300 Hz.

**Choosing the take, and what repeats.** Five takes were recorded. With one
oscillator nothing beats, and the takes agree within 0.05 dB on the level
of every note of the scale and of the held C4, within 0.2 dB on the
triad's, and within a mean of 0.12 dB on a note's partials; the 50 ms
envelopes differ by a median of 0.05 to 0.11 dB over the frames that
sound, and by up to 2.8 dB in the triad's attack. The benchmark is the
take whose first note sits on
the five takes' median (take 2); the other four pass every row of the
comparison against it. (Takes of the unison PowerBass, seven detuned saws
whose phases run free, differed by up to 5.5 dB on a note's level, which
is why the bass baseline is this preset.)

Two rows do not repeat on the scale's one-second notes: the valley floor
spans 3.7 to 11.0 dB across the five takes and the centroid 0.8 to 2.6
semitones, where on the held C4 and the triad they span 0.1 to 0.3 dB and
0.03 to 0.10 semitones. Both read what lies about 90 to 100 dB below the
strongest line, and what moves that floor on the short notes is not
known. The comparison therefore reads a valley floor no deeper than 80 dB
below the strongest line (`VALLEY_FLOOR` in `benchmark_compare.py`), which
leaves Galaxy's rows as they were (its floors are −45 to −78 dB) and makes
SawBass's row a test for a floor that rises above −74 dB. The centroid's
half octave holds the spread.

The checker's blind spot is in these files (`baseline_check.py`): a peak
below about 200 Hz can fall between two of its bins, and reads −240 dB. The
first half-fundamental partial of most notes reads so, and the D3's own
fundamental with it. A take is compared on the same blanks.
