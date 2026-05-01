# ScratchLab Codex Release Audit Prompt

Use this prompt for the final pre-submission audit:

```text
Run a final full-platform ScratchLab release audit from this repo.

Requirements:
- Audit iOS, macOS, and watchOS release readiness.
- Focus extra attention on files changed since the last successful build/audit recorded in DEV_LOG.md.
- Fix only release-blocking issues.
- Do not redesign flows or visual style unless a release blocker requires a minimal structural fix.
- Do not change bundle IDs, schemes, targets, signing structure, or App Store metadata.
- Update DEV_LOG.md and TASKS.md with the selected audit task, files changed, build result, and remaining risks.
- Run ./scripts/pre_release_check.sh.
- Document any remaining manual risks or verification gaps clearly.

Audit focus:
- Safe-area and layout issues, especially iPhone small-screen paths.
- iOS System Check screen fitting, button reachability, and navigation/back control visibility.
- Session/sidebar clutter rules and shared session behavior.
- Practice beat controls on supported platforms.
- Practice must not create sessions.
- Record flow and validation integrity.
- watchOS launch, capture, and artifact linking.
- Export/schema integrity and canonical metadata behavior.
- App Review compliance and screenshot readiness.

Execution rules:
- Read AI_CONTEXT.md, TASKS.md, and DEV_LOG.md before changing code.
- Prefer minimal, reviewable diffs.
- Reuse shared logic instead of duplicating per-platform behavior.
- If a blocker cannot be safely fixed in a small diff, stop and document it clearly.
```
