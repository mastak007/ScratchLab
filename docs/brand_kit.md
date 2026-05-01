# ScratchLab Brand Kit

## Brand architecture

### ScratchLab
- Role: pro capture, analysis, and technical workflow
- Audience: DJs, testers, operators, rig reviewers
- Tone: precise, calm, credible, instrument-grade
- Use for: ScratchLab, ScratchLab Mac, ScratchLab Watch, future ScratchLab iOS/tvOS utilities

### Scratch Academy AR
- Role: training, visual learning, guided feedback
- Audience: learners and coaching-first users
- Tone: more expressive and more visual, but still premium
- Use for: AR coaching, progression, lessons, visual correction

### Naming rules
- App family name: `ScratchLab`
- Platform labels:
  - `ScratchLab`
  - `ScratchLab Mac`
  - `ScratchLab Watch`
- Do not use:
  - `ScratchLabDesktop`
  - `Scratch Logger`
  - mixed title styles for the same feature

## Visual identity

### Core palette
- Background base: `#05070B`
- Background mid: `#0B1018`
- Background depth: `#101826`
- Primary accent: `#0EA5E9`
- Signal green: `#22C55E`
- Signal amber: `#F59E0B`
- Signal red: `#F44336`
- Watch accent: `#6366F1`
- Text primary: white
- Text secondary: white at `0.68` opacity

### Palette rules
- Use one accent color per screen plus semantic state colors.
- Keep green, amber, and red for state, not decoration.
- Avoid multi-color feature cards and large rainbow gradients.
- Let the app icon carry the playful record reference; keep the UI more restrained.

## Typography

### Typeface
- Primary: Apple system font (`SF Pro`)
- Numeric/data: system mono where needed (`.monospacedDigit()` or `.system(..., design: .monospaced)`)
- Do not use Futura or tracked all-caps branding for product UI

### Type scale
- Primary screen title: `28` semibold
- Secondary title: `22` semibold
- Section title: `18` semibold
- Body: `13` or `14` medium
- Caption/meta: `11` or `12` medium
- Timer / key numeric status: `24` semibold mono
- Large score / percent: `48` semibold mono

### Type rules
- Default to sentence case or title case.
- Reserve all-caps for small status labels only.
- Do not add tracking to product wordmarks or UI labels.
- Keep weights to regular, medium, semibold, bold.

## UI rules

### Panels and controls
- Prefer dark neutral panels with a thin border.
- Accent should appear in icons, status chips, or one primary action.
- Buttons and cards should stay compact and readable.
- Avoid decorative hero art on operational screens.

### Hierarchy
- Show state before decoration:
  1. recording / live status
  2. sync / device state
  3. current cue or active task
  4. analytics and secondary stats

### Copy
- Keep copy literal and short.
- Prefer `Ready`, `Recording`, `Standby`, `Connected`, `Waiting`.
- Avoid hype language like `Master the art` inside ScratchLab.

## SwiftUI implementation notes
- Use `.font(.system(size: weight:))` for interface text.
- Use `.font(.system(size: weight: design: .monospaced))` for timers, counts, addresses, and percentages.
- Use neutral `RoundedRectangle` panels with light borders.
- Use accent fills for compact chips and one primary action.

## Quick do / do not

### Do
- Make ScratchLab feel like part of the DJ rig
- Use status chips and concise helper text
- Keep Mac as the most technical surface
- Keep Watch as a one-action remote

### Do not
- Make ScratchLab look like a game launcher
- Mix multiple naming styles for the same feature
- Use decorative gradients as the main hierarchy tool
- Let training-brand language bleed into ScratchLab
