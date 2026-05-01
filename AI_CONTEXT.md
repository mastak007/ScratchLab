
# ScratchLab – AI Context

## Overview
ScratchLab is an Apple-platform application for DJ scratch training and high-quality data capture.

It is NOT just a practice app — it is a **data acquisition system** designed to:
1. Capture synchronized multi-device performance data
2. Attach structured metadata to each take
3. Export clean, validated datasets for machine learning and analysis

Supported platforms:
- iOS (primary capture + camera)
- Apple Watch (motion data)
- macOS (control surface + validation + export)

---

## System Architecture

### Core Principle
All platforms must share a **single source of truth** for:
- session configuration
- metadata
- validation rules
- export structure

Current reality:
- `scripts/` is still the canonical dataset contract and strongest validator
- iOS/macOS/watch runtime acts as a staging capture frontend
- app export/upload is only trustworthy when it matches the canonical script contract
- staged app captures must carry globally unique `sessionID` values and deterministic per-session `takeID` values
- watch motion presence is only true when an artifact is explicitly linked to that exact `sessionID` + `takeID`
- watch sync can be `acknowledged`, `timedOut`, `unavailable`, or `notRequested`; degraded states must never be mislabeled as synchronized

Platform differences should exist ONLY in:
- UI layout
- hardware integration

---

## Capture System

A session consists of multiple **takes**.

Each take may include:
- camA video (REQUIRED)
- camB video (OPTIONAL)
- audio (Serato / line-in)
- Apple Watch motion data
- session metadata

---

## Required Capture Rules

- camA is REQUIRED for a valid take
- A take is INVALID if required assets are missing
- Metadata must exist before recording starts
- No silent failures — all invalid states must be explicit

---

## Session Metadata Model

Each session must capture:

- performerName (String)
- bpm (Int)
- scratchType (Enum)
- drillMode (Enum)
- takeDuration (Seconds)
- takeCount (Int)
- handedness (Enum: left/right)
- notes (String, optional)
- deviceInfo (auto-generated)
- sessionID (UUID)
- timestamp (Date)

### Rule
If a field appears in UI → it MUST:
- exist in the model
- be validated
- be persisted
- be exported

---

## Scratch Type System

`scratchType` should be a strongly typed enum, for example:

- baby
- chirp
- transform
- flare_1
- flare_2
- orbit
- stab
- freestyle

This must NOT be free-text.

---

## Data Pipeline

### Flow

1. Create session
2. Configure metadata
3. Record takes
4. Rename takes (operator-controlled)
5. Validate session
6. Export dataset package

---

## File Structure (Expected)

Each session should produce a structure like:

session_/
├── camA/
├── camB/ (optional)
├── audio/
├── watch/
├── take_log.csv
├── metadata.json
└── manifest.json

---

## Validation Rules

Validation MUST fail if:
- camA is missing
- renamed takes do not match `take_log.csv`
- metadata is missing required fields
- files referenced in manifest do not exist

Validation must NEVER silently pass incomplete data.

---

## Export Requirements

Exported session must:
- match actual recorded files exactly
- include all metadata
- include take log
- be deterministic and reproducible

Export formats:
- JSON (metadata + manifest)
- CSV (take log)

---

## macOS Role

macOS is NOT a secondary platform.

It should function as:
- session control surface
- metadata editor
- validation interface
- export manager

macOS must support:
- full session configuration (same as iOS)
- take review / rename
- validation feedback

---

## iOS Role

iOS is the primary:
- camera capture device
- session initiator (if standalone)
- UI for guided capture

Must support:
- full metadata input
- camera preview
- recording control

---

## Apple Watch Role

Apple Watch provides:
- motion data capture

Requirements:
- must sync timestamps with session
- must associate data with correct take

---

## Current Priorities

1. Reliable capture across devices
2. Accurate metadata capture
3. Clean validation system
4. Deterministic export pipeline

---

## Non-Priorities (for now)

- advanced UI polish
- AR features
- real-time ML inference
- multiplayer features

---

## Known Risks

- metadata inconsistency between platforms
- missing camA enforcement
- partial exports
- macOS feature parity gaps
- invalid session states passing silently

---

## Development Philosophy

- correctness over speed
- explicit over implicit
- fail loudly, not silently
- minimal changes per task
- no placeholder logic in production paths

---

## Definition of a Healthy System

A session is considered valid only if:

- all required files exist
- metadata is complete and consistent
- take log matches actual files
- export package is complete and usable without modification

---

## Notes for Agents

- Do NOT invent fields not defined here unless necessary
- Do NOT remove validation rules
- Do NOT weaken requirements to “make things pass”
- If unsure, STOP and ask for clarification
- Always prefer tightening correctness over adding features
