# Staging Operations Runbook

## Purpose

Use this runbook when operating the app-side staging pipeline in production.

This document covers:

- the production trust boundary for staged capture
- how to review staged sessions before export
- what to do when export/share/upload is blocked
- how to handle quarantine, restore, and reconcile safely
- what assumptions still apply even though the staging layer is now production-grade

This runbook does not replace the canonical dataset workflow in `scripts/`. It explains how to operate the iPhone/macOS staging layer so it feeds that canonical workflow safely.

## Production Boundary

Treat the following as true:

- `scripts/` remains the canonical dataset contract.
- iPhone, watch, and macOS app capture remain staging until they pass canonical export validation.
- The staging layer is trusted to fail closed. It must not invent missing metadata, audio presence, motion presence, or synchronization.
- A staged session is ready for export only when the staging inspector shows it as ready and export validation reports no blockers.

Do not treat the following as true:

- a reachable watch means motion is present
- a recent watch import means the current take has motion
- a visible staged file means the take is exportable
- a restored quarantined artifact is automatically safe to export

## Operator Workflow

### 1. Open the Staging Inspector first

Before export, share, or upload:

1. Open the staging inspector from the iPhone or macOS staging surface.
2. Review the summary counts:
   - blocked sessions
   - ready sessions
   - quarantined artifacts
   - restore-blocked quarantine items
3. Review the session you intend to export before attempting the export action.

If the target session is marked `Blocked`, do not keep retrying export. Read the blockers and resolve them first.

### 2. Review the staged session

For each take, inspect:

- `recordingStatus`
- watch sync state
- linked watch artifact file name, if any
- transaction state
- recent artifact history
- last audit event

Use the transaction state as a direct hint:

- `Began, no artifacts written`
  - the capture transaction started but no staged artifact was committed
  - do not assume this take exists
- `Sidecar committed, media missing`
  - metadata was written but the media artifact is absent
  - this blocks export
- `Media committed, finalize missing`
  - media exists, but the staged take was not finalized cleanly
  - run recovery/reconcile before export
- `Finalized`
  - the staged transaction completed
  - this still does not bypass validation

### 3. Handle blocked export

If export/share/upload is blocked:

1. Read the blocking issues listed on the session card.
2. Check the affected take rows and their transaction states.
3. Check quarantine for related artifacts.
4. Use the explicit staging action:
   - `Refresh`
   - `Re-scan`
   - `Reconcile`
5. Re-open the session in the inspector and confirm the blockers are cleared before trying export again.

Common block reasons and safe actions:

- interrupted take recovered
  - inspect the take
  - either keep it quarantined from export or intentionally replace it with a new take
- sidecar committed but media missing
  - do not restore unrelated files into staging
  - inspect quarantine for the matching media artifact
  - restore only if the provenance is clear
  - run re-scan after restore
- media committed but finalize missing
  - run re-scan/reconcile first
  - verify the take state and audit trail after re-scan
- watch linkage missing or invalid
  - verify whether the watch artifact belongs to the same `sessionID` + `takeID`
  - if not proven, leave motion absent and keep export blocked when required
- mixed-session contamination
  - do not override this
  - remove or quarantine the contaminated staged artifact and rescan

## Quarantine Workflow

### What quarantine means

Quarantine means ScratchLab refused to treat an artifact as an active staged file because ownership, completeness, or validity could not be proven safely.

Quarantine is not data loss. It is a safety boundary.

### How to inspect a quarantined item

For each quarantined item, review:

- file name
- session/take, if known
- artifact role
- decision reason
- transaction state
- conflicting origin candidates
- decision history

### When restore is allowed

Restore is allowed only when ScratchLab can identify a single plausible origin and no active staged file already owns that path.

After restore:

1. do not export immediately
2. run the explicit staging re-scan/reconcile action
3. re-open the inspector
4. verify that:
   - the item left quarantine
   - the correct take now owns it
   - the transaction/audit history is coherent
   - export blockers cleared, if expected

### When restore is blocked

Restore stays blocked when origin remains ambiguous.

Typical causes:

- multiple candidate transactions
- multiple candidate session/take owners
- conflicting artifact history

When restore is blocked:

- leave the item quarantined
- use the decision history to identify the likely owner manually
- only move or re-import the file outside ScratchLab if you can prove the intended destination
- do not try to force export around the quarantine state

### Delete versus keep

Delete a quarantined item only when:

- it is clearly a duplicate
- it is corrupt
- it belongs to the wrong session and you no longer need it

Keep it quarantined when:

- provenance is uncertain
- you still need to compare it against other staged artifacts
- the operator has not confirmed whether it should be restored or discarded

## Re-scan and Reconcile Workflow

Use `Refresh` when you only need the current inspector view to reload.

Use the explicit staging action when you need ScratchLab to reevaluate staged files:

- `Re-scan`
  - re-reads staged artifacts from disk
  - refreshes recovery and validation state
- `Reconcile`
  - attempts deterministic linkage, especially for watch artifacts
  - preserves fail-closed behavior when ownership cannot be proven

Run re-scan/reconcile after:

- restoring a quarantined item
- app relaunch after interruption
- watch import completes after the take was already staged
- manual cleanup of staged files

## Upload Preparation

Upload preparation is not a weaker path than export.

If upload preparation is blocked:

- read the exact validation-block message in the staging inspector or upload state
- resolve the same underlying issue you would resolve for export
- do not treat upload as a bypass around local validation

## Production Assumptions

The staging layer is production-grade under these assumptions:

- operators review the staging inspector before export for sessions that had interruptions, quarantine, or watch involvement
- restore is only used after reading the decision context
- re-scan/reconcile is run after any restore
- canonical export validation remains the final gate before share/upload/export
- canonical `scripts/` validation still remains available as the strongest downstream contract check

## Remaining Caveats

These are still true:

- the transaction journal is file-based, not a database-backed write-ahead log
- severe mid-write interruption can still lead to quarantine rather than full automatic reconstruction
- ambiguous restore cases intentionally require operator judgment
- integration coverage is strong for deterministic local scenarios but not exhaustive for every real device/network/power-loss timing sequence

## Recommended Production Practice

For high-value sessions:

1. complete capture
2. open the staging inspector
3. clear blocked or quarantined state first
4. run export/share/upload only after the target session shows ready
5. run the canonical script validator on the exported session package when moving into the final dataset workflow
