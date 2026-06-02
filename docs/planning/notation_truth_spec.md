# ScratchLab Notation Truth — Specification Derived From The Training Videos

**Status:** Research + specification only. No code, no implementation, no architecture, no tests.
**Authority:** The supplied notation videos are ground truth. Where they contradict ScratchLab's
current renderer, the videos win.

## 0. Source material and what it actually is

Seven primary videos were analysed frame-by-frame (1108×720, 30 fps, stereo audio):

| Scratch | File | Sample | Notation colour |
|---|---|---|---|
| Baby | `Baby scratch FRESH notation.mp4` (1:22) | spoken **"fresh"** | blue (diagram), cyan (live screen) |
| Tear | `tear notation.mp4` (3:08) | **"ahhh"** | red |
| Chirp | `chirps notation.mp4` (2:41) | **"ahhh"** | red |
| Boomerang | `boomerang notation.mp4` (2:14) | **"ahhh"** | red |
| Crescent Flare (+ reverse) | `cresant flare normal and reverse notation.mp4` (2:00) | **"ahhh"** | red |
| Aquaman | `aquaman notation.mp4` (1:34) | **"ahhh"** | red |

**Critical finding about the source itself:** the notation in these videos is produced by a real
application — the window title reads **"Scratch Visualizer - by SXRATCH"** in all five "ahhh"
videos. The Baby video additionally shows static teaching diagrams from the SXRATCH website
(the "sxRATCH / Expression Evolved" logo is visible). So the videos are not a hand-drawn
convention we must reverse-engineer loosely — they are **a working reference renderer**, and our
job is to read its rules exactly.

Two ScratchLab clips were used only for the Part 4 audit: `macNotation.mp4`, `sl practice
view.mp4` (older straight-segment notation) and `sl notation review 3.mp4` (newer smooth-curve
notation).

### The single most important structural discovery

The reference renderer draws **two stacked, time-aligned lanes**:

1. **Motion lane (large, top):** a continuous trace of **record/platter position over time**.
   Horizontal = time, vertical = position in the groove (≡ position in the sample).
2. **Crossfader lane (thin, bottom):** a **binary square wave** of fader state (open vs closed)
   over the same time axis.

Evidence: `chirps notation.mp4 @0:11` and `boomerang notation.mp4 @1:45` show the bottom lane as
an unmistakable square wave whose pulses line up in time with the motion-lane events. The Baby
teaching diagram expresses the same second dimension differently (see §1.1), but it is the same
information: *motion* plus *audibility*.

Everything else in this document follows from those two lanes plus one more primitive: a **dot
marker at every reversal point** (where platter direction flips).

---

# Part 1 — Per-scratch analysis

A note on axes that applies to every scratch:

- **Vertical position = displacement of the record from a reference point**, which is identical to
  **position within the sample** (the groove and the platter are rigidly coupled 1:1). Rising
  trace = moving forward through the sample; falling trace = moving backward.
- **Slope = speed.** Steep = fast hand; shallow = slow hand. A vertical segment = an almost
  instantaneous move.
- **Height of a stroke (peak-to-trough) = how far you travelled = sample displacement.** This is
  *not* time and *not* velocity; it is distance.
- **A dot = a reversal** (velocity passes through zero, direction flips).
- **The crossfader lane / shaded band = audibility**, independent of motion. Motion is still drawn
  while the fader is closed; you simply do not hear it.

## 1.1 Baby Scratch ("fresh")

**Family:** foundation / no-fader.
**Purpose:** the root scratch — move the record forward and back with the fader open so every
motion is heard.
**Movement pattern:** continuous forward↔back oscillation, no fader.

### The teaching diagram (`Baby scratch FRESH notation.mp4 @0:08`)
- Title "baby scratch".
- **Left (vertical) axis is literally the word "fresh"** written bottom-to-top: bottom = "f",
  top = "h". The vertical axis *is* sample position, labelled with the sample.
- **Bottom (horizontal) axis is time**, annotated with what is *heard*:
  `f r r f f r r f f r r f f r e s h`.
- **The blue curve** is a smooth sine-like oscillation. Crucially, the early humps are **shallow —
  they only reach roughly mid-lane** (you push into "fr~e" and reverse). The **final stroke shoots
  to full height ("h")** — that is the one time the whole word "fresh" is played forward in a
  single move.

### The comparison diagram (`@0:25`, baby vs forward vs military)
- **Baby:** continuous wave, **no shaded regions** → fader stays open, both directions audible.
- **Forward:** an upstroke, then a **grey vertical band labelled "off"** (fader closed → the
  reverse is muted), then the downstroke inside that band. A separate clean tall diagonal labelled
  `f r e s h` = the full word played forward.
- This is the proof that the "second lane" in the teaching diagram is **fader state drawn as a
  shaded band over the motion**, exactly equivalent to the bottom square-wave lane in the live app.

### Live screen (`@0:50`, `@1:05`)
- At `0:50` the cyan live trace grows from a flat line into **increasingly tall sine peaks** —
  amplitude is not fixed; it tracks how far the DJ actually moves.
- At `1:05` the same screen shows steep sawtooth strokes with near-vertical drops when the
  performance shifts to forward-style cutting.

### Stroke-height relationship (Baby)
Height is controlled by **sample/platter displacement**, demonstrated directly: shallow humps for
partial pushes into "fre", a full-height stroke for the complete word "fresh"
(`@0:08`, `@0:25`). It is **not** elapsed time (that is the X axis), **not** velocity (that is
slope), and **not** "always 100%".

## 1.2 Tear ("ahhh")

**Family:** single-stroke articulation (fader open or lightly used).
**Purpose:** break one continuous stroke into two or more audible segments so a single push/pull
sounds like "rr-rr".
**Movement pattern:** a stroke that hesitates partway, then continues in the same direction.

### Notation (`tear notation.mp4 @0:53`, zoom confirmed)
- Motion lane: a series of **tall up/down zigzags**. The tall peaks and deep valleys are the
  **full reversals** (top of push, bottom of pull).
- **Dots sit at an intermediate height, not at the extreme peaks** — they mark the **tear break**:
  the momentary stall in the middle of a stroke where direction has *not* fully reversed but the
  motion pauses, producing the second articulation.
- Bottom fader lane: sparse, wide pulses (tear is primarily a hand technique; fader is optional).

### Audio relationship
You hear a continuous "ahhh" being chopped: one hand stroke yields two (or more) bursts because of
the mid-stroke stall. The notation shows one tall stroke carrying an interior dot rather than two
separate full strokes.

### Stroke-height relationship (Tear)
Full strokes are tall (large displacement across the playable portion of "ahhh"); the dot is a
mid-stroke marker, not a height. Height still = displacement.

## 1.3 Chirp ("ahhh")

**Family:** fader scratch (two-click, on forward and back).
**Purpose:** produce short "chirp" bursts by opening/closing the fader around a quick push-pull.
**Movement pattern:** rapid small forward↔back spikes, each gated by a fader click.

### Notation (`chirps notation.mp4 @0:11`, zoom confirmed)
- Motion lane: a flat low start, one sharp vertical forward spike, then a run of **tall narrow
  V-spikes**, each with a **dot at the apex** (reversal). The spikes **grow taller and closer
  together** as the chirps accelerate.
- Bottom fader lane: a **clean square wave** whose pulses **narrow and quicken in lock-step with
  the spikes** — one fader open/close per chirp.

### Audio relationship
This is the clearest demonstration of the two-lane model: the *sound* is the AND of motion and
fader. Each chirp = (a small motion spike) × (one fader pulse). The square wave is the chirp.

### Stroke-height relationship (Chirp)
Spike height = the small displacement of each quick push/pull; it grows because the player gives
each chirp slightly more travel as they speed up. Again: height = displacement, audibility = fader
lane.

## 1.4 Boomerang ("ahhh")

**Family:** asymmetric stroke (throw + controlled return).
**Purpose:** a fast "throw" one direction and a controlled return the other, repeated.
**Movement pattern:** asymmetric strokes — one side fast, one side slow — sometimes with brief
holds at the extremes.

### Notation
- Simple demo (`boomerang notation.mp4 @0:56`): low plateau → steep rise → **flat high plateau**
  → steep fall → rise. Plateaus = the record momentarily **held** at an extreme; steep transitions
  = the throw and the catch. Fader lane nearly empty (fader-open hand technique).
- Advanced demo (`@1:45`): dense **asymmetric strokes with a dot at every turnaround**, and now an
  **active fader square wave** — boomerang can be layered with fader cuts.

### Audio / height
Asymmetric slopes mean the two directions are heard at different speeds (a fast whip one way, a
slower drag the other). Height = displacement of each throw; plateaus = zero-velocity holds (flat,
because no displacement is accruing).

## 1.5 Crescent Flare ("ahhh") and Reverse

**Family:** flare (fader cut(s) inside a flowing stroke).
**Purpose:** a flare whose reversal is a smooth curved turn rather than a hard cusp — the curve is
the "crescent".
**Movement pattern:** steep stroke into a **rounded U-turn**, with one or more fader clicks.

### Notation (`cresant flare normal and reverse notation.mp4 @1:19`, zoom confirmed)
- Motion lane: short steep upstrokes ending in **dot cusps (sharp reversals)**, and a steep
  downstroke that resolves into a **smooth rounded U at the bottom** — the **crescent** (the video
  even circles this turn with a blue annotation to call it out).
- This establishes a real distinction the notation encodes:
  - **Sharp reversal = a dot / cusp** (abrupt direction flip).
  - **Crescent = a smooth curved reversal** (gradual flip; the hand eases through zero velocity).
- Bottom fader lane: a few **wide pulses** (the flare's click(s)), far sparser than chirp.
- **Reverse** (`@1:47`): the same grammar mirrored vertically — the lead motion goes down-first
  instead of up-first. The reverse is *not* a different notation system; it is the same shape with
  inverted leading direction.

### Audio / height
The flare's clicks mute selected portions; the crescent turn is audible as a smooth pitch
glide through the reversal rather than a hard stop. Height = displacement of the flare stroke.

## 1.6 Aquaman ("ahhh")

**Family:** advanced fader/tone-play scratch.
**Purpose:** a flowing scratch with tall expressive strokes and fader articulation.
**Movement pattern:** tall steep strokes with dotted reversals (`aquaman notation.mp4 @1:17`).

### Notation
- Motion lane: **tall steep strokes** (large displacement, fast hand) with **dots at reversals**;
  some strokes stand alone (isolated up-spikes) reflecting fader-gated single hits.
- Fader lane: present but intermittent — Aquaman gates specific strokes.

### Audio / height
Tall = large sample travel per stroke; the isolated tall spikes that appear without a matching
return stroke indicate the *return was muted by the fader* (motion still drawn, audibility off).

---

# Part 2 — Universal notation grammar

Derived rules that hold across **every** video:

1. **Two lanes, one shared time axis.**
   - Motion lane (position vs time) on top.
   - Crossfader lane (binary open/closed square wave) below, time-aligned.
   - Equivalent presentation: a shaded "off" band drawn over the motion (Baby teaching diagram)
     instead of a separate lane. Same meaning.

2. **Vertical = position in the sample (= platter displacement).** Up = forward through the
   sample, down = backward. The axis can be literally labelled with the sample word when the sample
   is short and phonetic (Baby: "fresh").

3. **Rising trace = forward motion; falling trace = reverse motion.** Direction is read from the
   sign of the slope, *not* from colour.

4. **Slope magnitude = hand speed.** Steep = fast, shallow = slow, vertical = a snap.

5. **Stroke height (peak↔trough) = displacement = how much sample you traversed.** Short move =
   short stroke; full move = full-height stroke. Height is independent of time and of speed.

6. **Reversal marker (dot) at every direction change** where the turn is abrupt (a cusp).

7. **Crescent (smooth rounded turn) = a gradual reversal.** Sharp turn → dot/cusp; eased turn →
   curve. The shape of the turn is meaningful.

8. **Audio heard = motion AND fader-open.** Motion is always drawn; the fader lane decides which
   parts are audible. A muted move is a drawn stroke with no sound (Aquaman isolated spikes; Baby
   forward-scratch "off" band; chirp gating).

9. **Hold = flat horizontal segment** (zero velocity, no displacement accruing) — Boomerang
   plateaus.

10. **Reverse variants mirror vertically.** A "reverse <scratch>" is the same grammar with the
    leading direction inverted, not a new vocabulary (Crescent Flare reverse).

11. **Curves, not straight lines.** The reference motion lane is a smooth continuous curve. Even
    fast strokes are rendered as curves with rounded extrema; only true snaps approach straight
    verticals. The smoothness encodes the continuous acceleration/deceleration of the hand.

12. **Amplitude is faithful, not normalised per-stroke.** Within one performance, strokes of
    different reach are drawn at different heights (Baby shallow humps vs full "fresh" stroke;
    chirp spikes growing). The lane is not auto-levelled stroke-by-stroke.

---

# Part 3 — Renderer specification (conceptual, not implementation)

## Input the renderer should consume
- **Platter position over time** (signed displacement from a reference, sampled densely enough to
  reconstruct a smooth curve). This is the spine of the motion lane.
- **Platter direction / velocity** (derivable from position; used to detect reversals and to set
  slope/curvature faithfully).
- **Sample position / displacement** — equal to platter position for normal playback; kept as a
  distinct concept so the vertical axis can be *labelled with the sample* (e.g. "fresh") and so
  "full sample" vs "partial sample" travel can be distinguished.
- **Crossfader state over time** as a binary open/closed signal (with its click/transition times).
- **Reversal events** (timestamp + position where velocity crosses zero) and whether each reversal
  is abrupt (cusp) or smooth (crescent).
- **Timing / transport** to lay everything on one shared horizontal axis.

## Internal model the renderer should compute
- A continuous **position(t)** curve for the motion lane (smoothed so motion reads as curves, with
  rounded extrema; near-vertical only when the move is genuinely near-instant).
- **Per-stroke displacement** = |position at reversal n − position at reversal n−1|, which sets the
  **height** of each stroke. Height must reflect partial vs full travel, never be clamped to 100%.
- **Slope(t)** from velocity, so fast/slow reads correctly.
- **Reversal classification:** abrupt → place a dot/cusp; smooth (low peak curvature / eased
  velocity through zero) → render a rounded crescent turn instead of a dot.
- **Audibility(t)** = motion present AND fader open; used only to style/annotate, never to suppress
  the motion curve itself.
- A **fader square wave** quantised to open/closed with transition times aligned to the motion
  lane.

## Output the renderer should draw
- **Motion lane:** one continuous curve.
  - **Stroke direction:** rising = forward, falling = reverse (read from slope; colour optional and
    must not be the *only* carrier of direction).
  - **Stroke height:** proportional to sample displacement of that stroke. Short reversals →
    shallow strokes; full-sample travel → full-height strokes.
  - **Reversal handling:** dot/cusp for abrupt turns; rounded crescent for eased turns.
  - **Short movements:** small-amplitude wiggles (do not inflate to full height).
  - **Long movements / full-sample travel:** full-height strokes reaching the top of the lane.
  - **Partial sample travel:** strokes that stop short of the top, at the height matching how far
    into the sample the motion went.
  - **Holds:** flat horizontal segments.
- **Crossfader lane (separate, time-aligned):** binary open/closed square wave; OR an equivalent
  shaded "off" band drawn over the muted portion of the motion curve. Fader clicks appear as the
  square-wave edges.
- **Sample labelling (optional, strongest for short phonetic samples):** the vertical axis may be
  annotated with the sample so height is legible as "how much of the word played".

---

# Part 4 — ScratchLab audit

Compared against ScratchLab's notation as seen in `macNotation.mp4 @0:12`, `sl practice view.mp4
@0:15` (straight-segment style) and `sl notation review 3.mp4 @0:15` (smooth-shallow-green style).

| # | Issue | Why it is wrong (vs videos) | Severity |
|---|---|---|---|
| 1 | **No crossfader lane.** ScratchLab's guide shows only a motion trace; there is no fader square-wave / "off" lane. | The reference makes the fader a co-equal lane (chirp/flare/military are *defined* by fader pattern). Without it, fader-based scratches cannot be notated at all, and "audio heard vs motion" is unrecoverable. | **Critical** |
| 2 | **Uniform stroke height.** The straight-segment guide (`macNotation`, `sl practice view`) draws every stroke at essentially the same slope/height; the newer green wave (`sl notation review 3`) is a uniformly shallow sine. | The reference proves height = sample displacement: Baby shows shallow partial humps *and* a full-height "fresh" stroke in the same routine. Uniform height erases the core information. | **Critical** |
| 3 | **No full-sample stroke for the complete "fresh".** Neither ScratchLab style renders the tall full-word stroke. | The Baby diagram's defining feature is the single full-height stroke for the whole word; its absence means ScratchLab cannot distinguish a full play from a partial scratch. | **Major** |
| 4 | **Straight line segments instead of curves** (`macNotation`, `sl practice view`). | The reference motion lane is a smooth continuous curve; the curvature carries acceleration and distinguishes a smooth crescent reversal from an abrupt cusp. Straight segments cannot express the crescent at all. | **Major** |
| 5 | **No reversal markers.** ScratchLab draws no dots/cusps at turnarounds. | Every reference scratch marks reversals with dots; tear/flare meaning depends on cusp-vs-smooth turns. | **Major** |
| 6 | **Direction encoded only by colour** (green up / magenta down in the straight-segment style). | The reference reads direction from slope sign and uses a single trace colour; colour-only direction is redundant at best and, in the monochrome green-wave style, lost entirely. | **Minor** |
| 7 | **Notation appears Baby-only / generic, with no scratch-specific vocabulary.** | The reference has distinct, recognisable signatures per scratch (chirp square wave, flare crescent, boomerang asymmetry, tear interior dot). ScratchLab's single shallow wave cannot represent any of them. | **Major** |
| 8 | **Possible per-stroke amplitude normalisation** (the shallow uniform green wave suggests the trace is levelled). | The reference keeps amplitude faithful within a take. Normalising destroys the partial-vs-full distinction. | **Major** (confirm against the live renderer behaviour) |

Note: ScratchLab's coaching *text* is actually correct and matches the videos — "one clean push
forward, one clean pull back, fader open" (`sl notation review 2/3`) is exactly the Baby
definition. The gap is entirely in the **drawn notation**, not the description.

---

# Part 5 — Baby Scratch deep dive

Direct answers, each backed by the Baby video.

1. **Should every Baby stroke reach 100% height?**
   **No.** `Baby scratch FRESH notation.mp4 @0:08` shows the early baby humps reaching only ~mid-
   lane (partial pushes into "fre"), with only the final full-word stroke reaching the top ("h").

2. **Should notation height vary with sample displacement?**
   **Yes.** Same evidence: shallow humps = small displacement, full stroke = full displacement.
   The vertical axis is literally the word, so height = amount of sample traversed.

3. **Should short reversals produce shallow notation?**
   **Yes.** A reversal that occurs after travelling only partway up the word turns around at mid-
   lane, producing a shallow hump (`@0:08`, `@0:25`).

4. **If the user scratches only part of "fresh", should notation show a shorter stroke?**
   **Yes.** That is exactly what the partial humps depict; they stop at the sample position reached
   (e.g. "fre") and never touch "h".

5. **If the user reverses halfway through "fresh", should notation reverse halfway up the lane?**
   **Yes.** The reversal point on the curve sits at the sample position where the hand turned
   around — halfway up if the turn happened mid-word. The dot/turn height *is* the reversal
   position.

6. **Should notation represent audio position?**
   **Yes — the vertical axis is sample/audio position** (labelled "fresh"). This is the primary
   meaning of height.

7. **Should notation represent platter position?**
   **Yes — and it is the same thing.** Platter displacement and sample position are rigidly 1:1, so
   the single vertical axis simultaneously represents both. The fader lane (separate) is what
   carries the *audibility* that platter position alone does not.

8. **Should notation represent both?**
   **Yes, but recognise they are one axis.** Platter position and sample position coincide on the
   vertical axis; "both" does not mean two stacked motion graphs. The genuine *second* dimension is
   the **crossfader lane**, which Baby happens to leave fully open (so for pure Baby the fader lane
   is flat/open — but it must still exist, because the very next teaching step, the Forward scratch
   at `@0:25`, turns it on).

**Conceptual verdict on ScratchLab's current Baby approach:** the *shape philosophy* of the newer
smooth-green wave is on the right track (smooth curve, forward↔back oscillation, fader open). But
it is **conceptually incomplete**: it uses uniform shallow amplitude, so it fails answers 1–5
(height must vary with displacement and the full-"fresh" stroke must appear), and it omits the
crossfader lane that the teaching sequence immediately needs.

---

# Part 6 — Cross-scratch consistency

**Universal (share this logic across all scratches):**
- Two-lane model (motion + fader on one time axis).
- Vertical = position/displacement; rising = forward, falling = reverse.
- Slope = speed; height = displacement; flat = hold.
- Dots at abrupt reversals; smooth curve = gradual reversal.
- Audio = motion AND fader-open; muted motion is still drawn.
- Faithful amplitude (no per-stroke normalisation); reverse variants mirror vertically.

**Baby-specific (the "fresh" short-sample case):**
- Vertical axis can be labelled with the literal sample word.
- The pedagogically important "full-sample" stroke (the whole word forward) is a first-class event.
- Fader lane is present but typically **all-open** — so Baby looks fader-less, but the lane is not
  absent, just flat.

**Long-sample ("ahhh") specific:**
- No phonetic axis labels (the sample is continuous), so height reads as generic displacement, not
  letters.
- Greater reliance on the **fader lane** to define identity (chirp, flare, military, parts of
  aquaman/boomerang).

**Crossfader-specific:**
- Chirp: regular fast square wave (one click per chirp).
- Crescent Flare: few wide pulses, paired with the crescent turn.
- Military / Forward: alternating open/closed gating the reverse stroke.
- Boomerang/Baby/Tear: fader often open (lane flat) — fader is optional, motion carries the
  identity.

**Where ScratchLab should share vs not:**
- **Share:** the entire motion-lane engine (position→curve, displacement→height, slope→speed,
  reversal→dot/crescent) is identical for all scratches including Baby. There is no reason for Baby
  to have a separate notation model.
- **Do not hard-code Baby assumptions** (e.g. "always full height", "no fader") into the shared
  engine — those are *performance facts about one routine*, not notation rules. The shared engine
  must support shallow partial strokes and a present-but-open fader lane.

---

# Part 7 — Final authoritative ScratchLab Notation Specification

An engineer could build the renderer from this section alone.

## 7.1 Canvas
Two horizontally-aligned lanes sharing one left-to-right time axis:
- **Motion lane** (tall): vertical axis = signed position in the sample / platter displacement.
  Top of lane = furthest-forward sample position represented; bottom = furthest-back. For short
  phonetic samples the axis may be annotated with the sample (e.g. bottom "f" … top "h").
- **Crossfader lane** (short, directly below): vertical is binary — open (audible) vs closed
  (muted).

## 7.2 Motion lane drawing rules
1. Plot a **continuous smooth curve** of position over time. Curvature reflects hand
   acceleration; extrema are rounded except where the move is a genuine snap (then near-vertical).
2. **Direction:** rising = forward through the sample; falling = backward. Direction is legible
   from slope alone. Colour, if used, is secondary and must never be the sole direction cue.
3. **Speed:** slope magnitude. Steeper = faster.
4. **Height of each stroke** (distance between consecutive reversals) is **proportional to the
   sample displacement of that stroke**, on a fixed scale for the whole take:
   - A short push that reverses early → a **shallow** stroke that stops at the reached position.
   - A move through the **entire** sample → a **full-height** stroke reaching the top.
   - Never clamp every stroke to full height; never auto-level per stroke.
5. **Reversals:**
   - Abrupt turn → mark with a **dot** at the turn position (a cusp).
   - Eased turn → render a **smooth rounded curve** (crescent); no dot.
   - The vertical position of the turn = the sample position where the hand reversed (reverse
     halfway through the sample ⇒ turn drawn halfway up the lane).
6. **Holds:** zero-velocity periods are **flat horizontal** segments.
7. **Interior articulations (tear):** a stall mid-stroke that does not fully reverse is marked with
   a dot at its position, without splitting the stroke into two full strokes.
8. **Reverse variants:** mirror the leading direction vertically; reuse all other rules unchanged.

## 7.3 Crossfader lane drawing rules
1. Draw a **binary square wave**: open vs closed, edges at the exact click times, aligned to the
   motion lane.
2. Equivalent acceptable presentation: shade the motion curve (an "off" band) over closed-fader
   spans instead of a separate lane — but the *information* (when audio is on/off) is mandatory.
3. The fader lane is **always present**, even when a scratch leaves it fully open (then it is a
   flat "open" line). Absence of fader work is *open*, not *missing*.

## 7.4 Audibility rule
**What is heard = motion present AND fader open.** The renderer must **draw motion regardless of
fader state**; audibility only changes styling/annotation (and is read off the fader lane). Muted
moves (e.g. an isolated forward spike whose return is cut) remain fully drawn in the motion lane.

## 7.5 Per-scratch signatures (acceptance checklist)
A correct renderer reproduces these recognisable shapes:
- **Baby:** smooth forward↔back wave, **variable** hump heights, fader lane flat-open, with a
  full-height stroke when the whole sample is played.
- **Tear:** tall strokes carrying an **interior dot** (the break), fader mostly open.
- **Chirp:** small accelerating motion spikes with apex dots, paired with a **regular fast fader
  square wave** (one pulse per chirp).
- **Boomerang:** **asymmetric** strokes (fast/slow sides), optional plateaus (holds), dots at
  turns, fader optional.
- **Crescent Flare:** steep stroke into a **smooth crescent U-turn**, a few **wide** fader pulses;
  **reverse** = the same shape mirrored.
- **Aquaman:** tall steep strokes with dotted reversals; some strokes audible only one way because
  the fader cut the return.

## 7.6 Hard "do nots" (each is a confirmed reference contradiction)
- Do **not** force every stroke to full height.
- Do **not** omit the crossfader lane.
- Do **not** draw straight segments where the reference draws curves.
- Do **not** encode direction by colour only.
- Do **not** suppress motion when the fader is closed.
- Do **not** give Baby a separate notation model — it is the shared engine with the fader open.

---

## Appendix — Evidence index (file @ timestamp)

- Baby teaching diagram, "fresh" vertical axis, shallow humps + full stroke: `Baby scratch FRESH notation.mp4 @0:08`.
- Baby vs Forward vs Military, "off" shaded band = fader closed: `… @0:25`.
- Baby live trace growing in amplitude: `… @0:50`; forward-cut sawtooths: `… @1:05`.
- Two-lane structure + square-wave fader, clearest: `chirps notation.mp4 @0:11`.
- Tear zigzags with interior break dots: `tear notation.mp4 @0:53`.
- Boomerang plateaus (simple): `boomerang notation.mp4 @0:56`; asymmetric + active fader (advanced): `… @1:45`.
- Crescent Flare crescent U-turn (annotated) + cusp dots + wide fader pulses: `cresant flare normal and reverse notation.mp4 @1:19`; reverse mirrored: `… @1:47`.
- Aquaman tall dotted strokes: `aquaman notation.mp4 @1:17`.
- Reference app identity: window title "Scratch Visualizer - by SXRATCH" (all five "ahhh" videos); sxRATCH website diagrams (Baby video).
- ScratchLab straight-segment notation: `macNotation.mp4 @0:12`, `sl practice view.mp4 @0:15`.
- ScratchLab smooth-shallow-green notation: `sl notation review 3.mp4 @0:15`.

## Open questions / contradictions flagged
- **Amplitude scaling of the live app:** chirp spikes grow over time. This is consistent with
  faithful (absolute) amplitude where the player adds travel, but a per-window auto-scale cannot be
  fully ruled out from stills. The Baby *teaching diagram* is unambiguously faithful (fixed word
  axis), so the spec mandates faithful amplitude; confirm the live app does not auto-level.
- **Tear interior dot vs full reversal:** read as a mid-stroke break (not a full reversal) from
  `tear @0:53`. If frame-stepping the live audio shows the dot coincides with silence rather than a
  stall, it would instead mark a fader/again-catch point — the teaching intent (one stroke heard as
  two) holds either way.
- **Dot semantics unified:** dots appear at chirp apexes, flare cusps, boomerang turns, and tear
  breaks. Treated uniformly as "articulation/reversal markers". If the source distinguishes a
  reversal dot from a break dot by style, that nuance was not resolvable at this resolution.
