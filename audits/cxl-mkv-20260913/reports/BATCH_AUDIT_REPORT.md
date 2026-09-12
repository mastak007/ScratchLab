# CXL MKV batch audit - stage report

Date 2026-09-13. Sources read only. All new output is under `claude-mkv-batch-audit/`.
Nothing in the dataset, the Baby pilot, the app source, the hand caches or the packaged
assets was modified. No commits, no pushes, no installs, no training.

**Scope completed so far:** library-wide inventory and grouping (all 119 titles), one
pipeline-claim re-verification, **four full technique audits** (`cutting_79bpm`,
`transformer_85bpm`, `reversecutting_79bpm`, `tears_98bpm`), and one cheap library-wide *screen*.
**19 techniques remain un-audited.**

---

## 1. A correction to the Baby pilot

The Baby report claimed the delivered exports "carry a second field the exports threw away".
**That claim is refuted.**

Both fields are present in the delivered MP4s, in the correct order. Splitting source and
delivered frames with `separatefields` (no interpolation) over 368 fields of
`baby_79bpm_angle_3_take01`:

| comparison | PSNR |
|---|---|
| delivered vs source, field parity 0 | **36.92 dB** |
| delivered vs source, field parity 1 | **36.92 dB** |
| what a dropped-and-duplicated field would score | 22.28 dB |
| what a field-order swap would score | 19.29 dB |

Within-frame field difference is 12.79 (delivered) against 13.00 (source), so the two fields
still genuinely differ, and `bwdif=mode=send_field` yields 368 = 2x184 field-rate frames
directly **from the delivered MP4**.

**Consequence:** 59.94p output does not require going back to the MKVs. Nothing temporal was
lost in the export; the only loss is H.264 coding fidelity (~36.9 dB per field). The case for
rebuilding from source now rests on duplicated material and audio/manifest problems, not on
lost fields. Evidence: `reports/stage-b-field-retention.json`.

---

## 2. Grouping - all 119 titles, by evidence

Three independent signals were combined: chapter-2 range, byte-identical decoded audio
excerpts, and edit-list chapter-2 matching. Filenames and duration alone decided nothing.

- **49 groups.** 22 multi-title groups cover exactly the 92 titles that have three audio
  streams, and account for all 23 edit-list techniques. 27 single-title groups are exactly the
  27 one-audio-stream titles.
- **Zero cross-group audio collisions** across all 119 titles, so the audio fingerprint is a
  clean discriminator.
- One group of 8 (`chapter2 = 35.035-83.450`) is shared by **baby** and **cutting**. The
  edit lists cannot separate them; the audio equality classes do, cleanly:
  `t00-t03` (baby) and `t04-t07` (cutting). Video matching agrees independently.
- **Every technique has three audio streams.** The 27 one-stream titles (`t60-t73`,
  `t106-t118`) match no edit list and are not any of the 23 techniques. Their content is
  unidentified and they were **not** audited.

**Camera angles were bound to titles by content**, not by filename order: each delivered
`angle_N_take01` was cross-correlated against every candidate title over a run of 134-150
consecutive frames. All 23 techniques resolved, at ZNCC 0.9999 with runner-up margins around
0.90. The ascending convention (`angle_1` = lowest title number) held everywhere it could be
tested - but it was *tested*, not assumed. Evidence: `inventory/stage-a-groups.json`,
`inventory/angle-binding.json`.

---

## 3. Technique audits completed

### cutting_79bpm - the missing angle is missing from the SOURCE

| angle | title |
|---|---|
| 1 | `Scratch_t04` |
| 2 | **absent** |
| 3 | `Scratch_t05` (identical to `Scratch_t06`) |
| 4 | `Scratch_t07` |

`Scratch_t05` and `Scratch_t06` produce an **identical decoded frame-hash sequence for all
2501 frames** (framemd5 sequence SHA-256 `264abbd6...`). The DVD carries the same camera view
twice. The delivered dataset ships only 3 angles for cutting because **the angle-2 view does
not exist in the source**. Nothing can recover it, and no rebuild should imply otherwise.

Everything else checks out: 2501 frames, monotonic PTS, all frames interlaced, `top_field_first`
0 on every frame, no pulldown, SAR 8:9, clean full decode, idet 1287 BFF / 0 TFF.

Audio roles **confirmed** and identical in order to Baby (`a0` withBeat, `a1` noBeat,
`a2` beatOnly): residual 49.72 dB below programme over chapter 2, correlation 0.999662.

> **Method note that matters for the remaining 21.** The same component test over the *full
> title* scores only -9.93 dB and would have been reported as "roles NOT confirmed". Narration
> sits on the mixed track alone, so the test must be run over the performance region only. The
> first run of this audit made exactly that mistake before it was caught.

Chapter 2 repeats at 726 frames / 24.2242 s (video 0.99885 vs adjacent 0.98612, random 0.87343;
isolated-scratch ncc 0.9846, 0.99993 after a 1-sample refinement). Delivered `take05-08`
duplicate `take01-04` on all three angles at ZNCC 0.9994-0.9998.

**No progressive A/V drift** - but note precisely what that means. The motion-envelope method
suggested 0/+6/+14 frames across start/middle/end, at a peak correlation of only 0.45-0.52 (Baby:
0.77-0.84), because a crossfader technique decouples hand motion from audio transients. The title's
own repeat settles it: the audio repeats at the video's 726-frame offset to within **1 sample
(0.02 ms)**, which rules out drift over that span.

**This is a relative measurement, not absolute synchronisation.** Comparing a title's audio repeat
period against its video repeat period constrains the two timelines against each other; a constant
absolute offset between picture and sound would be invisible to it. **No test in this audit
establishes absolute A/V sync for any technique.**

### transformer_85bpm - clean, and it generalises the repeat rule

All four angles present and distinct (`t36`-`t39`), no duplicate titles, 4239 frames each,
monotonic PTS, all interlaced BFF, no pulldown, SAR 8:9, clean decode. Audio byte-identical
across all four angles. Roles confirmed (-48.69 dB, correlation 0.999881; full-title -11.01 dB
again).

Chapter 2 spans 90.421 s and repeats at **1355 frames / 45.2118 s - almost exactly half of it**.
Baby and cutting repeat at 726 frames = half of their 48.415 s chapter 2. So the pattern is not
a fixed 24 s: **chapter 2 is its own first half, played twice**, whatever its length.

No A/V drift (audio repeats at the video offset within 2 samples / 0.042 ms), and the envelope
method again produced a spurious +9/+10/+13 frame reading at correlation 0.54-0.66.

### reversecutting_79bpm - the screen was wrong, for a measurable reason

All four angles present and distinct (`t08`-`t11`), 2156 frames each, monotonic PTS, every frame
interlaced with `top_field_first` 0, no pulldown, SAR 8:9, clean decode, idet 942 BFF / 0 TFF.
Audio byte-identical across all four angles; roles confirmed (-48.48 dB, correlation 0.999425).

Chapter 2 (48.4765 s) **is** a duplicated half at 726 frames / 24.2242 s:

| measurement | value | control |
|---|---|---|
| video, 360x240 similarity | 0.99854 | adjacent frame 0.98617, random pair 0.84511 |
| video, **full-resolution PSNR** frame(i) vs frame(i+726) | **35.59 dB** | consecutive frames 24.73 dB; 1.2 s apart 15.45 dB |
| isolated scratch, best fractional lag | **ncc 0.953-1.000, median 1.000** | next-best offset peak 0.045 |

**Why the screen said 0.812.** 726 frames = 726 x 1601.6 = **1,162,761.6 audio samples** - not a
whole number. Fixed integer-lag correlation therefore under-reports, and the best integer lag also
wanders about 2.2 samples (~45 microseconds) across the span, stepping from -0.96 to -3.13. At
fixed integer lag the per-window correlation ranges **-0.540 to 0.978**; at the correct fractional
lag it is **0.953 to 1.000**. The screen's verdict was a measurement artifact, not weak
duplication. Delivered `take05-08` duplicate `take01-04` on all four angles at ZNCC 0.9993-0.9998.

Narration runs 0.0-20.84 s against a chapter-2 start of 23.5235 s - **only 2.68 s of margin**.

### tears_98bpm - duplicated, but with a real 2.25 s anomaly

All four angles present and distinct (`t24`-`t27`), 3636 frames each, timing and field order clean,
audio byte-identical across angles, roles confirmed (-46.59 dB, correlation 0.99977).

Chapter 2 (78.333 s) repeats at **1175 frames / 39.2058 s**. The screen had assumed 1174 frames;
one frame of error dropped it to 0.897. Corrected, the isolated-scratch match is **0.9994**, and in
19 of 21 active one-second windows it is **exactly 1.000** - at two discrete lag plateaus, -2.92
samples before the gap and -5.08 after, which is itself evidence of a splice in the authored copy.

**The anomaly.** Two windows do not match. Across **56.25-58.50 s** (and its counterpart
**95.46-97.71 s**):

| | 53.0-56.0 s | **56.25-58.50 s** | 59.0-62.0 s | 62.25 s on |
|---|---|---|---|---|
| video similarity at +1175 | 0.9984-0.9992 | **0.9989-0.9993** | 0.9993 | 0.9991 |
| isolated-scratch ncc | 0.999 | **0.08-0.25** | 0.974-0.981 | 0.999-1.000 |

Controls: adjacent-frame video similarity 0.98801, random pair 0.87932.

**The picture stays duplicated while the scratch audio does not.** In that window the two passes
carry the same image and different sound, so at least one of them has picture and audio that do not
correspond. The cause is not determined - an authoring splice, a genuinely different performance of
that bar, or a defect are all consistent with the evidence, and the audit cannot say which pass is
faithful.

Independently, the mixed-track voice-band indicator fired inside chapter 2 exactly twice for this
technique - at 56.47-56.73 s and 95.67-95.93 s, both inside the divergent window and its
counterpart, with residual 87.4 and 44.5 against a codec floor of 13.55 (6.5x and 3.3x; known
speech reaches 9525). Weak on its own, but it points at the same place.

**Delivered segments affected: `take02` (52.870-62.700 s) and `take06` (92.077-101.901 s), on all
four angles - 8 clips.** Inspect these before using tears for any hand-motion/audio work.
Audition clip: `previews/tears_98bpm/tears_98bpm_INSIDE_chapter2_53.4to60.4s_Scratch_t26.mov`.

Narration runs in 9 fragmented stretches from 0.02 to 40.21 s against a chapter-2 start of
43.043 s - **2.83 s of margin**.

---

## 4. Library-wide duplication SCREEN - not an audit

One title per technique, isolated-scratch stream, first half of chapter 2 versus second half at
the half-offset with +-40 ms refinement:

- **21 of 23 techniques screen as "duplicated half likely"**, ncc **0.96 to 0.99993**.
- The 2 inconclusive results have since been **audited and both overturned**:
  `reversecutting_79bpm` (screen 0.812, actual **0.953-1.000**) and `tears_98bpm` (screen 0.897,
  actual **0.9994**). Both were lag-resolution artifacts, not weak duplication.

**The screen's error rate on the cases it flagged was 2 out of 2.** It under-reports whenever the
repeat offset is not a whole number of audio samples, and it is blind to a localised divergence -
`tears_98bpm` scores 1.000 in 19 of 21 windows and still conceals a 2.25 s stretch where the
picture duplicates and the audio does not. Treat screened-positive as a hypothesis only.

This is audio evidence on one title per technique. Video was confirmed to repeat at the same
offset only for baby, cutting and transformer (3 for 3). **Do not treat the other 20 as proven.**
Evidence: `reports/stage-d-duplication-screen.json`.

If it holds, roughly **half of every technique's exported segments are duplicates**, across the
whole delivered dataset - not a Baby-only problem.

---

## 5. Hum, hiss, clipping - measured, nothing applied

No filter was applied to anything in this audit. Baby's notch settings were **not** reused.

- **No clipping** on any stream of any audited title. Peaks: cutting -0.43/-4.45/-0.45 dBFS,
  transformer -0.35/-1.59/-1.60 dBFS. Zero full-scale samples.
- **Isolated-scratch streams carry mains hum.** The fundamental is *fitted* over 49-61 Hz, not
  assumed: cutting 59.98 Hz, transformer 60.01 Hz, harmonics -61 to -76 dBFS.
- **The music-bearing streams must not be notched.** Their fits land on 55.43 Hz (cutting) and
  58.57 Hz (transformer) at **-27.8 and -34.5 dBFS** - bass notes, not hum, and 30-40 dB louder
  than any real hum. Applying Baby's 60 Hz notch there would remove musical bass. Note that the
  mastering differs between techniques (a2 peak -0.45 vs -1.60 dBFS), so gain assumptions do not
  transfer either.

Any cleanup remains optional preview work *after* source and trim validation, per technique.

---

## 6. Talking boundaries - and why the evidence is weaker than it looks

| technique | narration (residual test) | chapter 2 starts | margin |
|---|---|---|---|
| cutting_79bpm | 0.0 - 23.02 s | 35.035 s | 12.0 s |
| transformer_85bpm | 0.0 - 47.10 s | 51.051 s | 3.95 s |

Residual peaks after the chapter-2 start are 63.0 and 120.4, against 9843 and 10217 during
known speech.

**Two honest caveats.**

1. Component subtraction cannot prove the *absence* of speech: voice present in two components
   cancels. It is evidence, not proof.
2. The independent per-stream voice-band indicator **failed as a check**. On the mixed track it
   found zero candidates *anywhere* - including the 0-23 s and 0-47 s stretches where narration
   certainly exists - because the music masks the loudness gate. Its silence inside chapter 2 is
   therefore **not** evidence of anything. On the isolated-scratch track it fired 9 and 20 times
   inside chapter 2, which are scratch transients, not speech.

So the boundary evidence for these two techniques rests on the residual test alone.
**Operator audition is PENDING** for both. Previews: `previews/cutting_79bpm/`,
`previews/transformer_85bpm/` (head and tail, mixed plus isolated-scratch tracks, source times
in the filenames).

Intentional scratch pauses were preserved everywhere; nothing was trimmed by silence removal.

---

## 7. Candidate rebuild plan - for review, not execution

1. **Settle the duplication first.** Run the full audit on the 19 remaining techniques. The two
   inconclusive ones are done and both were false alarms; the screen is now known to under-report,
   so a screened-positive verdict is not a finding.
2. **Keep the duplicates, mark them.** Do not delete. Record, per technique, the unique
   chapter-2 half plus a `duplicate_of` pointer for the repeated segments. Deleting would lose
   the authored structure, and the practice repeats are legitimate material - they just must not
   be counted as independent samples.
3. **Fix dataset grouping before any model work.** Angles and takes of one parent performance,
   and duplicate takes, must not be split across train/evaluation.
4. **Record absent angles explicitly.** `cutting` has three distinct camera views **in the
   inspected files**, not four, because `t05` and `t06` are frame-identical. The dataset should
   record that absence rather than silently shipping three angles. Note the limit of this claim:
   frame-identical titles show the angle-2 view is not present *here*. They do not show it never
   existed - it could survive on other media, another pressing, or an earlier master.
5. **Deinterlacing can proceed from either source.** Given section 1, correcting the delivered
   MP4s in place is a legitimate option; going back to the MKVs buys coding fidelity
   (~36.9 dB per field), not extra temporal information.
6. **Validate per technique before touching audio.** Stream roles were confirmed for baby,
   cutting and transformer, all in the same order - but with a test window that must be the
   performance region. Hum settings must be re-measured per technique.
7. **Identify the 27 unassigned titles** before anyone assumes the library is fully mapped.
8. **Run a fractional-lag repeat profile per technique, not just a whole-span score.** The
   `tears_98bpm` anomaly - same picture, different audio, for 2.25 s - is invisible to any single
   correlation number. If that pattern exists elsewhere it directly corrupts hand-motion/audio
   pairing, which is the one thing this dataset exists to teach.
9. **Establish absolute A/V sync separately.** Nothing measured so far constrains it. Every sync
   result in this audit is relative, across a title's own repeat.

**Do not bulk re-encode, re-trim, or change canonical or package data on the strength of this
report.** Two techniques are audited; twenty-one are screened at best.

---

## 8. What is verified, candidate, or awaiting a person

**Verified by measurement:** title grouping and angle binding for all 23 techniques; field
retention in the delivered exports; `cutting`'s `t05 == t06` frame-identity in the inspected files
and the resulting absent angle; repeat offsets, delivered-segment duplication, audio stream roles,
absence of clipping and mains-hum frequencies for **cutting, transformer, reversecutting and
tears**; absence of *progressive* A/V drift in all four; and the `tears_98bpm` picture/audio
divergence at 56.25-58.50 s.

**Candidate / screened only:** the duplicated half in the other 19 techniques; whether their video
repeats at the same offset; whether any other group contains two frame-identical titles; whether
any other technique hides a localised picture/audio divergence like `tears`.

**Not established anywhere:** absolute audio/video synchronisation. Every sync result here is
relative, measured across a title's own repeat, and cannot see a constant offset.

**Awaiting operator audition:** all talking boundaries, including Baby's, and the `tears_98bpm`
anomaly window.

---

## 9. Handoff status

A resumable runner now exists: `scripts/run_batch.py`. It orchestrates the existing per-technique
scripts rather than reimplementing them; `fractional_lag_repeat.py` and `repeat_profile.py` were
extended (independent offset discovery, fractional-lag windowed comparison, divergence detection,
atomic `--out`) rather than duplicated.

```sh
python3 scripts/run_batch.py --all      # the 19 pending techniques
```

Validated on `cutting_79bpm` from cached evidence, exit 0, writing only into
`reports/runner-validation/`. The validation confirmed the offset policy matters in practice:
cutting repeats at **726 frames while half its chapter is 725**, and the audio's independently
discovered offset agrees with the video-derived one to **0.029 ms**. The divergence detector's
negative control was clean (0 divergent spans, 24/24 video and 12/12 audio windows matching).

The validation also found and fixed two real defects in the runner - a classifier reading stored
artifacts instead of the recomputed ones, and a version-blind comparison that reported superseded
artifacts as a reproducibility failure.

**`tears_98bpm` take02 and take06 are queued for audiovisual review** in
`reports/REVIEW_QUEUE.json`, with both passes rendered for side-by-side audition. Both versions are
preserved; the evidence shows the passes differ and does not say which is faithful.

See `HANDOFF_TO_CODEX.md` for counts, paths, cache locations, dependencies, measurement pitfalls and
the outstanding operator checks. That file is on disk only - it has not been sent to anyone.

---

<!-- BEGIN GENERATED BATCH RESULTS -->

## 10. Batch results

**23 of 23 techniques classified.** 22 verified_duplicate_half, 1 verified_partial_repeat.

Full per-technique measurements: `reports/RESULTS_TABLE.md`.

### The repeat is real across the library, and its offset varies

Repeat offsets found so far span **548 to 1355 frames** (18.28 s to 45.21 s). **5** of the classified techniques repeat at an offset that is NOT half the chapter duration: baby_79bpm, clovertears_105bpm, cutting_79bpm, lazers_92bpm, tears_98bpm. The offset is searched per technique and cross-checked against an independently discovered audio offset; assuming half the chapter would have produced wrong answers.

### Picture/audio divergence

Techniques where the picture still duplicates but the isolated-scratch audio does not:

- **tears_98bpm** - first-pass spans [[56.043, 58.043]]

These are queued in `reports/REVIEW_QUEUE.json` (1 open). Both passes are preserved; the evidence does not say which is faithful.

### Source-level gaps

- **cutting_79bpm** - delivered angles missing: ['2']

- **baby_79bpm** - titles decoding to identical frames: t05+t06
- **cutting_79bpm** - titles decoding to identical frames: t05+t06

Note `baby` and `cutting` share a chapter-2 range and therefore one candidate group, so cutting's t05+t06 pair is reported under both. baby's own titles t00-t03 are distinct.

### Still not established, for any technique

- **Absolute audio/video synchronisation.** Every timing figure here is relative, measured across a title's own repeat. A constant offset between picture and sound would be invisible to it.
- **That any region is speech-free.** Component subtraction cannot prove absence, and the voice-band indicator has no sensitivity against a music bed. Every boundary still needs operator audition.

<!-- END GENERATED BATCH RESULTS -->
