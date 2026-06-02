# Mac / iOS Parity Audit — Scratch Playback Lab + controller-input safety

Status: analysis only (Slice 12). No code changes. Written after the tester-critical Mac
controller-mapping safety slices (1–11) landed on `release/testflight-1`.

## Context

- The macOS app is the `ScratchLabDesktop` target (product module `ScratchLab`); the iOS app
  is the `ScratchLab` target. Shared code under `ScratchLab/` compiles into both.
- Slices 1–11 added a controller-trust + mapping layer and Playback Lab review/export tools.
  Some of it was deliberately landed as **shared**; the rest is macOS-only for now.

## What is already shared (compiles into iOS today)

- `ScratchLab/Models/ControllerInput/ControllerProfile.swift` — `ControllerProfile`,
  `ControllerDeckMapping`, `ControllerControlBinding`, `ControllerProfileDocument`,
  `ControllerProfileStore` (persist/import/export, `controller_profile_v1`, fail-closed).
- `ScratchLab/Models/ControllerInput/MIDIMessageParsing.swift`, `ControllerInputNormalizer`,
  `ScratchControllerInputModels` — device-agnostic parsing/normalisation.
- `ScratchLab/Audio/ScratchPlatterPlayheadMapper.swift` — pure platter→sample mapping
  (+ `forProfile` seam).
- `ScratchLab/Models/ScratchMotionRenderer` + `MotionPath` + `LaneViewport` — the notation
  renderer the captured-notation preview/PNG already draw through.

## What is macOS-only today (in `ScratchLabDesktop/`)

| Component | File | Why macOS-only now |
|---|---|---|
| Core MIDI input transport | `Services/CoreMIDIInputTransport.swift` | Core MIDI client/port; iOS needs its own session-based transport. |
| Controller recognition / active profile / validation / inference / guided session | `Models/ControllerRecognition.swift` | Pure, but currently gated `#if os(macOS)`; logic is portable. |
| Playback Lab model/view/engine | `Models/ScratchPlaybackLabModel.swift`, `Views/ScratchPlaybackLabView.swift`, `Services/ScratchPlaybackLabEngine.swift` | AppKit (`NSOpenPanel`, `ImageRenderer` host), window-menu surface, dev-tool layout. |
| Sample timeline + notation adapter + replay clock | `Models/ScratchSampleTimeline.swift`, `ScratchSampleTimelineNotation.swift` | Pure value types; gated macOS but portable. |
| RANE diagnostic recorder + tester bundle | `Models/RaneDiagnosticRecorder.swift` | Pure; gated macOS but portable. |
| Onboarding copy | in `ScratchPlaybackLabView.swift` | Pure text; portable. |

## Should become shared / iOS later

Pure, no-AppKit pieces that are macOS-gated only by `#if os(macOS)` and would lift cleanly:

1. `ControllerRecognition`, `ActiveControllerProfile`, `ControllerSignalObservation`,
   `ControllerMappingValidation`, `ControllerMappingInference`, `GuidedMappingSession`.
2. `ScratchSampleTimeline` + `CapturedTimelineReplay` + `ScratchSampleTimelineNotation`
   (notation already draws via the shared renderer).
3. `TesterDiagnosticsBundle`, `TesterOnboardingContent`.

These are already unit-tested and have no platform dependency beyond the guard. Moving them to
`ScratchLab/` (and dropping the `os(macOS)` guard) is the bulk of cross-platform parity with
near-zero risk — do it when an iOS controller surface is scheduled, not before.

## Should remain macOS-only (for now)

- `CoreMIDIInputTransport` — iOS wants a `MIDINetworkSession` / USB-host-accessory transport
  behind the existing `MIDITransport` seam, not a port of the macOS client.
- `NSOpenPanel` import and `ImageRenderer`-host PNG export plumbing — re-implement with
  `fileImporter` / `ImageRenderer` on iOS; the render content (`CapturedNotationCanvas`) is reusable.
- The Playback Lab **window** itself — it is a dev/inspection surface (readouts, QA checklist,
  alias diagnostics). iOS should get the *promoted* surface (see below), not this window.

## How the Mac app can feel like the product (not a dev tool)

The Playback Lab is explicitly temporary isolation (see the TODOs in the model/view). To feel
like the iOS product:

- Promote the waveform + platter-driven playhead + captured-notation preview into the main
  Practice surface; demote readouts/alias/QA into Advanced.
- Lead with the captured-notation preview and replay; keep diagnostics one tap away.
- Keep the honest framing already added (estimated / preview / captured notation; the
  onboarding sheet) as the product's voice, not just a tester aside.

## Must match before wider (non-private) release

- Controller-trust parity: the "unverified mapping" warning + active-profile display must exist
  wherever capture happens on either platform (today: Mac only).
- One notation truth: captured-notation rendering identical on both (shared renderer already
  enables this) — no Fit-to-View / vertical compression on either.
- PROFILE.md copy safety enforced on both platforms (the forbidden-phrase test should cover
  shared copy once onboarding moves shared).
- Export schema stability: `controller_profile_v1`, `ScratchSampleTimelineExport`, RANE
  diagnostic v3 unchanged across platforms.

## Can wait until after private DJ testers

- Full MIDI-learn editor + per-profile mapper wiring (today `forProfile` is a no-op seam; the
  mapper still uses built-in constants).
- iOS controller input transport and an iOS Playback/Review surface.
- ZIP (vs folder) tester bundle; profile sync/sharing.
- Promoting the lab into Practice as the default UX.

## Pre-existing dirty files preserved

All other `docs/planning/*` notes and `docs/feature-walkthrough.md` were left untouched. This
file is additive and uncommitted.
