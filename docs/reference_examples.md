# Shared reference examples and offline advisory analysis

CXL is a dedicated Mac capture/review/export product. The ordinary iPhone/iPad and Mac apps retain their full interface. Both use the same reference viewer, catalogue validation and offline analysis; platform code only presents the shared view with finalized media URLs.

| Product | Scheme / configuration | Mac identity |
| --- | --- | --- |
| Full Mac | ScratchLabDesktop / Release | com.machelpnz.scratchlab |
| CXL capture | ScratchLabCXL / CXLRelease | com.machelpnz.scratchlab.cxl-authoring |
| Full iPhone/iPad | ScratchLab | Existing iOS identity |

Only CXLRelease defines CXL_AUTHORING. DEBUG remains a diagnostic condition. CXL retains signing team 2DDKGL33BU and its existing permissions/entitlements. Stage updates with scripts/stage_cxl_mac.py. The normal Mac Release must never be substituted into that staging workflow.

## Local data preparation

The source MKVs, derivatives and advisory model binaries remain outside Git. The current builder consumes the completed Claude audit and existing operator observations; it does not repeat the repeat-detection or camera-identification analysis.

```sh
python3 scripts/rebuild_reference_library.py \
  --source '/Volumes/Untitled/CXLrip' \
  --audit '/path/to/claude-mkv-batch-audit' \
  --review '/path/to/operator-media-review-20260913' \
  --previous '/path/to/reference-library-v1' \
  --output '/path/to/library-v2/ReferenceExamples'
python3 scripts/check_reference_metadata.py \
  --library '/path/to/library-v2/ReferenceExamples' \
  --titles '/path/to/observed-lesson-titles.json' \
  --output '/path/to/library-v2-checked/ReferenceExamples'
mkdir -p LocalReferenceLibrary
ln -s '/path/to/library-v2-checked/ReferenceExamples' LocalReferenceLibrary/ReferenceExamples
```

Use a new output version and an absolute symlink target. A completed output is never overwritten. Incomplete work resumes only with matching builder/input identities and verified derivative receipts. The resource folder is copied into iOS and Mac apps; Watch receives no dataset payload. A checkout without prepared resources cannot produce this configured build.

The metadata check requires numpy/scipy and ffmpeg. It attaches explicit, source-hash-bound title-card observations and checks the nominal integer BPM against independently ranked beat-periodicity candidates on the whole recording and both halves, requiring support on at least two source streams. It preserves candidates and metrical ambiguity in provenance; unsupported tempos stop publication for review instead of guessing a replacement. The September 13 check supports all 23 existing nominal BPM labels. Source title aliases clarify names such as “2-click flare (orbit)” and “Long-short tip tears” without changing class IDs. The final resource folder contains the declared playback/model assets and review provenance; machine-local build paths, decoder receipts and caches remain outside the app. This step never re-encodes media or repeats Claude's audit.

Version 2 contains **23 techniques, 24 source sequences, 95 camera views and 72 audio tracks**. The extra sequence preserves the second Tears source pass, sharing the first pass's performance identity. Cutting has three distinct views: its missing camera 2 is not replaced with another angle. Each sequence retains the performances and intervening breaks from chapter 2 to the measured repeat boundary. Boundaries use the searched frame offset, not half the chapter duration. The 22 fully repeating techniques use the first sequence; both Tears passes remain selectable with their unresolved picture/audio difference clearly stated.

The previous library's `take01` through `take08` filenames did **not** establish eight distinct Baby performances. They were pieces of the longer repeated source sequence. Claude verified duplication across the 23-technique collection; this build does not silently turn repeated passes or chopped files into additional independent performances. It also does not catalogue the other unidentified source titles outside these 23 techniques.

Video is rebuilt from the original MKVs using BFF field-aware `bwdif`, retaining 720×480 source resolution, 8:9 sample aspect ratio and approximately 59.94 progressive field samples per second. No generative detail is added. The older claim that the delivered Baby MP4s discarded one field was refuted by Claude's audit; both fields were present. Rebuilding improves the derivatives' field handling and restores whole-sequence selection, not lost detail.

Audio is an unfiltered float PCM decode of the corresponding MKV range. All three source streams remain available. Fourteen techniques retain the audit's established audio-role labels. Nine retain generic Track 1/2/3 labels because their roles were not confirmed: 1clickflare, clovertears, dicing, long_short_tips, needledropping, orbits, originalflare, waves and zigzags. No hum removal is applied. The builder checks source identities, output PCM and all rendered frame timestamps/counts, then decodes every new video completely. These are derivative-integrity checks, not another repeat audit or proof of absolute physical synchronization.

The manifest stores each sequence's source range, searched offset, shared performance identity, source pass, audio-role status, limitations and exact asset hashes. `evidence/provenance.json` binds the original title/SHA256 for every camera, stream ordinals, output checks and existing observations. The manifest records that provenance file's hash. Operator observations keep their original view/range/track scope; the other camera views and Tears' second pass do not inherit an approval. Speech-free boundaries and exact hand-to-sound timing remain unestablished where not independently observed. The original review queue is retained in `evidence/source-review-queue.json`.

Both advisory models remain byte-identical to the previously bundled files; no training is performed. Old cached hand observations are omitted because their frame indexes belong to the chopped videos. Imported-take motion analysis continues to extract features from that actual imported video. The legacy version 1 reader and preparation script remain supported for reproducibility.

## Review behavior

Reference examples are source-labelled material awaiting expert review. They never enter ReferenceRegistry, canonical packages or saved capture drafts. Viewing, comparison and estimated technique results do not change capture metadata, selected technique, notation, scores or approval.

The viewer is available from full-app Review/Practice navigation, the finalized iOS take review, general Mac Review and the CXL reference/review tool. Opening during Mac capture/finalization is disabled. Own media can also be chosen using the system file importer. Source files are preserved; imported copies belong only to this review session. Analysis reports are exported independently of capture packages.

Each reference camera view plays with the selected same-sequence WAV in one player. Confirmed roles default to Scratch only; unconfirmed roles default to Track 1. Native play, pause and seeking control both tracks together. Source timestamps are shifted by one common range origin, retaining fractional video-frame offsets and sample-quantized audio; there is no independently inferred camera/audio correction. Original durations and available tails are preserved. Camera audio is not mixed in. Imported-take comparison still has independent controls; no comparison alignment is invented. Version 2 does not show the previous clips' cached hand paths.

## Recognition boundary

Analysis is explicit, on device and limited to finished media up to two minutes. Audio and camera motion are separate modalities. The motion feature extractor and exact legacy 60-frame/30-stride/67-column transform are shared with existing tools; no new training or silent preprocessing change is performed. Reports retain file/model SHA256 identities, window times, model scores and limitations. Scores are not calibrated probabilities or measured accuracy. Failures remain visible and one usable modality can survive failure of the other.

Compatibility on source examples does not establish unseen-performance accuracy. Future CXL evaluation takes should have expert-confirmed labels, preserve all angles/repetitions of a performance in the same split, and remain excluded from training, validation and tuning. The agreed initial CXL evaluation setup can use one fixed front camera at about 45 degrees, with the scratching hand, platter and crossfader visible, plus recorded audio. Watch data is optional for audio/video evaluation; preserve it when present and mark absence explicitly. Karl clarified that Watch motion was intended for future 3D battling-DJ avatars. That is optional supplemental wrist motion, not a full body/finger capture. Ordinary canonical approval now permits explicitly absent Watch motion. Absence remains a visible warning and is preserved in the package; pending, failed, conflicting or mismatched Watch sources remain blocking. Exact packages verify declared absence against the captured sidecar, and attached motion still requires the matching file, identity and hash. Test multiple performers/setups before promoting recognition into scoring or approval behavior. Canonical review can be deferred and is not replaced by a model label.

## Verification

Run `python3 scripts/test_rebuild_reference_library.py`, `python3 scripts/test_prepare_reference_examples.py`, the shared catalogue/review tests, and `swift test --package-path Tools/TrainModels` for preprocessing/service coverage. The opt-in model compatibility smoke takes `SCRATCHLAB_ADVISORY_SMOKE_ROOT` and `SCRATCHLAB_ADVISORY_SMOKE_REPORT`; it runs existing models without training or accuracy assertions. `scripts/build.sh all` covers iOS, full Mac Release, CXLRelease and Watch after the capture fixture/XCTest gate. Use isolated product/intermediate/cache/test-host paths; preserve installed apps and captures before deployment. Physical capture and UI acceptance remain separate from software tests.
