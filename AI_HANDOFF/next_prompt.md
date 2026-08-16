Read `AI_HANDOFF.md` first. Top entry = V3.2 beta candidate COMMITTED `7efbb70` (NOT pushed) — AWAITING APPROVAL.
Read `SOUL.md` and `PROFILE.md`.
Report `git status --short --branch`.
Do not commit or push unless explicitly approved.
No `Co-Authored-By` trailer.
No pbxproj edits without separate manual approval.
Do NOT mutate Figma or use Code Connect.

---

# Current state (2026-08-17) — beta candidate committed `7efbb70`, awaiting beta-upload approval

One clean commit `7efbb70` ("V3.2: prepare App Store Connect beta candidate") on
`feature/v3.2-swiftui-20260815` (ahead 19). NOT pushed / NOT uploaded. Both iOS and macOS Release archives
now SUCCEED (development signing).

## Remaining blockers before upload

1. Apple Distribution signing cert (only "Apple Development" present locally).
2. Pre-existing dirty `project.pbxproj`/`xcscheme`/app-icons NOT in `7efbb70` — review + commit before submission.
3. Hardware/manual matrix (Practice/Capture/Review/Advanced journeys + camera/mic/DVS/MIDI/local-network/layout).

## Stop line

Beta candidate committed. Awaiting "Approve Beta Upload". Do NOT push/upload yet.

## Commands before upload (see AI_HANDOFF.md for full list)

- `! git push origin feature/v3.2-swiftui-20260815`
- Commit the pre-existing dirty assets if intended.
- `xcodebuild -exportArchive` with app-store-connect method (needs Apple Distribution cert).
- Upload via Xcode Organizer "Distribute App" or Transporter (altool upload deprecated under Xcode 26).
- `xcrun notarytool` for macOS notarization if needed (Developer ID only, not App Store).

## Verification gate (app-target slice)

1. `xcodebuild build -scheme ScratchLab -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
2. `xcodebuild archive -scheme ScratchLabDesktop -configuration Release -destination 'platform=macOS'`
3. `xcodebuild archive -scheme ScratchLab -configuration Release -destination 'generic/platform=iOS'`
4. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
5. `xcrun xctest -XCTest ScratchLabDesktopTests.<Suite> <bundle>` (dylib-symlink recipe).

`Tools/TrainModels swift test` is NOT required. Hardware validation is HARDWARE REQUIRED — deferred.

Standing rules: no new `.swift` files (pbxproj explicit refs). Preserve unrelated dirty files
(`project.pbxproj`, `ScratchLab.xcscheme`, app icons).
