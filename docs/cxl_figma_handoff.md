# CXL Release route design handoff

External Figma editing was not authorized for this batch, so file `AgrnQXwRvkAKlORTQ2U25z` remains pending. This record maps the implemented Release states to existing production components without inventing frames.

| Release stage | Implemented component | Required visible state |
| --- | --- | --- |
| Setup | `ReferenceAuthoringView.setupSection`, `calibrationSection`, `preflightSection` | Immutable capture intent, exact BeatSpec identity, declared variant, device readiness, and calibration status |
| Capture | `ReferenceAuthoringView.recordingSection`, `framingSection` | Explicit Record/Stop, camera framing, live measured notation, source state, and fail-closed unknown evidence |
| Review & Export | `ReferenceAuthoringView.reviewSection` | Finalized WAV/MOV audition, four repetition boundaries, canonical Tear review, approval blockers, raw capture save, approved package export, and copied-package reopen verification |

The Release window uses a 900 x 700 minimum and an 1180 x 820 default. The content is a bounded 860-point column inside a vertical scroll view, so Setup, Capture, and Review remain reachable at the minimum size. Practice, coaching, progression, performer-monitor, and DEBUG hardware windows are not part of the Release scene.

Before adding Figma frames, capture the built Release route at the default and minimum sizes. Label unknown motion/fader evidence explicitly and keep raw capture export visually separate from approved package export.
