# ScratchLab Profile

- Karl Watson, New Zealand.
- Practical, direct, technician-level workflow.
- ScratchLab is a Swift/SwiftUI multiplatform DJ scratch capture, notation, coaching, review, and export app.
- Current beta goal: reliable capture, target notation, Review evidence, audio-onset preview, uncertain timing marks, clean export, Advanced diagnostics.

## Current ML Truth

- exact 23-class recognition is not production-ready.
- CXL-style data works in-domain.
- YouTube/Ortofon external audio/video generalisation failed.
- classifiers are supporting/research signals only for now.
- audio onset timing is the reliable near-term Review/notation path.
- classifier labels must not be used as truth in Practice/Review yet.

## Current Review Truth

- audio-onset preview is preview-only.
- timing marks are not saved.
- timing marks are not exported.
- timing marks are not scored.
- captured notation remains the source of truth.

## App Store / TestFlight Safety

- no overclaiming ML.
- use `estimated`, `preview`, `uncertain`, `on-device audio and motion analysis`.
- avoid `AI detects exactly`, `real-time AI coach`, `deep learning` in user-facing copy.
