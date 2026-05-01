# ScratchLab Current Architecture Reality

## Canonical Truth

- `scripts/` is the canonical dataset contract.
- `scripts/create_session.py`, `scripts/rename_files.py`, and `scripts/validate_session.py` define the current manifest, take-log, naming, and validation rules.
- App-side capture is staging until its output can be validated against that contract.

## Runtime Role

- `ScratchLab` on iPhone is the primary staging capture frontend.
- `ScratchLabWatch` records motion sessions and can be remotely controlled through `WatchConnectivity`.
- `ScratchLabDesktop` is a macOS staging/control surface for analyzer and routine capture workflows.

## Watch Sync Semantics

- Watch control is coordinated as `Mac -> iPhone -> Watch`.
- A watch start request is only synchronized when an explicit acknowledgement is received.
- If no acknowledgement arrives before timeout, the take is degraded, not synchronized.

## Upload Boundary

- The app layer includes upload packaging/client code.
- That does not replace the canonical script contract.
- A package should only be treated as trustworthy when it conforms to the canonical manifest and validation rules.

## Export Boundary

- App export now targets the canonical `session_manifest.json` plus `take_log.csv` structure from the script pipeline, not a parallel app-only schema.
- The canonical gate is fail-closed: missing required audio, missing required slate/clap truth, mixed-session contamination, invalid BPM coverage, or unlinked watch motion all block share/upload/export completion.
- Presence fields must be artifact-backed. Reachability, recent imports, or live input level are not accepted as proof of motion/audio presence.

## Regression Coverage

- The repo now includes a checked-in macOS XCTest target and populated `.xctestplan` files for Phase 1 capture-core regressions.
- Those tests focus on session identity, take identity, watch command payloads, watch ack/timeout behavior, watch-link presence truth, macOS default metadata persistence, same-session export separation, and canonical manifest parity.
- The repo also includes deterministic staging recovery and inspector coverage for interrupted startup recovery, quarantine handling, restore-then-rescan flows, transaction-state reconstruction, and upload-preparation validation blocking.

## Production Operating Boundary

- The app staging/export/recovery layer is now production-grade enough to freeze for staging use.
- That claim applies only to the staging pipeline boundary:
  - staged capture
  - recovery/reconciliation
  - quarantine handling
  - canonical export/share/upload gating
- It does not mean every product surface is production-complete.

## Production Assumptions

- Operators use the staging inspector before export when a session has interruptions, quarantine, or watch involvement.
- Restore is followed by explicit re-scan/reconcile before export is attempted again.
- Canonical export validation remains fail-closed and is never bypassed for convenience.
- The downstream `scripts/` pipeline remains the strongest canonical dataset validator.

## Remaining Caveats

- The transaction journal is explicit and reconstructable, but still file-based rather than database-backed.
- Ambiguous quarantine cases remain intentionally unresolved until an operator can prove ownership safely.
- Automated integration coverage is deterministic and targeted, not exhaustive for every device/network/power-loss timing edge.
