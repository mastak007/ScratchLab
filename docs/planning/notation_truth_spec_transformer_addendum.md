# ScratchLab Notation Truth — Transformer Addendum (Version 1.1)

**Companion to:** `notation_truth_spec.md` (Version 1). This addendum does **not** rewrite V1.
It records only what the **Transformer Scratch** video adds or changes.

**New source:** `transformer notation.mp4` (1:23, 1108×720, 30 fps). Same authority as the other
notation videos. Same reference renderer ("Scratch Visualizer - by SXRATCH"), shown here in two
modes: the windowed app (dark theme) and a full-screen "big-screen" presentation.

**Sample:** continuous ("ahhh"-type), as with the non-Baby scratches.

---

# Transformer analysis

## Motion lane
- **Platter movement:** slow, steady, **largely continuous** hand motion. At `@0:12` it is a clean
  **triangle wave** — even forward ramps and even backward ramps (the record pushed and pulled at a
  steady speed). At `@0:55` the motion is faster and busier, but still a continuous oscillation.
- **Direction changes / reversal points:** the motion still reverses at the tops and bottoms of the
  triangle (dots/turns as in V1). But — and this is the central finding — **the reversals are NOT
  what define the scratch.** The number of audible sounds is far greater than the number of
  reversals.
- **Stroke shapes:** straight-ish ramps (triangle) at slow tempo (`@0:12`); a forest of taller and
  shorter strokes at speed (`@0:55`, `@1:15`). Crucially, each ramp is **drawn dashed / segmented**:
  one continuous platter ramp is rendered as a row of colinear bright dashes separated by gaps. The
  dashes lie *on the same straight line* — they are one motion, not many micro-reversals.

## Fader lane
- **Click pattern:** a **rapid, repeated open/close tap train** — the "transform" rhythm. The fader
  hand is visibly working the mixer (right hand on the mixer/faders at `@0:12`, `@0:55`) while the
  left hand does the slow platter motion.
- **Open/closed timing:** each **bright dash = fader OPEN (audible)**; each **gap / dim section =
  fader CLOSED (muted)**. In the big-screen mode (`@1:15`) the closed sections are drawn **dim**
  (the curve is continuous but darkens); in the windowed mode (`@0:12`) the closed sections are
  near-black gaps, so the ramp looks dashed.
- **Relationship to audio bursts:** **one fader open = one audio burst.** The dash spacing *is* the
  burst rhythm. Objective check: counting fader-gated silence gaps gives ~30/10 s for Chirp, ~14/10 s
  for this Transformer window, ~7/10 s for Baby — i.e. fader-driven scratches are densely gated
  while Baby (fader open) is not.

## Audio relationship — exactly how the sound emerges
The audible signal is the **product of three things, in this order of contribution for Transformer**:
1. **Crossfader state (open/closed)** decides *whether* sound exists at each instant, and therefore
   *how many* bursts you hear and *with what rhythm*. This is the dominant, rhythm-defining input.
2. **Platter motion (position/velocity)** decides the *pitch and direction* of whatever is audible
   during each open window (a forward ramp = rising pitch sound; backward ramp = reverse sound).
3. **Sample position** decides *which part of "ahhh"* is exposed in each burst.

So for one continuous platter ramp, the fader carves it into N bursts; each burst's tone is set by
where the ramp was when the fader was open. **The same platter motion with a different fader pattern
is a completely different scratch.** That is the whole point of the Transformer.

## Notation grammar impact
- **New primitive — one-to-many (motion→audio):** a *single* motion stroke can contain *multiple*
  audible events. V1 implicitly assumed (outside Chirp) roughly one audible event per stroke /
  reversal. Transformer breaks that assumption explicitly.
- **New primitive — audio segmentation along a stroke:** audibility must be expressible **per
  sub-segment of a single stroke**, not just per stroke.
- **New symbol/encoding — trace gating:** fader state is here shown as **brightness/colour of the
  motion trace itself** (bright cyan/green = open, dim/gap = closed). This is a *third* fader
  representation alongside V1's "separate square-wave lane" and "shaded off-band". For dense fader
  work this gating becomes the clearest representation.
- **Possible new marker — click onset (green):** short **green** segments recur at burst onsets /
  stroke turns, distinct from the steady cyan of a sustained-open window. Best read as **the click
  (fader-open onset) marker**. (Colour nuance not 100 % resolvable at this resolution — flagged.)
- **New rendering requirement:** render audibility at sub-stroke resolution (gate/colour the trace),
  not merely as a stroke-level attribute.
- **New timing requirement:** **click timing must be encoded explicitly and at high temporal
  resolution**, independent of the motion-sampling rate. The click rhythm is the musical content; if
  click times are quantised to motion reversals the Transformer is unrepresentable.

---

# Universal grammar review (every V1 Part-2 rule)

| V1 rule | Verdict | Why |
|---|---|---|
| 1. Two lanes, one shared time axis | **Strengthened** | Transformer makes the fader an independent event generator; the second timeline is not optional. (See A-vs-B below.) |
| 2. Vertical = sample/platter position | **Confirmed** | Triangle ramps at `@0:12` are clean position-over-time. |
| 3. Rising = forward, falling = reverse | **Confirmed** | Unchanged. |
| 4. Slope = speed | **Confirmed** | Steady ramps = steady speed; dashes are colinear (constant slope). |
| 5. Height = displacement | **Confirmed** | Strokes vary in height with reach (`@1:15`); unchanged. |
| 6. Dot at every abrupt reversal | **Confirmed** | Reversals still marked — but demoted in importance (reversals no longer equal audible-event count). |
| 7. Crescent = smooth reversal | **Confirmed** | Not contradicted (no crescents required by Transformer). |
| 8. Audio = motion AND fader-open; motion always drawn | **Strengthened + refined** | The AND rule is now *visibly* the generating principle. Refinement: a muted move may be drawn very **dim** (big-screen) or reduced to a **gap** (windowed) — audibility styling can approach invisibility. |
| 9. Hold = flat segment | **Confirmed** | Unchanged. |
| 10. Reverse variants mirror vertically | **Confirmed** | Unchanged. |
| 11. Curves, not straight lines | **Confirmed (with nuance)** | Slow Transformer ramps are near-straight by nature; the smooth-curve rule still holds for the hand's actual motion. |
| 12. Amplitude faithful, not per-stroke normalised | **Confirmed** | `@1:15` shows large and small strokes coexisting; not levelled. |

**Net:** no V1 rule is **Weakened** or **Invalidated**. The two that change both move *up*
(Strengthened): the two-lane model (rule 1) and the audibility/AND model (rule 8).

**One V1 framing IS corrected (not a Part-2 rule, but a tone):** V1 repeatedly described the motion
lane as "large/primary" and the fader lane as "thin/short", implying a *motion-first* hierarchy.
The Transformer shows that hierarchy is wrong for an entire scratch family. See below.

---

# The fundamental question: A vs B

> A. Motion-first with fader annotations &nbsp;&nbsp;|&nbsp;&nbsp; B. Two equal timelines (motion + fader)

**Answer: B — two equal, independent timelines.** The Transformer is the decisive proof.

Direct evidence:
1. **A single continuous platter motion produces many distinct audible events** (`@0:12`: one clean
   triangle ramp rendered as a row of dashes; `@1:15`: single long strokes carrying multiple
   bright/dim segments). The count and rhythm of those events live **entirely in the fader**, not in
   the motion.
2. **The motion lane alone is insufficient to describe the scratch.** From the ramp at `@0:12` you
   cannot recover how many sounds are heard or their timing — that information exists only in the
   fader timeline. An "annotation on motion" cannot carry a rhythm the motion does not contain.
3. **The fader is the dominant rhythmic generator here** (the hands are split: platter = slow tone,
   mixer = fast rhythm). Two independent performers/timelines, multiplied together.
4. **Symmetry of necessity:** fader alone gives rhythm but no pitch/direction; motion alone gives
   pitch/direction but no rhythm. Neither is reconstructable from the other → they are co-equal.

Therefore the notation system is **B**. Model A is adequate *only* for the fader-open family
(Baby, Tear, Boomerang) where the fader timeline happens to be a flat "open" line — but that is a
degenerate case of B, not evidence for A.

---

# ScratchLab implications

**Can the current ScratchLab notation architecture represent the Transformer correctly? No.**

The V1 audit already found ScratchLab missing a crossfader lane and variable height. The
Transformer makes the gap categorical: ScratchLab's notation is a **motion-only, single-curve**
model, and the Transformer is *defined* by the dimension ScratchLab does not have.

Missing to represent Transformer:
- **Missing concept — fader as an independent event/rhythm timeline.** ScratchLab treats notation
  as one motion curve; it has no notion that the fader generates audible events on its own.
- **Missing concept — one-to-many motion→audio.** No support for multiple audible bursts inside a
  single stroke; ScratchLab's stroke is the atomic unit.
- **Missing lane — the crossfader timeline** (as a separate lane *or* as trace gating/colour).
- **Missing data — click events with explicit, high-resolution timing.** Without per-click
  timestamps there is nothing to draw the transform rhythm from.
- **Missing data — per-segment audibility** (which sub-parts of a stroke are open vs closed).
- **Missing visual element — trace gating / dim-vs-bright (or dash-vs-gap)** to show audible vs
  muted along a stroke; and a **click/onset marker** distinct from the reversal dot.

Practical consequence: even a "perfect" ScratchLab motion curve for a Transformer would look like a
plain triangle wave and convey **none** of the scratch's actual content. Representing Transformer is
not a tuning fix; it requires adding the fader timeline and click-timing data as first-class
citizens.

---

# Corrections to apply to Version 1

These are the only edits V1 needs (apply conceptually; do not rewrite V1):

1. **Re-rank the lanes as co-equal.** Replace V1's "motion lane (primary) + thin fader lane"
   framing with "two equal timelines." Keep both, drop the hierarchy.
2. **Add a third sanctioned fader representation: trace gating/colour** (bright = open, dim/gap =
   closed) alongside V1's separate-lane and shaded-band forms. Note it is preferred when fader work
   is dense (Transformer, fast Chirp).
3. **Generalise V1 rule 8** from "audio = motion AND fader-open" (stroke-level) to **sub-stroke
   level**: audibility is evaluated continuously, so one stroke may contain many audible bursts.
4. **Add explicit click-timing as required input** (V1 Part 3 listed crossfader state and click
   events; elevate click *timing precision/independence* to a hard requirement, since it is the
   Transformer's musical content).
5. **Add the Transformer signature to the acceptance checklist (V1 §7.5):** *slow continuous
   platter motion (often a triangle wave) chopped by a rapid fader tap-train into many audible
   bursts; rendered as a dashed/gated motion line or a dim/bright-segmented curve; click rhythm is
   the dominant readable feature.*
6. **Soften V1 rule 8's "always drawn solid":** muted motion may be rendered **dim** or as a
   **gap**; the trace's brightness/continuity itself carries audibility.

---

## Appendix — Transformer evidence index
- Slow triangle motion drawn as **dashed ramps** (one motion → many bursts); fader hand on mixer:
  `transformer notation.mp4 @0:12`.
- Dense rapid bright-cyan/green bursts with gaps (fader tap-train at speed): `… @0:55`.
- Big-screen continuous curve, **brightness/colour-gated** (cyan/green = open, dim = closed), green
  at burst onsets; single long strokes carrying multiple bright/dim segments: `… @1:15`.
- Reference renderer identity: window title "Scratch Visualizer - by SXRATCH".
- Burst-gap counts (fader gating, confounded by commentary): Chirp ~30 / Transformer ~14 / Baby ~7
  per 10 s.

## Open questions / flagged uncertainties
- **Green vs cyan semantics:** read as click-onset (green) vs sustained-open (cyan). An alternative
  reading is green = fader-open and cyan = a different state; resolving this would need clean
  frame-stepping against the isolated audio. The *structural* conclusion (fader gates the trace into
  bursts) holds under either reading.
- **Muted-motion visibility differs by render mode** (dim in big-screen, gap in windowed). Both are
  the same underlying "audibility = trace styling" principle; the spec should permit either.
- Whether the windowed dark-mode app also carries a separate bottom fader lane (as the red light-mode
  app does) was not confirmed for Transformer; the gating/colour encoding was the visible one.
