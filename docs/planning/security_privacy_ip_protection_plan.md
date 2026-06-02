---
title: Security, Privacy, and IP Protection Track
role: Cross-cutting execution plan
status: PLAN ONLY - do not implement from this document alone
source: User-requested security/privacy/IP planning slice
related docs:
  - ./README.md
  - ./ttm_execution_plan_v2.md
  - ../../analysis/kid_mode/KID_MODE_PROTOTYPE_VALIDATION_PLAN.md
  - ../../analysis/kid_mode/KID_MODE_EXPERIMENT_PROTOCOL_V1.md
last updated: 2026-06-01
---

# Security, Privacy, and IP Protection Track

This track is separate from Kid Mode, notation, audio, and TTM execution work. It defines how ScratchLab protects two different classes of sensitive data:

1. **User-sensitive data:** recordings, child practice sessions, names, scores, videos, watch motion, exports, and session metadata.
2. **ScratchLab-sensitive IP:** technique models, notation grammar, TTM-derived research, analytics, tuning constants, internal diagnostics, evaluation data, and research documents.

Policy baseline:

> Default = local, private, minimal, encrypted where sensitive. Export/share = explicit user action only. Research/debug data = DEBUG-only and never in release.

## Current Surface Snapshot

Read during this planning pass:

- `ScratchLab/PrivacyInfo.xcprivacy` and `ScratchLabDesktop/PrivacyInfo.xcprivacy` declare no collected data, no tracking, and accessed API reasons for UserDefaults, file timestamps, and system boot time.
- `ScratchLab/Info.plist` declares camera, microphone, local network, document-opening, and audio background mode usage.
- `ScratchLabDesktop/Info.plist` declares camera, microphone, and local network usage.
- `ScratchLabDesktop/ScratchLabDesktop.entitlements` enables sandboxing, camera/audio input, user-selected read-write files, and local network client/server access.
- `ScratchLab/Services/SessionExportCoordinator.swift` builds ZIP exports with media, watch CSV, `session_manifest.json`, `take_log.csv`, `session_metadata.json`, `export_metadata.json`, `session_review.json`, `session_replay.json`, detected notation JSON, confidence/source fields, device metadata, and user metadata.
- Current write paths are spread across `SessionExportCoordinator`, `CaptureCore`, `StagedCaptureRecovery`, `WatchMotionCaptureStore`, `SessionUploadManager`, `CompanionCameraBroadcaster`, `CompanionCameraReceiver`, `CXLNotationCapture`, `MacCaptureEngine`, `RaneDiagnosticRecorder`, `SampleManager`, `BackingTrackManager`, and Studio annotation/playback lab models.
- `ScratchLab/Views/KidPrototypeView.swift` states that the current Kid prototype records nothing. `ScratchLab/Models/FeatureFlags.swift` currently makes `kidPrototypeEnabled` DEBUG-default true, which should be re-evaluated before any research logging or child-facing study build.

## 1. Threat Model

| Surface | Main risk | Required stance |
|---|---|---|
| User recordings | Audio/video privacy, faces, household/environment capture, child privacy | Local-only by default, protected files, explicit export/share only |
| Child practice data | Consent and behavioral profiling risk | Avoid names/ages, minimize, anonymous local session IDs, no cloud analytics |
| Research logs | Child data, experiment consent, accidental release bundle leakage | DEBUG-only, opt-in, local-only, no faces, no release build code path |
| Session exports | User data plus internal IP leakage | User-triggered only, sanitized, deterministic, no internal diagnostics/provenance |
| Model artifacts | ScratchLab IP and overclaiming risk | Keep out of app bundle unless explicitly approved; no raw evaluation data in public exports |
| Internal diagnostics | IP leakage, misleading App Review surface | Advanced/DEBUG only as appropriate; never exported raw unless explicitly user-facing |
| Bundled resources | Copyright/provenance/App Review risk | Ship only runtime-safe assets; no `analysis/`, research docs, local paths, or source provenance |
| App statistics | Behavioral data and privacy manifest mismatch | Do not collect by default; aggregate locally only if needed |
| API keys/secrets | Account compromise | Never in repo or bundle; Keychain only |

## 2. Data Classification Model

Future saved files/logs should carry an explicit classification at write time:

```swift
enum ScratchPrivacyClassification: String, Codable {
    case publicAsset
    case userRecording
    case userPracticeStats
    case researchLog
    case internalDiagnostics
    case modelArtifact
    case exportPackage
    case secretOrKey
}
```

Definitions:

- `publicAsset`: bundled demo audio/art/UI resources safe to ship.
- `userRecording`: captured audio, video, watch motion, raw takes, sidecars, and session media.
- `userPracticeStats`: timing, attempts, scores, streaks, progress, and child-linked outcomes.
- `researchLog`: experiment observations, Kid Mode validation logs, counterbalance/order data, and researcher notes.
- `internalDiagnostics`: confidence dumps, debug counters, local paths, device IDs beyond user-facing metadata, detector internals.
- `modelArtifact`: ML models, evaluation fixtures, tuning constants, notation grammar experiments, TTM-derived research outputs.
- `exportPackage`: ZIP/session packages prepared for user sharing.
- `secretOrKey`: encryption keys, API tokens, license/unlock codes, sensitive research unlock flags.

## 3. Storage Policy

| Category | Allowed storage | Backup | File protection | App encryption | Exports | App bundle |
|---|---|---:|---:|---:|---:|---:|
| `publicAsset` | App bundle resources | N/A | No | No | Yes, if user-facing | Yes |
| `userRecording` | App container Application Support or Documents when user-visible | Avoid backup for temporary/staged captures; user-visible documents may back up | Yes, strongest available (`complete` on iOS where practical) | Recommended for highly sensitive sidecars/stats | Yes, explicit user action only | No |
| `userPracticeStats` | Application Support | Usually no for child-linked stats; aggregate if backed up | Yes | Recommended when identifiable/child-linked | Only summarized and user-triggered | No |
| `researchLog` | DEBUG-only local Application Support or temporary experiment folder | No | Yes | Recommended | No production export schema | No |
| `internalDiagnostics` | DEBUG/Advanced local diagnostics | No unless user explicitly saves diagnostics | Yes when linked to sessions | Optional, based on content | No raw export by default | No release bundle |
| `modelArtifact` | Development-only local/private storage; explicit approved runtime resource if needed | No | Yes if local | Recommended for private evaluation payloads | No | Avoid; never without approval |
| `exportPackage` | Temporary export staging then user-selected destination/share sheet | User-controlled after export | Yes while staged | Optional; do not silently encrypt user ZIPs without UX | Yes | No |
| `secretOrKey` | Keychain | Keychain-managed | Keychain-managed | N/A | Never | Never |

Concrete current paths to audit in S0:

- `ScratchLab/Services/SessionExportCoordinator.swift`
- `ScratchLab/Models/CaptureCore.swift`
- `ScratchLab/Services/StagedCaptureRecovery.swift`
- `ScratchLab/Services/WatchMotionCaptureStore.swift`
- `ScratchLab/Services/SessionUploadManager.swift`
- `ScratchLabDesktop/Services/MacCaptureEngine.swift`
- `ScratchLabDesktop/Services/CXLNotationCapture.swift`
- `ScratchLabDesktop/Models/RaneDiagnosticRecorder.swift`
- `ScratchLabDesktop/Models/ScratchPlaybackLabModel.swift`

## 4. Encryption And Key Plan

- Use Keychain for encryption keys, API tokens, license/unlock codes, and sensitive research unlock flags.
- Do not store secrets in `UserDefaults`, plain JSON, `Info.plist`, Swift constants, bundled resources, or Git.
- Use iOS/macOS file protection where available for user recordings, sidecars, child-linked stats, research logs, staged exports, and diagnostic captures.
- Use CryptoKit `SymmetricKey` only for app-level encrypted payloads that need protection beyond platform file protection.
- Store app-level encryption keys in Keychain with accessibility appropriate to the feature. Do not derive keys from device names, session IDs, or hard-coded constants.
- Do not introduce cloud sync, cloud upload, or analytics SDKs until a separate consent, retention, deletion, and privacy-manifest design exists.

Good app-level encryption candidates:

- Capture session sidecars with user identity/device metadata.
- Practice stats linked to a child or named performer.
- Research logs.
- Private model/evaluation exports.

Low-value encryption candidates:

- Bundled demo audio.
- Public help copy.
- Generated UI assets.
- Anonymous aggregate counters that cannot be tied back to a person/session.

## 5. Export Sanitizer Plan

Add a future `ScratchExportSanitizer` before ZIP/session export finalization. It should run on the export model before files are written into the staging directory in `SessionExportCoordinator`.

Session ZIP exports must not leak:

- Internal debug fields.
- Local file paths.
- Classifier confidence dumps unless explicitly user-facing and documented.
- Research-only metadata.
- Source/provenance fields.
- Child identifiers.
- Private model/evaluation data.
- Raw timing logs unless the user explicitly includes them.
- Device unique IDs unless clearly necessary and user-facing.
- `analysis/`, TTM research documents, MakeMKV/Qbert/source-reference strings, or rights/provenance metadata.

Current export fields that need sanitizer decisions in S0/S3:

- `SessionExportNotationDocument.labelConfidence`, `notationConfidence`, event `confidence`, and event `source`.
- `SessionExportDeviceInfo.videoDeviceUniqueID` and `audioDeviceUniqueID`.
- `session_review.json`, `session_replay.json`, and detected notation JSON.
- File names generated from performer/session metadata.
- Staged paths copied from media/audio/watch artifacts.

## 6. Kid Mode Research Data Policy

Kid Mode research logging is not part of production capture/export.

Requirements:

- Compile research logging behind `#if DEBUG` unless a formal consent flow exists.
- Require an explicit runtime flag separate from `kidPrototypeEnabled`.
- Local-only by default.
- No face capture.
- No child names by default.
- Use anonymous session IDs such as `kid_session_2026_06_01_001`, not names/ages.
- No cloud upload.
- No silent analytics.
- No production export schema.
- Explicit parent/participant consent for experiments.
- Release builds should compile out research logging entirely.

Current risk to resolve before research logging:

- `FeatureFlags.kidPrototypeEnabled` is currently DEBUG-default true. Before any child-facing research logging exists, add a separate `kidPrototypeResearchLogEnabled` flag that is release-default false and DEBUG-default false, and ensure the log code cannot compile into release behavior.

## 7. App Review And Privacy Manifest Audit Checklist

Audit before TestFlight/App Store submission after any storage/log/export changes:

- `ScratchLab/Info.plist`
  - `NSCameraUsageDescription`
  - `NSMicrophoneUsageDescription`
  - `NSLocalNetworkUsageDescription`
  - `UIBackgroundModes`
  - `LSSupportsOpeningDocumentsInPlace`
- `ScratchLabDesktop/Info.plist`
  - `NSCameraUsageDescription`
  - `NSMicrophoneUsageDescription`
  - `NSLocalNetworkUsageDescription`
- `ScratchLab/PrivacyInfo.xcprivacy`
- `ScratchLabDesktop/PrivacyInfo.xcprivacy`
- `ScratchLabDesktop/ScratchLabDesktop.entitlements`
- App Store privacy answers.
- No undeclared tracking.
- No hidden data collection.
- No research/debug files in release bundle.
- No `analysis/` directory, research-only docs, model-evaluation files, or private provenance in app resources.
- Permission copy must match actual behavior and avoid unsupported claims.

If ScratchLab starts storing identifiable practice stats, collecting child-linked data, exporting diagnostics, or uploading anything, the privacy manifests and App Store privacy answers must be updated in the same slice.

## 8. Implementation Roadmap

Each slice should be small, reviewable, and independently verifiable.

### Phase S0 - Audit Write, Export, And Bundle Paths

Goal: find every file written, exported, or bundled.

Tasks:

- List every write path.
- List every export path.
- List every bundled analysis/research/resource file.
- Grep for `analysis/`, `TTM`, `Qbert`, `MakeMKV`, `sourceReference`, `rightsStatus`, local `/Users/` paths, and private dataset names.
- Check `PrivacyInfo.xcprivacy`.
- Check `Info.plist` permission strings.
- Check entitlements.
- Produce an audit table mapping path -> classification -> owner -> required change.

### Phase S1 - Add Data Classification Enum

Goal: every saved/exported thing gets a privacy class.

Tasks:

- Add `ScratchPrivacyClassification`.
- Add classification arguments to new sensitive write sites.
- Add tests that sensitive write helpers cannot omit classification.
- Do not retrofit every path in one large diff; migrate high-risk writes first.

### Phase S2 - Add SecureScratchStorage

Goal: route sensitive writes through one API.

Target shape:

```swift
SecureScratchStorage.write(data, classification:)
```

Responsibilities:

- Write into the app container.
- Apply file protection where supported.
- Optionally encrypt payloads.
- Exclude temporary/staged sensitive files from iCloud backup where appropriate.
- Block DEBUG/research logs from release.
- Keep keys in Keychain, not source or defaults.

### Phase S3 - Add Export Sanitizer

Goal: exports are user-safe and IP-safe.

Tasks:

- Add `ScratchExportSanitizer`.
- Sanitize `SessionExportCoordinator` model documents before ZIP staging.
- Add snapshot tests for export ZIP contents.
- Keep user-facing metadata, media, watch data, and validated notation intact.
- Remove internal diagnostics/provenance/research fields.

### Phase S4 - Gate Research Logs

Goal: Kid Mode logs are DEBUG-only and opt-in.

Tasks:

- Add `kidPrototypeResearchLogEnabled`, DEBUG-default false and release-default false.
- Compile research logging behind `#if DEBUG`.
- Write local-only logs via `SecureScratchStorage`.
- Prove release source/binary cannot create research logs.

### Phase S5 - Add Privacy And Export Invariant Tests

Goal: make regressions hard.

Tasks:

- Release bundle contains no `analysis/`.
- Release bundle contains no research-only docs.
- Export ZIP excludes internal fields.
- Research logs unavailable in release.
- Secrets not stored in `UserDefaults`.
- Sensitive files use protected storage where available.

### Phase S6 - App Review And Manifest Verification

Goal: declared data use matches actual behavior.

Tasks:

- Re-check `PrivacyInfo.xcprivacy`.
- Re-check `Info.plist` permission strings.
- Re-check App Store privacy answers.
- Confirm in-app copy describes local/export behavior truthfully.
- Verify no cloud sync/upload exists unless explicitly designed and declared.

## 9. Test Plan

Add grep/audit tests and focused unit tests:

- Release bundle contains no `analysis/`.
- Release bundle contains no research-only docs.
- Release bundle contains no TTM source media/art/provenance documents.
- Export ZIP excludes internal/debug/research fields.
- Export ZIP excludes local filesystem paths.
- Export ZIP excludes child identifiers unless explicitly user-provided and user-triggered.
- Research logs are unavailable in release builds.
- `KidResearchLog` or successor types are behind `#if DEBUG`.
- Secrets are not stored in `UserDefaults`, `Info.plist`, Swift constants, bundled JSON, or Git.
- Sensitive file writes use `SecureScratchStorage` or an approved equivalent.
- Staged sensitive files use file protection where available.
- Temporary/staged exports are cleaned up.
- Privacy manifests still match actual API/data use.

Suggested command families for S0/S5:

```sh
rg -n "analysis/|TTM|Qbert|MakeMKV|sourceReference|rightsStatus|/Users/" ScratchLab ScratchLabDesktop ScratchLab.xcodeproj
rg -n "UserDefaults.*(token|key|secret|password|license)|apiKey|API_KEY|secret" ScratchLab ScratchLabDesktop
rg -n "write\\(to:|copyItem|createDirectory|temporaryDirectory|applicationSupportDirectory|documentDirectory" ScratchLab ScratchLabDesktop
```

## 10. Clear Non-goals

- Do not build cloud sync yet.
- Do not add an analytics SDK.
- Do not encrypt public bundled assets unnecessarily.
- Do not overbuild enterprise security before validation.
- Do not change export schema as part of planning.
- Do not add Kid Mode research logging until S0-S4 decisions are made.
- Do not ship model/evaluation artifacts or TTM-derived research data in the app bundle without explicit approval.
- Do not silently collect practice data, camera frames, face video, audio recordings, or identifiable stats.

## Immediate Recommendation

Run Phase S0 before any real Kid Mode research logging, session analytics, or broader notation/model artifact export work. For the current audio/Kid prototype state, no sensitive research data should be stored yet.
