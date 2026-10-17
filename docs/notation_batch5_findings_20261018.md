# Batch 5 and question-mark investigation — 18 October 2026

The chart is withholding some recorded movement because confidence is calculated from travel amplitude. This is separate from genuinely unobserved packet intervals. This batch investigated the cause and verified the existing installed candidate; it did not alter product code, decoder thresholds or stored projections.

## Causal findings

- `CaptureCore.swift:11976` assigns `min(0.95, 0.7 + abs(counterSteps)/1000)`. The projection cutoff in `ReferenceTake.swift:3466` is0.75. An otherwise accepted8–49step run can therefore lose its entire curve.
- Nine such records occur in saved80BPM, totalling1.394457seconds; seven in95BPM, totalling1.296394seconds. The read-only audit verifies stable route, monotonic packet counter deltas, valid timestamps, at least3packets, minimum80msduration and gaps no greater100ms in every confidence-only span. It matches saved confidences exactly. Example95BPM1.071275–1.214826s:46packets,−45steps, maximum spacing30.27ms, confidence0.745. This proves why software withheld the curve; it does not independently prove hand-motion ground truth.
- Separate raw gaps exceed100ms: four in80BPM, two in95BPM. Their exact consecutive packet indices/timestamps match the saved intervals. Silence does not establish a hold or prove whether hardware, transport or scheduling caused it.
- Separate noise-gate omissions:80BPM six discarded runs/four insufficient-sampling intervals;95BPM six/two. Their saved packet ranges fail duration/count/travel gates. They must not become invented stationary holds.
- `ReferenceAuthoringTake.tearProjection` returns a restored projection first (`ReferenceAuthoringSession.swift:1704`). Reopening historical evidence intentionally preserves its omissions. A future decoder change alone will not repair an old saved projection.
- The shared geometry excludes missing/invalid measured curves; `ScratchPhraseChartView.swift:361` labels narrow unknown bands `?`, wider ones `MOTION UNKNOWN`. The glyph is downstream of these causes.

## Installed combined check

Exact app: `/Applications/SL Capture Export Readability 2026-10-18.app`; executableSHA256 `cf4624aab3c2ffbafed7ad3276d781a64383a4f392f6922ef468e4674838f930`. Product/test/configuration sources match Batch4 snapshot `fbe0668d1367808ea47d8748ee6adde5d27ed4d9423c431b4d69000eb6490255`. Reused matching full9506XCTest/1064namedSwiftTesting/123Python/all-platform receipts; no unnecessary build or suite rerun.

A clearly labelled, unapproved80BPM review copy was created from the approved source; original approval/preference were removed only in that new copy. ID `ui-batch5-check-70ce77dc-896d-49ad-a679-c9417caa743f`. The user edited repetition2to9.75–23during the initial observation and explicitly confirmed doing so. That baseline is retained separately; do not attribute it to app instability. Controlled observations began after the user handed off the UI.

| Check | Result | Evidence / next action |
| --- | --- | --- |
| Playback cursor/readout and inspection | PASS, bounded | Clocks4.84→7.44s, cursor392.5→836px; visible viewport4.44–14.38s and seven visible static anchors unchanged. Inspect paused at8.60s and moved only selected panel pin to7.60–9.60s. Not continuous frame-pacing/audio proof. |
| Recorded travel / Movement detail / Sample position | PASS | Same full range, correct units/qualitative warnings, physical pin absent in Sample position and restored in Recorded travel. |
| Timeline body, in and out dragging | PASS | User baseline9.75–23→body10.25–23.5→in10.5–23.5→out10.5–23.25beats. Each expected snapped value persisted. |
| Save/reopen/export | PASS | Reopened10.50–23.25; actualZIP has15validated artifacts, three1600×1420PNGs, exact sourceMOV/WAV, rawsidecar, projection92records, sample playback and uncertainty. Draft only, no preferred repetition/approval. |
| Source preservation | PASS |59original registered files, six referenced media,10previous app executables, archives and protected untracked demo unchanged. New review copy is the only mutable item. |
| Accepted movement visibility | FAIL, unresolved |16confidence-only curves remain withheld. Next correction must address visibility versus eligibility without hiding true gaps. |
| Original recording-load / general frame pacing | NOT RUN | Saved review only. A5second actual ARM64 process sample is retained; initial sample overlapped manual edits, not a controlled benchmark. |
| Intel responsiveness | NOT RUN | One bounded same-build checklist prepared in externalINTEL-CHECK.md; run on the actualIntel Mac. |
| Physical Rane/audio and learner/operator acceptance | NOT RUN | No new capture, physical cue/cut/audio-alignment observation or user visual acceptance was performed. |

Bulk AX values/positions are read separately while readout text changes; they can misalign offscreen arrays. An initial all-array analysis failed and is documented. Assertions and screenshot pixel analysis are restricted to the visible selected panel. Do not promote those sampled anchors into a general no-jump guarantee.

## Next correction proposal

Keep recorded, qualified telemetry visible independently of canonical classification/comparison confidence. Use the existing raw-packet decoder/trajectory and explicit uncertainty; retain low-confidence ineligibility for comparison/training and preserve packet/clock/route gaps and rejected-run provenance. Do not globally lower confidence thresholds, draw connectors over unobserved intervals, invent holds, or silently rewrite approved/stored projections. Historical takes need an explicit separately derived review. Establish the minimal source/eligibility boundary and an actual-capture failing regression before implementing.

Suggested continuation prompt:

> Implement the confidence-only visibility correction described in this report. First audit the existing derived-review and eligibility paths. Use the saved80/95BPM fixtures and exact16interval audit; preserve original evidence and canonical eligibility. Show supported raw movement with explicit uncertainty using the existing decoder and shared geometry, retain genuine gaps, and provide a separately derived review for saved historical omissions. No global confidence-threshold change or silent approved-data rewrite. Add a focused actual-capture regression before product edits; group the repair before required shared/full verification, signed installation and one bounded live check. Reuse unaffected receipts and stop downstream on required failures.

Durable evidence: `/Users/karlwatson/ScratchLab-Local-Evidence/2026-10-18/batch5-gap-audit`. Key files: `GAP-CAUSAL-AUDIT.json`, `CONFIDENCE-ONLY-GAPS.csv`, `CONTROLLED-PLAYBACK-RECEIPT.json`, `TIMELINE-DRAG-RECEIPT.json`, `LIVE-EXPORT-RECEIPT.json`, `FINAL-PRESERVATION.json`, `REUSED-SOFTWARE-RECEIPTS.json`, `PROCESS-SAMPLE-OBSERVATION.json`, `ACCEPTANCE-MATRIX.json`, `INTEL-CHECK.md`, original baseline backups, scripts and nativeUI screenshots. Git checkpoint/push identity is recorded separately in `GIT-RECEIPT.json`.
