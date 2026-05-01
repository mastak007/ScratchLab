# ScratchLab Offline Segmentation Plan

This document is planning-only scaffolding for a future offline segmentation step.

Current status:

- accepted dataset items remain `whole_take` or `whole_clip`
- no segmentation is implemented yet
- no model training is implemented here
- no existing accepted or rejected dataset items should be modified or deleted by this plan

## Goal

Add a later offline step that can segment accepted whole-take dataset items into individual scratch events without changing the iOS, macOS, or watchOS apps.

The future segmenter should run after `process_dataset.py` has already produced canonical accepted items.

## Non-Goals

- no ML model training
- no inference model integration
- no destructive rewrite of the accepted dataset
- no change to the existing `process_dataset.py` output contract

## Proposed Future Flow

1. Read from `processed_dataset/accepted/**/take_####/meta.json`
2. Generate candidate segment boundaries from one or more offline heuristics
3. Write segment proposals into a separate non-destructive output area
4. Track manual review state per segment
5. Promote approved segments into later training/export workflows

## Placeholder Segmentation Strategies

### Audio Onset Detection Placeholder

Purpose:
- find likely scratch-event start and stop points from transient energy changes in the accepted audio track

Future TODO:
- [ ] read accepted `audio.*` when present
- [ ] compute simple offline onset candidates
- [ ] emit candidate windows instead of final labels
- [ ] record the method as `audio_onset_placeholder`

### Beat-Grid Segmentation Placeholder

Purpose:
- align candidate segment windows to BPM-aware timing when the accepted item includes reliable beat metadata

Future TODO:
- [ ] require usable `bpm` and `beatMode`
- [ ] derive beat-grid boundaries from metadata rather than retraining anything
- [ ] snap or score audio candidates against beat positions
- [ ] record the method as `beat_grid_placeholder`

### Motion Peak Segmentation Placeholder

Purpose:
- use optional watch motion or motion sidecar peaks to find scratch gestures that may align with event boundaries

Future TODO:
- [ ] read accepted `motion.*` when present
- [ ] detect candidate peaks or gesture windows offline
- [ ] correlate motion peaks with audio/video timing
- [ ] record the method as `motion_peak_placeholder`

## Manual Review Status

Future segments should carry explicit review state and must not be treated as final training labels until reviewed.

Proposed values:

- `unreviewed`
- `approved`
- `rejected`
- `adjusted`

Rules:

- auto-generated segments start as `unreviewed`
- manual edits should switch the segment to `adjusted`
- rejected segments remain in review output for auditability and should not silently disappear

## Non-Destructive Future Output

The future segmenter should write to a sibling area instead of overwriting accepted whole takes.

Example future layout:

```text
processed_dataset/
  accepted/
    baby/
      90bpm/
        take_0001/
          audio.wav
          video.mov
          meta.json
  segmentation_review/
    baby/
      90bpm/
        take_0001/
          segment_0001/
            meta.json
          segment_0002/
            meta.json
```

This keeps the accepted source item intact while allowing iterative segmentation and manual review.

## Proposed Per-Segment `meta.json` Schema

Planning-only example:

```json
{
  "segmentID": "segment_0001",
  "parentDatasetItemID": "dataset_item_abc123",
  "parentOutputPath": "accepted/baby/90bpm/take_0001",
  "sourceType": "scratchlab_zip",
  "sourceFile": "session_export.zip",
  "performer": "Qbert",
  "scratchType": "baby",
  "bpm": 90,
  "beatMode": "withBeat",
  "hasAudio": true,
  "hasVideo": true,
  "hasMotion": true,
  "segmentIndex": 1,
  "startTime": 1.24,
  "endTime": 1.82,
  "duration": 0.58,
  "segmentationMethod": "audio_onset_placeholder",
  "segmentationStatus": "candidate",
  "manualReviewStatus": "unreviewed",
  "confidence": 0.65,
  "notes": "",
  "createdFromWholeTake": true
}
```

Minimum intent for the future schema:

- preserve the parent dataset item identity
- preserve original performer, scratch type, BPM, and beat context
- capture the exact segment window
- capture how the segment was proposed
- capture whether a human has reviewed it yet

## Implementation TODO Scaffold

- [ ] add a future `segment_dataset.py` entry point instead of extending `process_dataset.py`
- [ ] read only from `accepted/` inputs
- [ ] write only to a separate `segmentation_review/` output tree
- [ ] never mutate or delete existing accepted dataset items
- [ ] support audio-onset candidate generation when audio exists
- [ ] support beat-grid candidate generation when BPM metadata exists
- [ ] support motion-peak candidate generation when motion exists
- [ ] emit per-segment `meta.json` using the schema above
- [ ] track explicit manual review status
- [ ] document promotion rules from review candidates to approved segments
