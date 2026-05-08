# ScratchNotation (dev tooling)

Local Swift package for generating ScratchLab notation timelines from
dataset evidence. Phase 1 ships the data model, the inference algorithm,
the JSON sidecar codec, and tests.

This package is **not** linked into the iOS app target. It exists so the
dataset pipeline can produce two artefacts in lockstep:

1. Core ML training samples (already produced by the Python pipeline)
2. Notation timelines for each take, written next to the take as a JSON sidecar

## Constraints (enforced)

- No raw training audio/video bundled with the app.
- Dataset folders are **not** added to Copy Bundle Resources.
- Approved notation is kept in a separate file from inferred notation; a
  re-run of the generator must never overwrite human review work.
- The encoded JSON contains no source provenance — see `LeakScanTests`.

## Files

```
Sources/ScratchNotation/
  DatasetNotationEvent.swift       Event model (stroke/hold/silence/unknown,
                                   forward/back/none/unknown, source, conf, …)
  DatasetNotationTimeline.swift    Per-take timeline + approval state + schema
  NotationEvidence.swift           Inputs: AudioOnsetEvent, AudioSilenceEvent,
                                   VisualMotionEvent, BeatGrid
  ScratchNotationGenerator.swift   Audio/visual fusion → DatasetNotationTimeline
  NotationCodec.swift              JSON encode/decode + sidecar IO

Tests/ScratchNotationTests/
  DatasetNotationModelTests.swift
  ScratchNotationGeneratorTests.swift
  NotationCodecTests.swift
  LeakScanTests.swift
```

## Generator behaviour

For each segment of the take's timeline, evidence is fused with this table:

| audio    | visual          | -> type   | direction   | source | confidence              |
|----------|-----------------|-----------|-------------|--------|-------------------------|
| onset    | forward / back  | stroke    | (visual)    | fused  | mean(audio, visual)     |
| onset    | still           | stroke    | unknown     | audio  | audio                   |
| onset    | unknown         | stroke    | unknown     | audio  | audio                   |
| silence  | forward / back  | stroke    | (visual)    | vision | visual × 0.5            |
| silence  | still           | hold      | none        | fused  | mean(audio, visual)     |
| silence  | unknown         | silence   | none        | audio  | audio                   |
| none     | forward / back  | stroke    | (visual)    | vision | visual × 0.5            |
| none     | still           | hold      | none        | vision | visual × 0.5            |
| none     | unknown         | unknown   | unknown     | audio  | 0                       |

The generator never invents a label it can't justify: any region without
corroborating evidence ends up as an `unknown` event.

Adjacent events that share `(type, direction, source)` are merged so the
output isn't fragmented across breakpoint boundaries.

## Sidecar files

For every take in the dataset, two filenames are conventional:

- `notation.inferred.json` — generator output, `approvalState: inferred`
- `notation.approved.json` — human-reviewed copy, `approvalState: approved`

The two files coexist; the approved one is authoritative once present.

## Running tests

```bash
cd Tools/ScratchNotation
swift test
```

Tests cover:
- forward/back audio + vision combine into stroke events
- silence + still vision = hold; silence alone = silence
- audio onset without vision = stroke with `direction: unknown`
- vision alone = stroke marked `source: vision` with discounted confidence
- approved timelines round-trip through JSON unchanged
- encoded JSON contains none of: `/Users`, `MakeMKV`, `sourceMKV`, `QBERT`,
  `SXRATCH`, `rightsStatus`, `reviewStatus`

## What this package does NOT do (yet)

- Phase 1 has no review UI. Phase 2 will add a dev-only SwiftUI surface for
  listing events and approving/rejecting timelines.
- Phase 1 has no extractors that produce `AudioOnsetEvent` /
  `VisualMotionEvent`. Wiring real extractors (silencedetect output, Vision
  hand-pose, beat-grid alignment) is downstream work.
- Nothing here is wired into the iOS app or App Store-facing UI.
