# Handoff - CXL MKV batch audit

**Last update: 2026-09-13T04:53:24**  |  state: COMPLETE - all 23 techniques audited. 22 verified_duplicate_half, 1 verified_partial_repeat (tears). 0 inconclusive, 0 failed.

Techniques: **23 complete**, 0 partial, 0 pending, 0 blocked, out of 23.

## Objective

Audit the remaining techniques in `/Volumes/Untitled/CXLrip` for the classes of problem found in
the Baby pilot, BEFORE any bulk re-encode or trim. Produce an audit and a candidate rebuild plan.
Do not rebuild the library or change canonical/package data.

## Protected paths - read only

- `/Volumes/Untitled/CXLrip`
- `/Users/karlwatson/Movies/PRO DJ DATASET/dataset`
- `/Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/evidence/mkv-source-inspection-20260913/claude-baby-pilot`
- `/Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/evidence/mkv-source-inspection-20260913/audio-comparison`
- `/Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/evidence/mkv-source-inspection-20260913/probe`
- `/Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/source`

No app or database changes, no training, no installs, no commits, no pushes.

## All new output goes here

`/Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/evidence/mkv-source-inspection-20260913/claude-mkv-batch-audit`

## Usage monitoring

- plan-usage data available: **False**
- No reliable plan-usage window data is exposed to this session. Only an informational session dollar figure is visible, which is not a plan-usage percentage. Per the task instructions, this turn is capped at TWO techniques after the inventory stage.

## Stages

- **A_inventory_grouping**: complete - 119 titles -> 49 chapter groups: 22 multi-title groups covering all 92 three-audio-stream titles and all 23 edit-list techniques, plus 27 single-title groups that are exactly the 27 one-audio-stream titles and match no edit list. Zero cross-group audio collisions. Evidence: inventory/stage-a-groups.json, inventory/angle-binding.json
- **B_pipeline_claim_checks**: complete - Baby's 'second field discarded' claim tested and REFUTED. reports/stage-b-field-retention.json
- **C_per_technique_audit**: complete - 23 of 23 audited under the current analysis version.
- **D_duplication_screen**: complete - Audio-only SCREEN, one title per technique. 21/23 screen as duplicated-half likely (ncc 0.96-0.99993); reversecutting_79bpm (0.812) and tears_98bpm (0.897) inconclusive. NOT a substitute for the per-technique audit. reports/stage-d-duplication-screen.json
- **E_runner**: complete - scripts/run_batch.py orchestrates the existing per-technique scripts; fractional_lag_repeat.py and repeat_profile.py were EXTENDED (independent offset discovery, fractional-lag windowed comparison, divergence detection, atomic --out) rather than duplicated. Validated on cutting_79bpm from cache: exit 0.
- **F_consolidation**: complete - reports/REVIEW_QUEUE.json consolidated (1 open item), reports/manifest-consistency.json refreshed, reports/RESULTS_TABLE.md and reports/BATCH_AUDIT_REPORT.md regenerated.

## Corrections to prior evidence (important)

- **Baby pilot REPORT.md: 'The originals carry a second field the exports threw away.'**
  - verdict: REFUTED. Both fields are present in the delivered MP4s, in the correct order.
  - evidence: separatefields on both sides, 368 fields of baby angle_3 take01: PSNR 36.92 dB (parity 0) and 36.92 dB (parity 1) against the source fields. A dropped-and-duplicated field would score 22.28 dB; a field-order swap 19.29 dB. Within-frame field difference 12.79 (delivered) vs 13.00 (source), so the two fields still genuinely differ. bwdif send_field yields 368 = 2x184 field-rate frames directly FROM the delivered MP4. reports/stage-b-field-retention.json
  - consequence: Field-rate 59.94p output does NOT require returning to the MKVs; it can be produced from the delivered exports. The only loss in the exports is H.264 coding fidelity (~36.9 dB per field). The case for rebuilding Baby from source now rests on the duplicated second pass and the missing/mislinked audio, not on lost fields.

## Counts

| state | n |
|---|---:|
| verified (fully audited) | 23 |
| pending (screened only, not audited) | 0 |
| inconclusive | 0 |
| failed | 0 |
| **total** | **23** |

Counts come straight from batch-state.json. 'pending' means not yet run by the runner; the cheap screen is a hypothesis, not a finding.

## The command to process the remaining techniques

```sh
cd /Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/evidence/mkv-source-inspection-20260913/claude-mkv-batch-audit
export BATCH_SCRATCH=/tmp/cxl-batch      # or any durable dir; see Cache below
python3 scripts/run_batch.py --list      # what is pending
python3 scripts/run_batch.py --all       # process all pending, checkpointing as it goes
python3 scripts/run_batch.py --all --limit 3        # smaller batches
python3 scripts/run_batch.py --only <key>           # a single technique
python3 scripts/run_batch.py --validate <key>       # re-derive one from cache and compare
```

State is written to `batch-state.json` after every step. `progress.json` stays the human-facing summary.

**Result vocabulary** (kept distinct on purpose):

- `verified_duplicate_half` - repeat found and confirmed in BOTH video and audio
- `verified_partial_repeat` - repeat confirmed but with divergent spans inside it (the tears signature)
- `verified_no_repeat` - searched, none found
- `inconclusive` - evidence conflicts or falls below thresholds - never treated as a negative result
- `failed` - a step errored; partial results preserved and NOT marked complete
- `screened_only` - not audited; the cheap screen is a hypothesis, not a finding

**Skip rule.** A technique is skipped only when state starts with 'verified' AND its fingerprint matches: source file sizes and mtimes, SHA-256 of all six scripts, runner version, and the analysis parameters. Any change re-runs it.

**Offset policy.** The repeat offset is SEARCHED by audit_technique.py over all offsets, then cross-checked against an independently discovered audio offset (fractional_lag_repeat --discover). Half the chapter duration is recorded for comparison only and is never assumed. cutting_79bpm proves the point: searched 726 frames, half-chapter 725.

**Failure handling.** The record is written before work starts with state=failed, and only upgraded after classification. A crash or interruption therefore leaves 'failed' plus a step log, never a false 'complete'.

## Artifacts from the earlier analysis version

The four techniques audited earlier were produced under an earlier analysis version. Their FINDINGS stand - they were each checked by hand - but their .fractional-lag.json artifacts predate the widened lag search, and only reversecutting has a .repeat-profile.json. Re-running them under the runner is cheap with warm caches and would make the evidence set consistent.

```sh
python3 scripts/run_batch.py --only cutting_79bpm transformer_85bpm reversecutting_79bpm tears_98bpm
```

## Paths

| what | where |
|---|---|
| original MKVs (read only) | `/Volumes/Untitled/CXLrip` |
| current dataset (read only) | `/Users/karlwatson/Movies/PRO DJ DATASET/dataset` |
| all new output | `/Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/evidence/mkv-source-inspection-20260913/claude-mkv-batch-audit` |
| scripts | `<output>/scripts/` |
| per-technique evidence | `<output>/techniques/<key>*.json` |
| previews for audition | `<output>/previews/<key>/` |
| reports | `<output>/reports/` |
| runner state | `<output>/batch-state.json` |
| review queue | `<output>/reports/REVIEW_QUEUE.json` |
| decode cache | `$BATCH_SCRATCH` |

Cache used so far: `/private/tmp/claude-501/-Users-karlwatson-Developer-ScratchLab-CXL-Ready-20260913-evidence-mkv-source-inspection-20260913/63286248-ced4-4649-8945-717a8c57e505/scratchpad/batch`

That path is session-scoped and may be cleared. If it is gone the scripts re-decode from the original MKVs automatically - slower, same results. Set BATCH_SCRATCH to any durable directory.

Cache subdirectories:

- `pcm/` - full-length decoded audio, s16le 48 kHz stereo, <title>-a<N>.s16le
- `grayfull/` - full-length 360x240 grayscale video, <title>.gray
- `gray/` - short grayscale windows used by angle binding
- `clip/` - grayscale of delivered dataset MP4s
- `framemd5/` - per-frame MD5 of decoded video, for exact title-duplicate tests
- `fields/` - separatefields output for the field-retention check
- `fullres/` - 720x480 grayscale windows for full-resolution PSNR

roughly 200-400 MB of cache per technique (4 titles).

## Dependencies

- Python 3.14.2, numpy 2.3.5
- ffmpeg version 8.1.1 Copyright (c) 2000-2026 the FFmpeg developers
- This ffmpeg build has NO drawtext filter, so previews carry no burnt-in timecode; source time is encoded in each preview filename instead.

## Runner validation result

Validated on **cutting_79bpm** (--validate, cached evidence only, exit 0), writing only into `reports/runner-validation/ (stored evidence untouched)`.

- `cache_present`: PASS
- `fractional_lag_ran`: PASS
- `repeat_profile_ran`: PASS
- `reproduces_stored_numbers`: SKIPPED - stored file was produced by (none - predates versioning), the current analysis is fractional_lag_repeat/2. Differing numbers here are an expected consequence of the widened lag search, not a reproducibility failure. Re-run this technique to refresh its artifacts.
- `detects_superseded_artifacts`: PASS
- `classifier_produced_a_distinct_state`: PASS

**Offset check:** searched 726 frames, half-chapter 725 frames, equal: False. cutting does NOT repeat at exactly half its chapter duration; the runner uses the searched offset and flags the difference.

**Independent offset agreement:** the audio's own discovered offset differs from the video-derived one by 0.029 ms.

**Divergence detector, negative control:** {'divergence_detected': False, 'video_windows_matching': 24, 'audio_windows_matching': '12 of 12 evaluated', 'controls': {'adjacent_frame_similarity': 0.98542, 'random_pair_similarity': 0.84796}}

**Classifier output:** verified_duplicate_half - video and audio both repeat at 726 frames

The validation found and fixed two real problems:

- The classifier was reading stored artifacts instead of the validation's own recomputed ones; it now takes a derived_dir.
- Comparison against stored numbers is now analysis-version aware. cutting's stored fractional-lag file predates the widened lag search, so its numbers legitimately differ; this is reported as SUPERSEDED, not as a reproducibility failure.

**Not exercised:** The divergence detector's POSITIVE case was not re-run here; it is evidenced by tears_98bpm (see reports/REVIEW_QUEUE.json). A full end-to-end run including audit_technique.py on a fresh technique has not been executed.

## What these measurements cannot establish

- **Correlation cannot establish absolute audio/video synchronisation.** Every timing result in this audit is RELATIVE - a title's audio repeat period against its own video repeat period. That rules out progressive drift across the repeated span and nothing more. A constant offset between picture and sound is invisible to it. Establishing absolute sync needs a different instrument.
- **Correlation cannot prove a region is speech-free.** Component subtraction (withBeat - noBeat - beatOnly) isolates content unique to the mixed track, but voice present in two components cancels. The per-stream voice-band indicator has essentially no sensitivity against a music bed - it missed known narration entirely in cutting, transformer and reversecutting. Boundary claims are evidence plus audition, never measurement alone.
- **A whole-span correlation score hides localised divergence.** tears_98bpm scores 1.000 in 19 of 21 windows and still conceals 2.25 s where the picture duplicates and the audio does not. Only the windowed profile finds it.
- **A repeat offset is not necessarily half the chapter.** cutting_79bpm repeats at 726 frames while half its chapter is 725. The offset is searched, then cross-checked against an independently discovered audio offset; the half-chapter value is recorded for comparison only.
- **Frame-identical titles show an angle is absent from THESE files.** cutting's t05 and t06 are frame-identical, so the angle-2 view is not in the inspected source. That is not evidence it never existed - it may survive on other media, another pressing, or an earlier master.
- **The cheap screen under-reports.** Of the two techniques it flagged inconclusive, both were false alarms from lag-resolution artifacts. A screened-positive verdict is a hypothesis, not a finding.
- **The motion-envelope A/V sync method is unreliable** outside Baby: it produced spurious multi-frame drift on three of four techniques at peak correlations of 0.31-0.66. Its numbers are retained in the per-technique JSON but should not be quoted as sync measurements.

## Audiovisual review queue

`reports/REVIEW_QUEUE.json` - 1 open item.

tears_98bpm take02 and take06, all four angles (8 delivered clips). Source ranges 56.25-58.50 s (first pass) and 95.456-97.706 s (second pass). Both versions preserved; the evidence does not say which pass is faithful.

## Technique status

| technique | state | source titles | headline finding | evidence |
|---|---|---|---|---|
| 1clickflare_85bpm | complete | t44,t45,t46,t47 | verified_duplicate_half; offset 1355 fr; audio ncc median 0.9999 | techniques/1clickflare_85bpm*.json, previews/1clickflare_85bpm/ |
| baby_79bpm | complete | t00,t01,t02,t03 | verified_duplicate_half; offset 726 fr (NOT half-chapter); audio ncc median 0.9999; identical titles [['Scratch_t05', 'Scratch_t06']] | techniques/baby_79bpm*.json, previews/baby_79bpm/ |
| chirpflare_92bpm | complete | t52,t53,t54,t55 | verified_duplicate_half; offset 1249 fr; audio ncc median 0.9999 | techniques/chirpflare_92bpm*.json, previews/chirpflare_92bpm/ |
| chirps_98bpm | complete | t20,t21,t22,t23 | verified_duplicate_half; offset 588 fr; audio ncc median 0.9999 | techniques/chirps_98bpm*.json, previews/chirps_98bpm/ |
| clovertears_105bpm | complete | t74,t75,t76,t77 | verified_duplicate_half; offset 549 fr (NOT half-chapter); audio ncc median 0.99995 | techniques/clovertears_105bpm*.json, previews/clovertears_105bpm/ |
| crabs_92bpm | complete | t102,t103,t104,t105 | verified_duplicate_half; offset 1249 fr; audio ncc median 1.0 | techniques/crabs_92bpm*.json, previews/crabs_92bpm/ |
| cresentflare_92bpm | complete | t48,t49,t50,t51 | verified_duplicate_half; offset 1249 fr; audio ncc median 0.9999 | techniques/cresentflare_92bpm*.json, previews/cresentflare_92bpm/ |
| cutting_79bpm | complete | t04,t05,t07 | verified_duplicate_half; offset 726 fr (NOT half-chapter); audio ncc median 1.0; missing angles ['2']; identical titles [['Scratch_t05', 'Scratch_t06']] | techniques/cutting_79bpm*.json, previews/cutting_79bpm/ |
| dicing_85bpm | complete | t40,t41,t42,t43 | verified_duplicate_half; offset 1355 fr; audio ncc median 0.9999 | techniques/dicing_85bpm*.json, previews/dicing_85bpm/ |
| drags_98bpm | complete | t16,t17,t18,t19 | verified_duplicate_half; offset 1175 fr; audio ncc median 0.9999 | techniques/drags_98bpm*.json, previews/drags_98bpm/ |
| lazers_92bpm | complete | t56,t57,t58,t59 | verified_duplicate_half; offset 624 fr (NOT half-chapter); audio ncc median 0.9999 | techniques/lazers_92bpm*.json, previews/lazers_92bpm/ |
| long_short_tips_105bpm | complete | t32,t33,t34,t35 | verified_duplicate_half; offset 1097 fr; audio ncc median 0.9998 | techniques/long_short_tips_105bpm*.json, previews/long_short_tips_105bpm/ |
| marches_79bpm | complete | t12,t13,t14,t15 | verified_duplicate_half; offset 726 fr; audio ncc median 0.9999 | techniques/marches_79bpm*.json, previews/marches_79bpm/ |
| needledropping_105bpm | complete | t78,t79,t80,t81 | verified_duplicate_half; offset 823 fr; audio ncc median 0.9999 | techniques/needledropping_105bpm*.json, previews/needledropping_105bpm/ |
| orbits_85bpm | complete | t100,t101,t98,t99 | verified_duplicate_half; offset 1016 fr; audio ncc median 1.0 | techniques/orbits_85bpm*.json, previews/orbits_85bpm/ |
| originalflare_85bpm | complete | t94,t95,t96,t97 | verified_duplicate_half; offset 1016 fr; audio ncc median 1.0 | techniques/originalflare_85bpm*.json, previews/originalflare_85bpm/ |
| reversecutting_79bpm | complete | t08,t09,t10,t11 | verified_duplicate_half; offset 726 fr; audio ncc median 0.99965 | techniques/reversecutting_79bpm*.json, previews/reversecutting_79bpm/ |
| swipes_105bpm | complete | t90,t91,t92,t93 | verified_duplicate_half; offset 548 fr; audio ncc median 0.9999 | techniques/swipes_105bpm*.json, previews/swipes_105bpm/ |
| tears_98bpm | complete | t24,t25,t26,t27 | verified_partial_repeat; offset 1175 fr (NOT half-chapter); audio ncc median 0.9999; DIVERGENCE [[56.043, 58.043]] | techniques/tears_98bpm*.json, previews/tears_98bpm/ |
| tips_105bpm | complete | t28,t29,t30,t31 | verified_duplicate_half; offset 548 fr; audio ncc median 0.99975 | techniques/tips_105bpm*.json, previews/tips_105bpm/ |
| transformer_85bpm | complete | t36,t37,t38,t39 | verified_duplicate_half; offset 1355 fr; audio ncc median 1.0 | techniques/transformer_85bpm*.json, previews/transformer_85bpm/ |
| waves_105bpm | complete | t86,t87,t88,t89 | verified_duplicate_half; offset 1097 fr; audio ncc median 0.9999 | techniques/waves_105bpm*.json, previews/waves_105bpm/ |
| zigzags_105bpm | complete | t82,t83,t84,t85 | verified_duplicate_half; offset 548 fr; audio ncc median 0.9998 | techniques/zigzags_105bpm*.json, previews/zigzags_105bpm/ |

## Pending operator checks

- PRIORITY - tears_98bpm audiovisual review: reports/REVIEW_QUEUE.json. Compare previews/tears_98bpm/tears_98bpm_INSIDE_chapter2_53.4to60.4s_Scratch_t26.mov (first pass) against tears_98bpm_SECONDPASS_92.6to99.6s_Scratch_t26.mov (second pass). Same picture, different sound, ~2.25 s. Affects delivered take02 and take06 on all four angles, 8 clips. PRESERVE BOTH VERSIONS - the evidence does not say which pass is faithful.
- Talking boundaries for every technique remain unaudited by ear. Margins are tight: reversecutting 2.68 s, tears 2.83 s, transformer 3.95 s, cutting 12.0 s. Baby's is still pending from the pilot.
- Absolute audio/video synchronisation is not established for any technique and needs a separate method (a clap, a slate, or a known transient with a visible cause).
- cutting_79bpm: accept that the angle-2 view is absent from the inspected files, and decide whether the dataset should record that absence explicitly.
- Policy for duplicated take05-08 across the library: tag as duplicate_of take01-04 rather than delete.

## Unresolved / open questions

- 19 of 23 techniques remain SCREENED ONLY. The screen is now known to under-report: it produced two false 'inconclusive' verdicts out of two, both from lag-resolution artifacts, and it cannot see a localised divergence like the one found in tears. Screened-positive is not audited.
- The tears video/audio mismatch at 56.25-58.50 s has no determined cause, and it is unknown whether any other technique has a similar localised divergence. Only a per-technique fractional-lag profile would reveal one.
- Absolute audio/video synchronisation is NOT established for any technique. Every sync result so far is a RELATIVE measurement across a title's own repeat, which cannot see a constant offset. The motion-envelope method is too weak to settle it (peak correlation 0.31-0.66 outside Baby).
- cutting_79bpm angle_2: t05 and t06 are frame-identical in THESE files, so the angle-2 view is absent from the inspected source. That does not prove the camera view never existed - it may exist on other media, another disc, or an earlier master. It is absent here, nothing stronger.
- The 27 one-audio-stream titles (t60-t73, t106-t118) match no edit list and remain unidentified.
- The per-stream voice-band speech indicator has essentially no sensitivity against a music bed: it missed known narration entirely in cutting, transformer and reversecutting. Boundary conclusions rest on component subtraction plus audition, and component subtraction cannot prove absence of speech.

## Scripts and how to run them

```sh
cd /Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/evidence/mkv-source-inspection-20260913/claude-mkv-batch-audit
export BATCH_SCRATCH=/tmp/cxl-batch     # any scratch dir; caches decoded grayscale/PCM
python3 scripts/stage_a_inventory.py        # groups (cached, safe to rerun)
python3 scripts/stage_a2_angle_binding.py   # angle<->title binding (resumable, skips done)
python3 scripts/stage_b_field_retention.py  # field-retention claim check
python3 scripts/stage_d_duplication_screen.py # cheap library-wide screen (under-reports; see below)
python3 scripts/audit_technique.py <technique_key>       # full audit of one technique
python3 scripts/fractional_lag_repeat.py <key> <title> <ch2start> <ch2end> <offset_frames>
python3 scripts/repeat_profile.py <technique_key>        # localise where a repeat holds/breaks
python3 scripts/drift_crosscheck.py <technique_key>      # relative A/V timing across the repeat
python3 scripts/make_boundary_previews.py <technique_key>
```

**Measurement pitfalls already paid for - do not repeat them:**

- A repeat of N video frames lands at `N*1601.6` audio samples. That is fractional unless N is a
  multiple of 5, so fixed integer-lag correlation UNDER-REPORTS the match. Both screen-inconclusive
  techniques were false alarms from exactly this. Use `fractional_lag_repeat.py`.
- The best lag can also step by a few samples along a span (splices in the authored duplicate).
  Search a window of at least +-32 samples, and check whether the result saturates at the bound.
- The component role test must be run over the performance region only. Over the full title it reads
  -9 to -11 dB and looks like a failure, because narration sits on the mixed track alone.
- The motion-envelope A/V sync method produced spurious multi-frame drift on three of four techniques.
- A whole-span correlation number cannot see a localised divergence. `tears_98bpm` scores 1.000 in 19
  of 21 windows and still hides a 2.25 s stretch where picture duplicates and audio does not.
```sh
# (block re-opened so the fenced section below stays valid)
```

## Resume command

```sh
cd /Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/evidence/mkv-source-inspection-20260913/claude-mkv-batch-audit && cat progress.json
# then run: Nothing pending in the audit. Operator actions are in 'Pending operator checks'. To re-verify any technique: python3 scripts/run_batch.py --only <key>  (it re-runs only if the fingerprint changed).
```

## Next exact operation

Nothing pending in the audit. Operator actions are in 'Pending operator checks'. To re-verify any technique: python3 scripts/run_batch.py --only <key>  (it re-runs only if the fingerprint changed).

## Note

This handoff was written to disk. It has NOT been sent to Codex or anyone else.
