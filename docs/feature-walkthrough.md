# ScratchLab Feature Walkthrough

A practical runbook for everything shipped on `release/testflight-1`:
what's on by default, what's behind a flag, how to flip each flag,
and what you'll see when you do.

---

## TL;DR — am I in a gameplay state?

| Layer | Status |
|---|---|
| **Core Practice loop** (pick scratch → run session → score → results) | ✅ Complete & shipped, on by default |
| **Phase A polish** (streak chip, recent sessions, beat pulse, input breathing, session-complete cinematic, honest-failure callout) | ✅ Shipped, on by default |
| **Phase B "feels like a game"** (judgment tint, phrase tint, hit pulses, momentum HUD, progression ladder) | 🟡 Shipped but **flag-off**. Flip flags to enable. Some surfaces wait on upstream data. |
| **Phase C coaching foundations** (event pacer, displayability, contextual tips, drill summary, drift summary card) | 🟡 Shipped but partial — one card (drift summary) renders empty until evaluator wiring lands. |
| **Phase D Studio (macOS)** (Studio tab, scrubber, archaeology charts, notation video exporter) | 🟡 α-D + α-DX checkpoint shipped; macOS-only; empty session data until plumbing lands. |
| **Phase E Instructor** | ⛔ Blocked on D-A7 + D-S6 |

**Verdict:** Yes — the gameplay loop is finished. The Phase B game-feel
layer is ready to play with by flipping flags; the existing
`gamefeel-*` tags do it for you. Before going further on coaching
depth, the next minor slice is wiring `DriftCoachingEvaluator` into
the running Practice session so the C1 card populates.

---

## Three ways to flip a flag

Every Phase B/C/D flag accessor in
`ScratchLab/Models/FeatureFlags.swift` reads three things in order:

1. **Env override (highest priority)**: `SCRATCHLAB_FF_<KEY>=1`
   (Xcode: Scheme → Edit Scheme → Run → Arguments → Environment
   Variables). Accepts `1/true/yes/on` or `0/false/no/off`.
2. **DEBUG default** if running a Debug build.
3. **Release default** if running a Release build.

Examples:

```
SCRATCHLAB_FF_LANE_JUDGMENT_TINT=1     # turn judgment tint on
SCRATCHLAB_FF_STUDIO_MODE=1            # show the macOS Studio tab
SCRATCHLAB_FF_PHRASE_MOMENTUM_HUD=0    # force phrase HUD off
```

Or use the pre-made cumulative test branches/tags
(stacks each Phase B layer on top of the previous):

```
git checkout gamefeel-1-judgment-tint   # B1 only
git checkout gamefeel-2-phrase-pulse    # + B2 (phrase tint + hit pulses)
git checkout gamefeel-3-momentum        # + B3 (momentum HUD)
git checkout gamefeel-4-progression     # + B4 (unlock ladder + in-session bar)
```

Return to mainline: `git checkout release/testflight-1`.

---

## Phase A — already on (sanity smoke)

Nothing to flip. Open the app and confirm:

| Surface | Where to look |
|---|---|
| Streak chip | LevelSelect header (iOS Live Practice). Shows "Start a streak" or "Day N". |
| Recent sessions strip | LevelSelect, below the header. Cards for last 5 sessions with accuracy %. |
| Beat pulse | Practice mode action-line opacity gently pulses on each beat (when BPM is set). |
| Input breathing | Practice mode action-line shifts a couple points forward as mic input rises. |
| Session-complete cinematic | After a Practice session ends, the Results overlay stages reveal (~700 ms total). |
| Honest-failure callout | Finish a session with 0 or 1–2 mic attempts → the Results overlay shows a "didn't pick up any attempts" / "only a few attempts" advisory. |

---

## Phase B — game-feel (flag-gated; ship-safe)

All Phase B flags are release-default-false. Each flag is a small,
visual-only layer over the existing notation lane / Practice HUD.

### B1 — Lane judgment-color states · `LANE_JUDGMENT_TINT`

**What it does:** Strokes on the notation lane recolor based on
existing `coachingKinds`:
- `.lateReversal` → warning (amber)
- `.earlyReversal` → info (blue)
- otherwise → today's `Color.primary`

**Caveat:** Production adapters currently emit empty `coachingKinds`,
so the tint only fires when the coaching pipeline (C0a) has a real
event source plumbed. In DEBUG mode you can see it via the
`DebugNotationLaneHostView` replay preset → fixture strokes already
carry `.lateReversal` / `.earlyReversal`.

**Steps:**
1. `git checkout gamefeel-1-judgment-tint` (or set
   `SCRATCHLAB_FF_LANE_JUDGMENT_TINT=1`).
2. Open the iOS Practice surface for any scratch.
3. (Real effect appears when a stroke has a tinted `coachingKind` —
   most visible in the DEBUG host until C0a wiring lands.)

### B2 — Phrase boundary tints + per-hit micro-feedback · `LANE_PHRASE_TINT` + `LANE_MICRO_FEEDBACK`

**Two flags, one slice:**
- `LANE_PHRASE_TINT` paints a 6% headingCyan wash over alternating
  phrases on `NotationLaneGeometryView`.
- `LANE_MICRO_FEEDBACK` paints a 180 ms ease-out ring on `ScratchMotionLane`
  every time `userEvents.endTime` lands near `now`. Reduce-Motion
  skips the pulse path.

**Caveat:** Phrase tints only render when the caller passes phrase
boundary data. Today only `DebugNotationLaneHostView` does. The
micro-feedback ring works in production when `laneUserEvents` has
real entries (which it does during scored Practice modes).

**Steps:**
1. `git checkout gamefeel-2-phrase-pulse` (adds to B1).
2. Run Practice and play your scratch. Watch the lane: every time a
   stroke completes, a brief ring blooms at the attempt position.
3. For the phrase tint, open the DEBUG Notation Lane Host
   (Advanced → DEBUG menu → Notation Lane) → `.replay` preset →
   toggle "Substrate overlay (debug)".

### B3 — Phrase release tail + phrase-streak HUD · `PHRASE_MOMENTUM_HUD`

**Two pieces, one flag:**
- A brief horizontal fade on `ScratchMotionLane` at phrase end (clamped
  ≤ 0.6 s). Reduce-Motion skips the fade.
- A `Phrases in a row` chip in the `PracticeModeView` HUD row,
  rendered when `phraseStreakCount > 0`.

**Caveat:** Both pieces have **renderer-ready paths but no upstream
data source yet**:
- The lane never sees release-tail data (waits on Phase C2 phrase
  coaching plumbing).
- The chip never increments above 0 in production (waits on Phase C2
  phrase-window verdict source).

You can see them populate with synthetic data only via tests or by
manually injecting state.

**Steps:**
1. `git checkout gamefeel-3-momentum`.
2. Run Practice. Visual difference today is zero in production —
   data is the blocker, not the renderer.

### B4 — Progression visibility · `UNLOCK_LADDER` + `IN_SESSION_MOMENTUM`

**Two flags, one slice:**
- `UNLOCK_LADDER` adds a horizontal "AVAILABLE NEXT" pill row in
  `LevelSelectView` showing each practice scratch — filled green for
  mastered, dim white for in-progress, hollow for untouched.
- `IN_SESSION_MOMENTUM` adds a 2 pt thin progress bar directly under
  the countdown timer in Practice, growing from 0 → 1 as the session
  elapses.

**Steps:**
1. `git checkout gamefeel-4-progression` (final cumulative tag).
2. Open LevelSelect → expect to see the small "AVAILABLE NEXT" pills
   above the scratch cards.
3. Tap a scratch → start a Practice session → expect a thin green
   bar that grows under the timer.

---

## Phase C — coaching foundations (partial)

Phase C foundations are shipped; this is the section where one card
ships *renderer-only* and needs upstream wiring to actually appear.

### Contextual practice tips · `CONTEXTUAL_TIPS`

**What it does:** Replaces the random `tips.randomElement()` pick in
`PracticeModeView.startSession()` with a deterministic
`PracticeTipPicker` that reads ProgressManager state:
- 0 practice runs of this scratch → first-session contextual tip
- 3+ day gap → returning contextual tip
- currentStreak ≥ 2 → active-streak contextual tip
- otherwise → rotates through the scratch's own tips deterministically

**Steps:**
1. `SCRATCHLAB_FF_CONTEXTUAL_TIPS=1`.
2. Start a Practice session you haven't done before → expect the
   "First time on this one — move slowly through the pattern" copy.
3. Practice 2+ days running, then start again → expect "Same beat,
   same window. Hold onto what is already working."

### Structured drill summary · `STRUCTURED_DRILLS`

**What it does:** A quiet "DRILL SUMMARY" card appears in the
Results overlay after a combo / drill session, reading three honest
counters (repetitions, landed/expected, subskill name).

**Steps:**
1. `SCRATCHLAB_FF_STRUCTURED_DRILLS=1`.
2. From LevelSelect, run the **Baby Flow combo challenge** (the
   yellow Combo card).
3. After the session ends, scroll the Results overlay → expect the
   DRILL SUMMARY card under the stats grid.

### Drift coaching summary card · `RESULTS_DRIFT_COACHING`

**What it does:** Renderer for up to 3 observational items per
session, tagged advisory or primary tier. Verb-softened copy
("appears to land after the expected beat") for advisory; catalog
copy verbatim for primary.

**Caveat:** ⚠️ Currently renders **nothing** in production because
`PracticeModeView.driftCoachingSummary` returns `nil` until the
upstream `DriftCoachingEvaluator` + `CoachingEventPacer` +
`CoachingEventDisplayabilityResolver` chain is wired against the
running session. **This is the next minor C slice.**

**Steps:**
1. `SCRATCHLAB_FF_RESULTS_DRIFT_COACHING=1`.
2. Run a Practice session.
3. Expect to see **no change** today — the card stays absent. Will
   appear once the upstream wiring slice lands.

### DEBUG-only: coaching pipeline · `COACHING_EVENTS_PIPELINE`

DEBUG-default-true (release-false). The
`SessionReplayPresentationAdapter` will attach `.lateReversal` /
`.earlyReversal` coaching kinds to strokes when caller passes
`[CoachingEvent]`. This is what lets B1 judgment tinting and C1's
future card eventually populate. No user-visible surface today.

---

## Phase D — Studio (macOS only)

Studio Mode is macOS-only. The flag-gated tab appears between the
existing **Review** and **Advanced** tabs in the macOS app.

### Foundation · `STUDIO_MODE`

**Steps:**
1. `SCRATCHLAB_FF_STUDIO_MODE=1` on the **`ScratchLabDesktop`** scheme.
2. Launch the macOS app → expect a new **Studio** tab with the
   `rectangle.stack.fill` icon.
3. Sidebar lists existing `RoutineSessionStore.sessions` in
   last-activity-descending order. Selecting one shows the host
   pane (header + "coming soon" card by default).

### D-A1 — Replay scrubber · `STUDIO_SCRUB`

**What it does:** Adds a scrubber primitive under the session
header: slider, play/pause, 0.25× / 0.5× / 0.75× / 1× rate picker.
Audio rate stays 1.0× — visual inspection only.

**Steps:**
1. Set `STUDIO_MODE=1` and `STUDIO_SCRUB=1`.
2. Pick a session in the Studio sidebar.
3. Expect a quiet "Scrubber" card with a time readout, slider, play
   button, and rate picker. Reduce-Motion disables auto-playback;
   slider still scrubs.

### D-A2 — Archaeology charts · `STUDIO_ARCHAEOLOGY`

**What it does:** Three read-only chart panels:
- Phrase drift heatmap
- Session timeline dot row
- Release-tail durations bar chart

Each panel has a "what this shows / what it doesn't" footer.

**Caveat:** ⚠️ The host currently passes `.empty` data; charts
render placeholder empty-state messages until real
`AudioPhraseSummary` + `PhraseBoundaryMapper` + `TimingDrift`
plumbing lands from `RoutineSessionDraft`.

**Steps:**
1. Set `STUDIO_ARCHAEOLOGY=1` (and `STUDIO_MODE=1`).
2. Open Studio → pick a session.
3. Expect three empty-state chart cards.

### D-A3 — Annotation sidecar · model only

`StudioAnnotationDocument` (`scratchlab_studio_annotations_v1`) is
defined and codec-tested. No UI yet — the document type exists
ready for future Studio surfaces and Phase E exchange.

### D-X1 — Notation overlay video export · `EXPORT_NOTATION_OVERLAY_VIDEO`

**What it does:** Writes a transparent ProRes 4444 `.mov` of the
notation/timing layer only (alpha channel preserved) — droppable into
OBS, Premiere, FCP.

**Caveat:** ⚠️ The exporter type exists and the renderer is
deterministic, but there's no UI button to invoke it yet. To smoke
the pipeline today, exercise it from a test or scratch helper.

### D-S0 — Spatial replay projection · pure model

The 3D ribbon projection (`SpatialReplayProjector`) is shipped, with
audio-onset = solid / classifier-derived = dashed honesty grammar
encoded in the type. No AR view yet (D-S1 is the next slice).

---

## Bug fix verification

### Notation Lab Template Demo (macOS) — Baby Scratch repetitions

Recent commit `a4ea922` fixed the macOS Notation Lab where only the
first Baby Scratch repetition was visualised.

**Steps:**
1. macOS app → **Advanced** tab → top selector → **Notation Lab**.
2. Ensure **Template Demo** is selected (not Captured Take).
3. Press the play button in the transport bar.
4. Expect: the notation canvas loops the ~5 s phrase **across the
   full ~42 s of demo audio**. Strokes stay aligned to the playhead
   the entire time. Previously it played once then went blank.
5. Optional: confirm by watching the Audio chip readout count from
   `0.0s` toward `42.8s` while strokes keep painting.

### iOS Practice Demo — no regression

iOS Practice Demo mode was already correct (uses
`baby_reel.json` with explicit demo+copy segments) and was not
touched by the fix. Confirm by:
1. iOS app → pick **Baby Scratch** → choose **Demo** assist mode.
2. Start the session.
3. Expect: notation lane plays through all four reel demo segments
   exactly as before.

---

## Gameplay readiness assessment

### What's complete and live

- Picking a scratch from LevelSelect.
- Running a Practice session with mic input.
- Live notation lane (`ScratchMotionLane`) with action line, beat
  grid, attempt ticks, past-fade mask.
- Combo / drill mode (Baby Flow challenge).
- Score / streak / accuracy counters.
- Results overlay with phased reveal, low-attempts callout, timing
  preview, progress meter.
- Phase A polish (default-on).
- Per-scratch progress badges + recent sessions strip + streak chip.
- macOS Capture / Review surfaces unchanged.
- Notation Lab Template Demo plays through every Baby Scratch
  repetition (bug fix).

### What's ready but flag-off

- Phase B game-feel: judgment-tint, phrase tint, micro-feedback
  pulses, momentum HUD, progression ladder, in-session bar.
- Phase C foundations: pacer + displayability tested; adapter wired
  to drift events in DEBUG.
- Phase C structured-drill summary card (real data, just needs flag).
- Phase C contextual practice tips (real data, just needs flag).
- Phase D-A1 scrubber, D-A2 chart shells, D-X1 video exporter type,
  D-S0 spatial projection — all behind `STUDIO_*` / `EXPORT_*` flags.

### What's stubbed (renderer in, data source pending)

- Phrase momentum streak chip (`PHRASE_MOMENTUM_HUD`) — count source
  needs C2 phrase coaching wiring.
- Phrase release tail fade — needs phrase end times plumbed into
  `ScratchMotionLane`.
- Drift coaching summary card (`RESULTS_DRIFT_COACHING`) — needs
  `DriftCoachingEvaluator` chain into the live session.
- Studio archaeology charts — needs `AudioPhraseSummary` +
  `TimingDrift` derivation from `RoutineSessionDraft`.

### What's missing for the next milestone

- **Closest gameplay polish slice:** wire the existing drift
  evaluator + pacer + displayability chain into `PracticeModeView` so
  the Results drift-coaching card actually populates. This is one
  slice and unlocks the first real Phase C surface in production.
- **Phase B2 phrase boundary visibility plumbed from real captures**
  (rather than only the DEBUG host) — required before Phase C2/C5
  phrase coaching can ship.
- **D-A3 annotations UI** — model exists; needs the Studio surface
  to create / view annotations.
- **D-A7 Studio package export** — γ-D milestone that ultimately
  unblocks Phase E instructor pilots.

### Recommendation

You are at a clean "gameplay state" for TestFlight today:
1. Cut a TestFlight from `release/testflight-1` HEAD (`a4ea922`).
   Default-on surfaces are stable; nothing new is exposed unless you
   flip flags.
2. For internal game-feel testing: use the cumulative `gamefeel-*`
   tags / branches to validate each Phase B layer.
3. Before going deeper on coaching: ship the drift-evaluator wiring
   slice so the C1 card has real data to display.
