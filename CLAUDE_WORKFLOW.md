# ScratchLab Claude Workflow

Use this file as the standing workflow contract for Claude CLI sessions in `/Users/karlwatson/Downloads/ScratchLab`.

## Fixed modes

### MODE: PLAN
Use for audit, architecture, risk review, and deciding the next slice.

Allowed:
- Read files
- Inspect git status/log
- Produce exact implementation plan
- Recommend verification gates

Forbidden:
- Editing files
- Staging
- Committing
- Pushing

Output:
- Recommendation
- Files likely touched
- Acceptance checks
- Risks
- STOP before implementation

### MODE: IMPLEMENT
Use for scoped, approved code/doc changes.

Allowed:
- Edit only approved files
- Run approved verification scripts/builds
- Show diff/status
- Stage/commit only if explicitly approved

Forbidden:
- Re-planning the whole app
- Expanding scope
- Touching pbxproj unless explicitly approved
- Touching signing, bundle IDs, entitlements, Info.plist, PrivacyInfo.xcprivacy
- Pushing unless explicitly approved

Output:
- Files changed
- Verification results
- Git status
- STOP for review/commit/push approval

### MODE: VERIFY
Use after a commit, push, build, or manual smoke.

Allowed:
- Read diffs/log/status
- Run non-mutating verification commands
- Confirm remote/local state

Forbidden:
- Editing files
- Staging
- Committing
- Pushing

Output:
- Pass/fail table
- Any mismatch
- Next safe action

### MODE: FAST IMPLEMENT
Use only for low-risk UI copy, labels, small SwiftUI layout/status-card tweaks, and docs.

Allowed:
- Edit approved files
- Run focused build/grep gates
- Stage/commit if explicitly bundled in prompt

Forbidden:
- Long architecture recap
- Risk matrices
- AI_HANDOFF edits unless requested
- Tests unless the slice touches logic
- Capture/classifier/export/schema changes
- pbxproj

Output maximum:
- 12 bullets
- Files changed
- Verification
- Git status

## Push workflow

Direct `git push origin main` from Claude Bash may be blocked by the auto-mode classifier.

Preferred recovery:
1. User runs:
   ```bash
   ! git push origin main
   ```
2. Claude runs:
   ```bash
   git status --short --branch
   git log --oneline -6
   git fetch origin main
   git log --oneline origin/main -6
   ```
3. Confirm local HEAD equals origin/main HEAD.

## XCTest selector warning

For `xcrun xctest -XCTest`, use dot-form selectors:

```bash
xcrun xctest -XCTest ScratchLabDesktopTests.BabyPlatterFixtureDecodeTests "$XCTEST_BUNDLE"
```

Do not use slash form with `xcrun xctest`; slash form is for `xcodebuild -only-testing` and can silently run zero tests.

## Build strategy

For tiny macOS SwiftUI/UI copy slices:
- Usually run macOS build only.
- Add iOS build only if shared code changed or the prompt requests it.
- Add build-for-testing only if logic/tests are touched or the prompt requests it.

For risky slices:
- iOS build
- macOS build
- macOS build-for-testing
- targeted `xcrun xctest` if relevant

## Worktree strategy

Use dedicated worktrees when:
- A slice may take more than one session
- You want parallel Claude sessions
- You have local ignored/reference assets in the main tree
- You want easy rollback

Pattern:
```bash
git -C /Users/karlwatson/Downloads/ScratchLab worktree add ../ScratchLab-<slice-name> main
cd /Users/karlwatson/Downloads/ScratchLab-<slice-name>
```

## Deterministic fixture strategy

Prefer fixture-driven QA over manual camera/capture loops where possible.

Good fixture targets:
- Review mixed state
- Raw motion present / no recognized strokes
- Audio-only review state
- Notation rendering
- Phrase timing
- Scoring edge cases
- Fixture-loader debug card

Manual QA remains necessary for:
- Camera permission
- Hand tracking
- Actual capture/record/stop flows
- App Store screenshots
