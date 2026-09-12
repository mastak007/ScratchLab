# CXL MKV audit checkpoint

This directory preserves Claude Code's completed 13 September 2026 audit as a reviewable snapshot. It is evidence and investigation tooling, not a production media importer. The user explicitly requested committing and pushing this work.

`ARCHIVE_MANIFEST.json` hashes every copied file and indexes the excluded media. The original evidence remains at `/Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/evidence/mkv-source-inspection-20260913/claude-mkv-batch-audit`. Original MKVs, dataset assets, 48 review videos (about 533 MB), decode caches and Python bytecode are not committed. Source paths and tool versions are recorded in the archived handoff. No source media, installed app or training data has been replaced.

## Current result and limits

- The current machine-readable batch state has 23 technique results: 22 `verified_duplicate_half`, 1 `verified_partial_repeat` (Tear), 0 pending/failed/inconclusive. These are repeat-analysis classifications, not declarations that every media property is verified.
- Five searched offsets differ from half the chapter duration. Do not truncate every title at its midpoint or treat all named segments as independent performances.
- Tear contains a local picture/audio divergence. The user compared the clips and said `i cant tell they look same`. `OPERATOR_REVIEW.json` records that unresolved reading and the proposed exclusion of take02/take06, all four angles, from paired training/evaluation until resolved. Both versions remain preserved; no existing dataset eligibility was changed.
- Cutting angle 2 is absent from the inspected files. The t05/t06 duplicate appears in Baby's group-level report too; Baby's own t00-t03 camera titles are distinct.
- Repeat-period agreement does not establish absolute audiovisual sync. Absence of a flagged divergence at the tested one-second windows does not establish absence at finer resolution.
- Talking boundaries still need listening review. The report's component and voice-band checks cannot establish speech-freedom.
- All 23 technique repeat audits completed, but 27 single-audio-stream titles remain unidentified. Do not describe the entire source collection as fully catalogued.

## Corrections discovered during handoff review

The archived files are preserved verbatim, including superseded prose. Treat current `batch-state.json` classifications as the completion record; several handoff paragraphs still mention 19 pending, a two-technique budget cap, an untested positive control or unrefreshed earlier artifacts. Those are historical instructions, not current pending tasks.

The detailed audio-role test is **NOT CONFIRMED for nine techniques**: 1clickflare, clovertears, dicing, long_short_tips, needledropping, orbits, originalflare, waves and zigzags. Do not relabel their tracks automatically from Baby's stream order. The repeat classifier's verified label does not override those per-technique audio results. Moreover, a component sum alone cannot distinguish two interchangeable addends; retain the content evidence for semantic track labels.

`scripts/make_boundary_previews.py` hard-caps tail previews at 83.4 seconds and rounds filenames. Some archived tail previews therefore do not represent the relevant source ending, and filename timestamps are not an exact timing manifest. New review derivatives must use each title's actual timestamps and distinguish the candidate end of one unique pass from the original chapter end. Audio/video are also independently zeroed in that legacy preview script, so those previews must not be used as exact sync evidence.

The old Baby pilot claim that its exports discarded one interlaced field was refuted by the audit. Both fields are retained in those checked MP4s. Correcting existing video remains an option; source rebuilding is a separate decision based on mappings, duplicated content, fidelity and operator-reviewed cuts.

## Verification of this checkpoint

The checkpoint verification validates JSON, parses the archived Python scripts without executing them, checks copied bytes against `ARCHIVE_MANIFEST.json`, checks 23 result records and their script fingerprints, and confirms that no media payloads are staged. It does not rerun the expensive audit, certify its methodology, or establish physical sync/speech-free cuts. There are no changes to Swift, project/build settings, signing or app resources; app builds are not applicable to this archive-only checkpoint.

Do not run the archived scripts in-place casually: they write investigation results relative to their directory and require the recorded local source paths. Resume experiments in a separate evidence directory, preserving this snapshot and its known limitations. The next active slice is an external operator-review tool at `/Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/evidence/operator-media-review-20260913`; it is separate from this frozen Claude checkpoint and does not replace packaged app media.

Two original trailing spaces in `scripts/stage_a2_angle_binding.py` (lines 58 and 87) are retained to preserve the archived hashes. Git whitespace checking reports those two archival findings; all newly written checkpoint documentation passes.
