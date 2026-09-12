# Shared reference examples and offline advisory analysis

CXL is a dedicated Mac capture/review/export product. The ordinary iPhone/iPad and Mac apps retain their full interface. Both use the same reference viewer, catalogue validation and offline analysis; platform code only presents the shared view with finalized media URLs.

| Product | Scheme / configuration | Mac identity |
| --- | --- | --- |
| Full Mac | ScratchLabDesktop / Release | com.machelpnz.scratchlab |
| CXL capture | ScratchLabCXL / CXLRelease | com.machelpnz.scratchlab.cxl-authoring |
| Full iPhone/iPad | ScratchLab | Existing iOS identity |

Only CXLRelease defines CXL_AUTHORING. DEBUG remains a diagnostic condition. CXL retains signing team 2DDKGL33BU and its existing permissions/entitlements. Stage updates with scripts/stage_cxl_mac.py. The normal Mac Release must never be substituted into that staging workflow.

## Local data preparation

The user's dataset and model binaries remain outside Git. Prepare a new immutable library version, then link it into the ignored app-resource location:

```sh
python3 scripts/prepare_reference_examples.py \
  --source '/path/to/PRO DJ DATASET/dataset' \
  --output '/path/to/reference-library-v1'
mkdir -p LocalReferenceLibrary
ln -s '/path/to/reference-library-v1' LocalReferenceLibrary/ReferenceExamples
```

Use an absolute symlink target. Existing output versions are never overwritten. The app build copies the complete ReferenceExamples folder into iOS and Mac resources; Watch receives no dataset payload. A checkout without prepared resources cannot produce this configured build. Do not replace the missing resource with an empty catalogue.

The current selection contains one named performance per each of 23 source techniques: the first take at the lowest listed BPM. It includes available camera angles, their unchanged cached hand observations, three shared audio variants and two original model files. One Cutting camera is missing and is omitted explicitly. Selection does not use model scores. The current assets total 371,834,369 bytes (approximately 355 MiB); the full training corpus remains external.

The source contains 175 recorded performances (6–10 takes per technique), while the current app package includes only the 23 take01 performances. The remaining 152 source takes are not selectable in this package. For example, Baby has eight recorded takes with four angles each; the current app includes the four views of Baby take01. Scratch only, With beat and Beat only select soundtracks for the included performance, not another recorded take.

The manifest stores source-relative provenance, current SHA256 identities, asset sizes, labels and limitations. Historical processing hashes and hardware synchronization remain unknown. Hash checks verify current file identity, not historical provenance or label quality. Same-source audio is referenced once. Byte-identical distinct sources retain distinct provenance records.

## Review behavior

Reference examples are source-labelled material awaiting expert review. They never enter ReferenceRegistry, canonical packages or saved capture drafts. Viewing, comparison and estimated technique results do not change capture metadata, selected technique, notation, scores or approval.

The viewer is available from full-app Review/Practice navigation, the finalized iOS take review, general Mac Review and the CXL reference/review tool. Opening during Mac capture/finalization is disabled. Own media can also be chosen using the system file importer. Source files are preserved; imported copies belong only to this review session. Analysis reports are exported independently of capture packages.

Each reference camera view plays with the selected same-performance WAV (Scratch only by default, With beat, or Beat only) in one player. Native play, pause and seeking control both tracks together. The camera and WAV start at their original zero timestamps; no measured synchronization correction is available or applied. Their original durations are retained, including the dataset's less-than-one-frame video tail. Camera audio is not mixed in. Imported take comparison still has independent controls; no comparison alignment is invented. Cached hand paths are image-space estimates with missing/off-image observations and identity discontinuities retained as limitations; they cannot supply platter holds or fader observations.

## Recognition boundary

Analysis is explicit, on device and limited to finished media up to two minutes. Audio and camera motion are separate modalities. The motion feature extractor and exact legacy 60-frame/30-stride/67-column transform are shared with existing tools; no new training or silent preprocessing change is performed. Reports retain file/model SHA256 identities, window times, model scores and limitations. Scores are not calibrated probabilities or measured accuracy. Failures remain visible and one usable modality can survive failure of the other.

Compatibility on source examples does not establish unseen-performance accuracy. Future CXL evaluation takes should have expert-confirmed labels, preserve all angles/repetitions of a performance in the same split, and remain excluded from training, validation and tuning. The agreed initial CXL evaluation setup can use one fixed front camera at about 45 degrees, with the scratching hand, platter and crossfader visible, plus recorded audio. Watch data is optional for audio/video evaluation; preserve it when present and mark absence explicitly. Karl clarified that Watch motion was intended for future 3D battling-DJ avatars. That is optional supplemental wrist motion, not a full body/finger capture. Ordinary canonical approval now permits explicitly absent Watch motion. Absence remains a visible warning and is preserved in the package; pending, failed, conflicting or mismatched Watch sources remain blocking. Exact packages verify declared absence against the captured sidecar, and attached motion still requires the matching file, identity and hash. Test multiple performers/setups before promoting recognition into scoring or approval behavior. Canonical review can be deferred and is not replaced by a model label.

## Verification

Run `python3 scripts/test_prepare_reference_examples.py`, the shared catalogue/review tests, and `swift test --package-path Tools/TrainModels` for preprocessing/service coverage. The opt-in model compatibility smoke takes `SCRATCHLAB_ADVISORY_SMOKE_ROOT` and `SCRATCHLAB_ADVISORY_SMOKE_REPORT`; it runs existing models without training or accuracy assertions. `scripts/build.sh all` covers iOS, full Mac Release, CXLRelease and Watch after the capture fixture/XCTest gate. Use isolated product/intermediate/cache/test-host paths; preserve installed apps and captures before deployment. Physical capture and UI acceptance remain separate from software tests.
