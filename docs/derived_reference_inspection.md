# Offline derived reference inspection v1

Shipping policy update, 26 September 2026: archival media is offline research
only. Reference Examples playback/navigation and archival demo export are
de-scoped. Practice Watch uses bounded, non-audio LaneClock time over the existing
canonical Baby pattern; Listen is unavailable. No derived-inspection runtime
consumer or canonical conversion was added. Source assets and research schemas
remain offline; removing app resource membership does not delete them. See
Build/shipping-media-descope-20260926/RESULT.md for the final verification status.
The later historical paragraphs describing older playback paths as untouched
apply to the previous slice, not the current shipping policy.

This document records the 26 September 2026 read-only Developer-directory audit
and the approved, bounded Swift inspection contract. No media pipeline was run
or changed. No external files were modified. Audit findings below are from code,
stored reports, schemas and file inventories, not a new media-quality evaluation.

## Existing pipeline inventory

Paths below are relative to `/Users/karlwatson/Developer` unless stated otherwise.

| Folder | Relevant tooling and artifacts found |
| --- | --- |
| `ScratchLab-CXL-Final-Capture-Fixes-20260913/source` | Canonical source for this task. `scripts/dataset_processor/ingest_media_scratch.py`, `process_dataset.py`, `label_clip.py`, `validate_training_manifest.py`, `build_coach_demo_audio.py`, `evaluate_classifier.py`, `extract_youtube_baby_candidates.py`, README and SEGMENTATION_PLAN. `scripts/rebuild_reference_library.py`, `prepare_reference_examples.py`, `check_reference_metadata.py`, `extract_baby_scratch_strokes.py`; corresponding dataset/training/rebuild/prepare/metadata tests. Capture-session `rename_files.py`, `validate_session.py`, `capture_pipeline_common.py`, `test_capture_pipeline.py`. `Tools/Fixtures/click_to_platter_timeline.py`, `click_baby_platter.py`, and `Tools/ScratchNotation` are adjacent manual/notation workflows, not DVD ingest. |
| `ScratchLab-CXL-Ready-20260913/evidence/mkv-source-inspection-20260913` | `inspect_mkv.py`, inventory/probe/summary records, `deinterlace-trial/trial.py`, `audio-comparison/inspect_baby_audio.py`, `refine_baby_audio.py`, reports and source-mapping preview. |
| Same root, `claude-baby-pilot/scripts` | `match_angles.py`, `av_sync.py`, `analyze_audio.py`, `repeat_check.py`, `duplicate_takes.py`, `repeat_extent.py`, `voice_boundary.py`, `verify_previews.py`, `self_similarity.py`, `half_repeat.py`, `speech_residual.py`, `audio_noise_analysis.py`, `hum_refine.py`, `hum_frequency_fit.py`, `verify_audio_outputs.py`, `build_original_derived.sh`, `build_quad_review.sh`, `build_manifest.py`. Source/angle/audio/chapter/trim manifest and pilot report. Hum experiments are optional pilot derivatives, not the current library's audio contract. |
| Same root, `claude-mkv-batch-audit/scripts` | `stage_a_inventory.py`, `stage_a2_angle_binding.py`, `stage_b_field_retention.py`, `stage_d_duplication_screen.py`, `audit_technique.py`, `fractional_lag_repeat.py`, `repeat_profile.py`, `drift_crosscheck.py`, `run_batch.py`, `checkpoint.py`, `manifest_consistency.py`, `consolidate_review_queue.py`, `make_boundary_previews.py`, `make_divergence_clip.py`, `finalise_report.py`, `render_results_table.py`, `sync_handoff.py`. Batch report, results table, source fingerprints, angle bindings, review queue and HANDOFF_TO_CODEX. |
| `ScratchLab-CXL-Ready-20260913/evidence/operator-media-review-20260913` | `build_review.py`, `server.py`, `test_review_batches.py`, `test_library_qa.py`, `verify_preview_audio.py`, `verify_library.py`, and historical snapshots. Operator observations retain their original title/track/time scope. |
| `ScratchLab-CXL-Ready-20260913/evidence/reference-audio-20260913` | `link-audit/audit_links.py`, reports, staging/install helpers. Adjacent delivery checks, not a new ingest contract. |
| `ScratchLab-Reference-Library-20260913` | `library-v2/ReferenceExamples`, `library-v2-checked/ReferenceExamples`, RESULT.md, source provenance and receipts. `evidence/verify_products.py`; `evidence/metadata-check/measure_tempo.py`, `measure_tempo_grid.py`, REPORT.md. |
| `ScratchLab-Dataset-Integration-20260913` | `inventory/build_inventory.py`, `test_inventory.py`, REPORT.md and ledgers; `baby-take01-hands-v1/extend_pilot.py`, `test_hand_mapping.py`, original `analyse.py`/`make_review.py`. Historical cache/hand review, not platter ground truth. |
| `ScratchLab-Platter-POC` | `scratchlab_platter_poc.py`, `scratchlab_audio_fusion_poc_v2.py`, `scratchlab_av_lag_poc.py`, `validate_turnarounds.py`, `baby79_test/validate_turnarounds_v2.py`; audio V1/V2 subfolders and scripts/READMEs; `baby1.zip`, `baby2.zip`, development/holdout evidence, extracted `_source` manifests and `.meta.json`. |
| Duplicate/historical copies | Canonical scripts also occur in `ScratchLab-CXL-Approval-Export-Audit-20260913/source`, `ScratchLab-CXL-Final-Capture-Fixes-20260913/duration-diagnostics`, `ScratchLab-CXL-Pilot-20260912/evidence/save-playback-relay/checkpoint-source`, `ScratchLab-CXL-Claude-Followup-20260913/evidence/baseline-3558128/source`, and `ScratchLab-Dataset-Integration-20260913/app-evidence/checkpoint-20260913/before`. The canonical, approval-audit and duration-diagnostics ingest scripts compared byte-identically. These are not alternative bases to merge. |
| Adjacent delivery tooling | `ScratchLab-Xcode-Cloud-20260913/evidence/upload_reference_assets.py` and release verification scripts transport/check assets; they do not establish evidence quality. No relevant processing script was found in the `ScratchLab-CXL-MediaAudit-20260913` filename scan. |

Searches covered relevant source/script/report extensions, excluding generated
build products and dependency caches; this is not an assertion about executable
contents of every archive or hidden environment.

## Reuse and authoritative schemas

1. Use canonical `ingest_media_scratch.py` for first-pass local media stream mapping,
   deterministic angle naming, remux/extraction and `.meta.json` emission. It
   preserves folder-derived BPM and marks outputs `needs_review`. Its present
   `media_file_ingest` vocabulary differs from the historical POC sidecars'
   `makemkv_dvd_rip`; do not rewrite history to match today's producer.
2. For the already audited DVD source library, reuse `rebuild_reference_library.py`
   and the batch audit's fingerprints, angle bindings, searched repeat offsets
   and review queue. `scratchlab_reference_examples_v2` plus checksum-bound
   `evidence/provenance.json` is the existing viewing-library contract. It carries
   `performanceID`, source pass, source-time bounds and `canonicalApproval=false`.
   It preserves unfiltered audio and unconfirmed track roles. The checked V2
   library supersedes the older take01-only resource preparation for this use.
3. The POC's `reference.json` schema 1 is authoritative for *this trajectory's*
   vision provenance and analysis clock. Audio evidence schema 2 supplies gated
   support. AV-lag schema 1 is diagnostic and has a known rounded-CSV clock error.
   The raw manual-validation schemas differ and remain review evidence only.
4. `ReferencePackageManifest` remains exclusively the hardware/canonical package
   contract. The separate training-manifest validator prohibits source/vendor
   provenance; neither its accepted status nor historical `trainingUse` can
   establish ScratchLab canonical approval.

Existing tools emit source collection/MKV/folder, performer, nominal BPM and its
origin, angle/audio role, dataset identity, review labels and historical training
use. The V2 library supplies a shared performance identity. The POC additionally
emits the exact FPS/start/duration, estimated angle/velocity/direction, confidence,
interpolation, turnarounds, audio gate and per-window lag/correlation diagnostics.
At the initial audit none emitted `scratchlab_derived_reference_inspection_v1`
directly. The first slice added its Swift decode/read boundary. The next approved
offline producer slice is recorded below; the original audit findings are retained.

The current generic ingester emits `originalFile` and `sourceFolder`; the POC
retains historical `sourceCollection`/`sourceMKV` and `makemkv_dvd_rip` fields from
its source sidecars. The specific historical MakeMKV emitter was not found in
these Developer source/script searches. Preserve those sidecars as evidence;
do not claim today's generic ingester reproduced their exact schema.

## Conflicts to preserve explicitly

- Ingest README's “noBeat: scratch with no beat” is insufficient: program audio
  can include speech. V1 ungated audio is not equivalent to V2 gated support.
- The batch audit refutes the earlier Baby pilot's claim that exported video
  discarded the second field. Do not use the superseded claim to justify work.
- Chapter 2 and the old fixed Coach demo offset are workflow-specific assumptions,
  not a universal speech-free segmentation rule. Batch repeat offsets are searched,
  not assumed to be half a chapter. Both Tears passes remain source-related.
- Old chopped-take datasets, the V2 whole-sequence library and the platter POC
  have different time origins. No unverified cross-pipeline time conversion occurs.
- `extract_baby_scratch_strokes.py` infers strokes from audio. It is not an allowed
  source for this document's vision trajectory or turnaround timestamps.
- Hum-filtered pilot variants cannot replace the frozen POC's audio silently.
- Camera halves baby1/baby2 and windows 18–24/24–30 are not independent sessions.

## Inspection data contract

`DerivedReferenceInspectionDocument` is Codable/Sendable and belongs to the
existing Reference model files. Its discriminator accepts only `videoDerived`
or `videoAudioDerived`. Both false trust flags and explicit review metadata are
required; no missing-key defaults confer provenance or approval. Even an explicit
`approvedDerived` review (requiring reviewer/date) remains training-ineligible.
It has no conversion to a canonical take, manifest or registry entry.

Source metadata retains original vocabulary and a shared performance ID. External
source/evidence references are metadata only: IO never opens or resolves them.
Their existence, hashes, historical producer identity, source rights and the truth
of supplied review/gate declarations are not authenticated by schema validation.

Timebase stores metadata FPS/start/duration and its reference-file binding. Frame
duration is computed from FPS. Samples retain serialized timestamps, angle and
velocity estimates, conventions, direction, confidence and interpolation state.
Canonical frame time is separately accessible. A 0.51 microsecond consistency
tolerance allows six-decimal CSV serialization; it never estimates FPS or repairs
the original value. Sparse fixture excerpts are allowed and do not imply coverage.

Turnarounds retain vision timestamps/confidence and separate optional audio
support. Audio has no angle/velocity/direction fields. Its frozen vision-gate state
controls availability; inactive/unavailable rows may retain raw RMS/flux but no
normalized motion evidence. Gate declarations are validated for consistency,
not regenerated from sparse samples or by rerunning the detector. AV lag is an
array of per-document feature/subset diagnostics; its reported noncanonical FPS
is retained, while inspected milliseconds use the canonical metadata clock.
RMS ratios may exceed one, correlations may be negative, and neither is converted
to a calibrated probability. No lag is applied to vision data.

`ReferencePackageIO.decodeDerivedInspection(_:)` and
`readDerivedInspection(at:)` read this normalized JSON only. Direct Codable decode
also calls `ReferenceValidator.derivedInspectionIssues`. Missing keys, invalid
enums, false trust claims, invalid clocks/frames, contradictory availability,
audio mutation claims and malformed diagnostics fail without repair. The initial
boundary slice performed no writes, source-media extraction, automatic approval
or publication. The later review-copy writer was removed with the runtime UI;
the current inspection IO is read/decode only.

## Fixtures and verification

`ScratchLabDesktopTests/Fixtures/DerivedInspection` contains small deterministic
projections of the two POC schemas: development frames 0/7/26 and holdout frames
0/10/238/359, one original turnaround each and original per-window correlations.
Frame 238 preserves interpolation/unknown direction; frame 359 preserves loud
inactive-platter program audio. Both use the same collection/folder performance
identity. Full original tracking/manual-validation metadata remains at the named
external sources; the fixtures are not replacement POC archives or approvals.

Tests live in existing `ReferenceAuthoringTests.swift` and load fixture files from
the source tree, not app resources. Existing shared model/IO files already belong
to iOS and macOS targets. No project membership, UI, preview, signing, sidecar,
canonical export, capture, MIDI/DVS or learner path changes are needed.

## Offline producer slice — 26 September 2026

The existing `scripts/dataset_processor/ingest_media_scratch.py` now dispatches
`derived-inspection` to its adjacent `derived_reference_inspection.py` adapter.
Legacy ingest arguments and processing are unchanged. No second ingest/extractor,
library rebuild, runtime consumer or Swift contract change is introduced.
The source's embedded `datasetMetadata` is the existing sidecar snapshot; its
historical vocabulary is retained, not upgraded to current ingest labels.

| Input | Projection into the existing inspection contract |
| --- | --- |
| `reference.json` schema 1 | False trust flags and `videoDerived` required. Source collection/MKV/folder/angle/video/archive/dataset identity, optional performer/BPM/origin/trainingUse retained. `video.analysisFPS`, start and duration exclusively own the clock. |
| `trajectory.csv` | Original frame/timestamp, `smoothed_angle_deg`, forward-positive signed velocity, direction, visual confidence and interpolation. Blank estimates remain null for unknown direction. Conventions identify the columns and recorded `tracking.forwardSign`. |
| Reference turnarounds | Original frame/time/kind; visual confidence comes from the matching vision sample, never audio. |
| Audio V2 fusion CSV | Copies of vision fields must agree with trajectory. `audio_evidence_available` is the already computed padded gate, not `vision_activity_raw`. Raw RMS/flux survive inactivity; normalized motion cannot. |
| Audio V2 turnaround JSON | Source/angle/clock/turnaround declarations must agree. Explicit noBeat/speech semantics and false mutation flags required. Original trough delta/RMS/baseline/ratio are separate support, not confidence or trajectory edits. |
| AV-lag report schema 1 | Each feature/subset's recorded `bestPearson` row, including its Spearman diagnostic, is copied in stable key order. Full curves and `bestSpearman` alternatives stay in the referenced original report. Reported FPS remains explicitly noncanonical. |

The POC does not contain `performanceID`. A caller must provide the established
shared identity (`qbert_makemkv_dvd/Baby_79bpm` for BOTH current windows); the adapter
does not infer it from an interval, camera, archive path or dataset item ID.
If source, dataset metadata or manifest already carries an ID, it is preserved;
every supplied/embedded identity must agree. Identity truth is not authenticated.

Default output is `videoAudioDerived`. Explicit `--video-only` produces
`videoDerived` without reading audio or claiming audio support. Missing mandatory
files, keys, provenance, invalid clocks, conflicting copied vision/source fields,
duplicate keys/frames, malformed numbers/CSV, mutation claims and contradictory
availability fail with a nonzero exit and no published output. No clamping,
sorting of samples, interpolation, direction repair or lag correction occurs.

Output is sorted-key, indented UTF-8 JSON with a trailing newline and no generated
time, UUID or machine-local input-root substitution. The original archive and
historical producer vocabulary remain verbatim. Output creation is atomic and
exclusive, outside the read-only evidence tree; existing outputs are never
replaced. Source references are metadata, not paths to resolve/authenticate.
Existing source-media rights, reviewer identity and detector authenticity are
outside this contract. New inspection review is always `needsReview`; no raw
historical review/training label is promoted to approval.

This is a bounded projection, not a lossless replacement archive. Tracking
parameters, manifest contents, original review labels, extra audio diagnostics
and full AV search curves remain in the named original evidence files. Relative
evidence filenames retain their meaning relative to the input evidence root;
an output JSON alone is not a portable, authenticated evidence package.

Small raw-schema excerpts live under `Fixtures/DerivedInspection/Producer`.
Their sparse samples and preserved report summaries do not assert complete
coverage; the producer/Swift contract accepts sparse evidence, not completeness.
Three `Expected` JSON files are generated projections checked byte-for-byte by
`scripts/test_derived_reference_inspection.py` and decoded by
`DerivedReferenceProducerTests` through the existing IO. Swift tests do not launch
Python from the sandboxed app. An explicit test-only
`SCRATCHLAB_DERIVED_INSPECTION_OUTPUT_ROOT` can instead select newly generated
full-window outputs, in which case the tests require 360 samples. No test data
or external media is added to app resources or project membership.

## Runtime de-scope — 26 September 2026 (current)

Archival video/audio is offline research evidence only, not application content.
The macOS derived review sheet, Open Derived Evidence entry point, video/player
and playhead state, Accept/Reject controls, review-copy writer and UI presentation
helpers were intentionally removed. No native Open/Save/video smoke test is
required. The prior successful UI verification below is historical only and is
superseded by product direction; Build/derived-review-20260926 is preserved.

The original inspection model, strict validator and read/decode IO remain for
offline research/tests with no shipping runtime consumer. Optional review
annotations and their validation remain useful lossless offline metadata, not
automatic quality judgments. Two pure-model tests cover annotation round trips,
unchanged evidence/eligibility and malformed annotation rejection. Earlier
inspection/producer tests, fixture data and producer tooling are preserved.

Older Reference Examples/ScratchExampleLibrary playback and Practice audio are
explicitly unchanged in this slice. This removal does NOT prove whole-product
compliance with the no-archive-media shipping policy. A separate bounded de-scope
must handle those existing paths without removing legitimate capture review.

Verification: focused108 unique/216 executions; bounded regression238/476;
Python producer14/dataset36/capture87; all four normal builds pass. Source and
preservation hashes match; git diff --check passes. No full-suite, native media
smoke, installation or hardware acceptance is claimed. Current receipt:
Build/derived-descope-20260926/RESULT.md.

## Historical macOS derived review slice — superseded, 26 September 2026

The following describes the removed implementation, not currently available UI.

Reference Authoring's **Open Derived Evidence…** opens normalized inspection JSON
in a modal review sheet within the existing workflow. The existing
ReferenceAuthoringViewModel owns the document, playhead, editable reviewer/notes
and video preview. ReferenceAuthoringSession is intentionally unchanged: an
inspection document never enters its canonical take state machine.

Physical platter angle is explicitly NOT ESTABLISHED. All plotted/numeric motion
is IMAGE-PLANE DERIVED MOTION, not physical degrees or physical deg/s. Observed
means a stored, noninterpolated estimate exists, not verified marker identity.
Unknown direction and interpolation are independent facts. Sparse gaps are not
joined or filled by review. Confidence is an uncalibrated diagnostic, not a percent
probability. Manual exclusions overlay rather than delete original evidence.

Accept for Authoring retains serialized `approvedDerived`; Reject Evidence uses
`rejected`. Both require reviewer attribution and save a NEW normalized JSON via
ReferencePackageIO.writeDerivedInspectionCopy before applying the state change.
Cancel/failure/existing destination leaves the loaded decision unchanged. Only
review metadata changes; samples, turnarounds, audio, lag, provenance and clocks
remain equal. No canonical package/take, registry write or training eligibility
results. Reviewer identity/rights are recorded, not authenticated. Notes are saved
with a successful decision; closing otherwise discards note edits after a warning.

The existing v1 Review has an additive optional `annotations` array. Old fixtures
and producer output still decode unchanged. Each annotation carries inclusive
`firstFrame`/`lastFrame` in the document's ANALYSIS frame space, `kind`
(`suspect`, `unavailable`, `manualExclusion`), `reason`
(`suspectedNonMarkerLock`, `missingVisualEvidence`, `handOcclusion`,
`blendedEditTransition`), nonempty `reviewer` and `evidenceReference`.
Bounds must be ordered/nonnegative and inside the declared analysis duration;
blendedEditTransition requires manualExclusion. Interpolation/unknown-direction
reason labels come from unchanged sample fields, not invented quality flags.
Annotations are read/displayed/preserved; this slice has no interval editor or
experimental-screen adapter. Missing/empty annotations do NOT mean quality passed.
Other investigation-sidecar structures are not interpreted as this extension.

Video selection is explicit via the system file picker. AVPlayer/VideoPlayer uses
the original selected local file with no media copy, extraction or storage layer.
JSON provenance paths are never resolved/opened automatically. The preview is
muted and operator-selected, not authenticated to the document. Default playback
is independent. The operator may explicitly choose video-zero = timestamp-zero
or video-zero = analysis-start for APPROXIMATE display alignment. No source or
detector timestamp is rewritten, no AV lag applied, and no exact sync claim made.
Media selection/alignment are transient and must be chosen again after reopen.

Deferred contract gaps: exact integer sourcePTS/rational time base, explicit
videoAssetID/take fields, hash/transform-bound media identity and calibration,
manual exclusion uncertainty brackets/review status, and external sidecar
ingestion. The UI says not supplied rather than inferring identities from filenames
or manufacturing PTS. Current raw processed-library detector runs remain outside
the normalized input contract; this UI does not make them import-ready.

Canonical behavior, iOS consumers, capture/MIDI/DVS, learner/Practice/scoring,
AI/XP/AR, app resources and project membership remain unchanged. Shared pure
model/validation/IO additions compile for both platforms; only macOS has this UI.
