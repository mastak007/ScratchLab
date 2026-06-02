# ScratchLab Notation Truth — System / Data-Model Addendum (Version 1.2)

**Companion to:** `notation_truth_spec.md` (V1) and `notation_truth_spec_transformer_addendum.md`
(V1.1). This addendum does **not** rewrite either. It establishes the **underlying data model**
implied by the notation system.

**New source:** `demo hoe notation app works with replay.mp4` (2:14, 1108×720, 30 fps). This is not
a scratch tutorial — it is a demonstration of the **notation application itself** (the "Scratch
Visualizer / SXRATCH Sound Collective" app). Structure: ~0:00–0:47 a DJ performs a freestyle
routine while the system records; ~0:47+ the app replays the recording and shows what can be
changed without changing the notation. Same authority as the other videos.

---

## The decisive observation

During replay, the demonstrator changes the **scratch sample, the beat, the pitch, the volumes,
and the crossfader rendering** — and the **notation curve never changes**. The recorded white
motion trace at `@0:30`, `@1:50` (sample 2) and `@2:00` (sample 1) is **byte-for-byte the same
shape** while the sample waveform panel on the right swaps between completely different audio.

That single fact determines the data model: **the notation is a recording of performance
gestures, not of audio.** Everything below follows from it.

---

# 1. What information is actually stored by the notation system

Stored (intrinsic to the notation; survives every replay change):
- **Platter motion over time** — position/velocity of the record vs time (the motion lane / white
  trace). Defines direction, speed, reach, reversals, timing of the hand.
- **Crossfader actions over time** — the cut/open-close events. These must be *stored as data*,
  because the app can **toggle "XF Cuts" on/off and "XF Invert"** at replay (`@1:25`). You cannot
  enable/disable cuts that were never recorded.
- **Timing** — the shared time base binding motion and fader together. The rhythm of the
  performance is preserved across all replays.

In one phrase: **the notation stores the two gesture streams (hand-on-platter and hand-on-fader)
on a common timeline.** It is a *performance/control recording*, akin to MIDI or an automation
track — not an audio file.

# 2. What information is NOT stored

Not stored (freely changed at replay without touching the notation):
- **Audio waveform content** — proven by **Scratch Sample Hot Swap 1–7** (`@1:35`, status "Sample
  'Freshhh' selected"): the same notation drives entirely different audio. The sound is not in the
  notation.
- **Sample identity** — the chosen sample ("This beat is fresh" / "Freshhh" / slots 1–7) is a
  replay parameter, not part of the notation.
- **The beat / backing track** — a separate selectable layer ("Beat (BPM) – powered by TableBeats:
  Worms (90)", its own volume and BPM, `@0:05`). Removing/reducing the beat does not alter notation.
- **Pitch** — "Scratch Pitch 100%" (`@1:35`) is a playback control.
- **Audio mix / levels** — independent volume sliders for sample (65%) and beat (100%) (`@0:05`).
- **Crossfader *rendering*** — whether cuts are applied (XF Cuts) or inverted (XF Invert) is a
  replay choice, distinct from the stored cut events.

# 3. What aspects of playback are DERIVED from notation
- **Sample position / playhead** — the motion drives a playhead *through* whatever sample is
  loaded. The vertical sample-waveform panel shows a **red playhead marker** that moves under the
  stored motion (`@0:30`, `@1:35`). Sample position is computed from motion, not stored as audio.
- **Pitch/direction of the heard tone** — derived from motion velocity/sign at each instant.
- **Audibility / burst rhythm** — derived from the stored crossfader events (when XF Cuts is on).
- **The rendered motion trace and its dashing/gating** — drawn from stored motion + fader.

# 4. What aspects of playback are INDEPENDENT of notation
- Sample choice, beat choice, BPM, pitch, all volumes, XF Cuts on/off, XF Invert. All of these can
  change while the notation stays identical.

## Does notation represent…?
| Candidate | Stored? | Evidence |
|---|---|---|
| Audio waveform content | **No** | Sample hot-swap 1–7 keeps notation, changes audio (`@1:35`). |
| Sample identity | **No** | Sample selector is a replay parameter (`@0:05`, `@1:50`). |
| Platter movement | **Yes** | The motion lane / white trace is the spine of the recording. |
| Sample position | **Derived, not stored** | Playhead moves under motion; depends on loaded sample (`@1:35`). |
| Crossfader actions | **Yes (as events)** | XF Cuts/Invert toggles require stored cut events (`@1:25`). |
| Timing | **Yes** | Rhythm preserved across all replays. |
| Performance gestures | **Yes — this is the essence** | Notation = what the hands did (motion + fader) over time. |
| Combination | **Yes** | Specifically: motion-gesture + fader-gesture + timing. |

---

# Replay analysis

**Unchanged when replaying (intrinsic to the recording):**
- **Notation** — the motion trace shape is constant across all replays.
- **Movement** — platter motion is fixed (it is the recording).
- **Timing** — the temporal structure / rhythm is fixed.
- **Fader activity** — the *cut events* are fixed (only whether they are *applied* changes).

**Changeable without altering notation:**
- **Sample choice** — hot-swap 1–7.
- **Beat** — selectable track, BPM, can be reduced/removed.
- **Audio mix** — independent sample/beat volumes.
- **Fader rendering** — XF Cuts on/off, XF Invert (the events stay; their application toggles).
- **Pitch.**

**Implication for the underlying model:**
The notation is a **gesture/control recording decoupled from audio material and from rendering
options.** It behaves like a *score* or *MIDI/automation track*: the score (motion + fader + time)
is fixed; the *instrument* (sample), the *accompaniment* (beat), the *tuning* (pitch), the *mix*,
and the *interpretation of the fader* (cuts on/off/invert) are all swappable at play time. Audio is
**re-synthesised on demand** by driving the chosen sample with the stored gestures.

---

# Architecture implications

## "What is the smallest set of information required to reproduce a scratch performance from notation?"

**Mandatory (without any one of these the performance gesture cannot be reproduced):**
1. **Platter motion vs time** — position (or velocity) on a continuous time axis. Carries
   direction, speed, reach, reversals, and the tone's pitch/rhythm.
2. **Crossfader events vs time** — the open/close (cut) timeline. Carries audibility and, for
   fader-driven scratches (Chirp, Transformer), the entire burst rhythm. (For fader-open scratches
   — Baby, Tear, Boomerang — this stream is simply "open throughout", but it must still exist.)
3. **A shared timing reference** — the common clock that binds streams 1 and 2.

That is the whole minimum: **motion(t) + crossfader(t) + time.** Everything across all eight videos
(Baby, Tear, Chirp, Boomerang, Crescent Flare, Aquaman, Transformer, and this demo) is reproducible
from those three.

**Optional (needed to reproduce a *specific rendition*, not the gesture itself):**
- Sample identity / scratch sample.
- Beat selection + BPM.
- Pitch.
- Sample and beat volumes / mix.
- Crossfader render options (XF Cuts on/off, XF Invert).

**Display-only (affect appearance, never the performance):**
- Trace colour/brightness, dashing/gating style, gridlines.
- The vertical sample-waveform panel and its playhead marker.
- Beat/backing visualisation, theme, branding.

This cleanly resolves V1.1's "two equal timelines" into a concrete data model:
**a notation file = { motion samples over time, crossfader events over time, a clock }**, plus a
detachable **render/voicing config = { sample, beat, BPM, pitch, volumes, XF options }**.

---

# Notation truth review — A / B / C / D

> A. Audio &nbsp;|&nbsp; B. Motion &nbsp;|&nbsp; C. Performance events &nbsp;|&nbsp; D. Hybrid

**Answer: C — performance events — realised as D, a hybrid of two gesture streams (motion + fader)
on a shared clock. It is definitively NOT A (audio), and NOT B (motion alone).**

Evidence from the demonstration:
- **Not A (audio):** hot-swapping samples 1–7 changes the sound entirely while the notation is
  unchanged (`@1:35`, `@1:50`, `@2:00`). If audio were stored, it could not be swapped freely.
- **Not B (motion alone):** the crossfader is independently stored and independently toggleable
  (XF Cuts / XF Invert, `@1:25`); the Transformer (V1.1) proved the fader carries content the
  motion does not. Motion alone is insufficient.
- **C, expressed as D:** what *is* fixed across every replay is *what the performer did* — the
  platter gesture and the fader gesture in time. That is a **performance-event recording**, and it
  is intrinsically **hybrid** (two distinct gesture streams). The system then **re-synthesises
  audio** from those events against a chosen sample/beat.

So the precise statement: **the notation encodes performance events — a hybrid motion-gesture +
crossfader-gesture timeline — from which audio is generated at replay; it stores neither the audio
nor the sample.**

---

# ScratchLab impact

**Concepts ScratchLab already captures:**
- A **motion lane** (a position-over-time trace exists in ScratchLab's guide).
- Some notion of **timing / a playhead cursor** (the vertical cursor in the guide).
- Correct coaching *language* about the gesture (push/pull/fader-open).

**Concepts ScratchLab is missing:**
- **Crossfader as stored, toggleable event data** — no fader timeline, so no XF-cuts concept at all.
- **Decoupling of gesture from audio** — no sample hot-swap; notation appears bound to one bundled
  demo rather than being sample-agnostic.
- **Re-synthesis model** — no concept of "drive any sample with the stored gestures."
- **Detachable voicing layer** — no separable sample / beat / pitch / mix / XF-render config.
- **Sample-position playhead derived from motion** (driving a playhead through an arbitrary sample).
- **A persisted performance recording** that can be replayed and re-voiced (vs a pre-baked visual).

**Assumptions ScratchLab currently makes that appear incorrect:**
1. **That notation is a fixed visual tied to a specific audio/sample** ("the Baby Scratch demo").
   The reference system proves notation must be **sample-independent gesture data**; the audio is
   chosen at replay, not embedded.
2. **That motion is the whole story** (motion-only single curve). The demo confirms the fader is a
   co-equal, separately-stored stream — without it ScratchLab cannot even *represent*, let alone
   reproduce, Chirp/Transformer/flare-family scratches.
3. **That the notation is a display artifact rather than a recording.** The reference treats
   notation as a replayable performance record (a score), not a drawing. ScratchLab's guide is
   currently the latter.
4. **That sample, beat, and mix are part of "the notation."** They are not — they are independent
   playback parameters; baking them in is the wrong model.

Bottom line: representing this system in ScratchLab is not a rendering tweak. It requires adopting
the **gesture-recording data model** — store `motion(t)` + `crossfader-events(t)` + `clock`, keep
sample/beat/pitch/mix/XF-render as a separate detachable config, and synthesise audio at replay.

---

# Why the reference notation app can separate beat, sample, fader cuts, and notation

**System context (provided, treated as authoritative):** the reference notation app is a
**standalone macOS app** — *not* Serato, and no Serato instance is running during the demo. The
"ahh" sample and the beats are **preloaded inside the notation app**. The DJ hardware is plugged
**directly into the Mac**, and the app receives **MIDI/control input from the hardware**.

That context explains the entire V1.2 data model. The app can cleanly separate beat, sample,
fader cuts, and notation for one reason:

> **It owns every layer, and it captures the performance as control/gesture data *upstream* of
> audio — before motion and fader ever become sound.**

Concretely, the reference app owns, as separate layers:
- the **beat** (preloaded, selectable, with its own BPM and volume),
- the **scratch sample** (preloaded, hot-swappable 1–7),
- the **playback / synthesis engine** (it generates the audio itself),
- the **MIDI/control input** (it reads the hands' gestures directly from the hardware),
- the **replay system**, and
- the **notation renderer**.

Because the platter motion and crossfader actions arrive as **discrete control data** (not as a
finished audio mix), the app records the *causes* of the sound, then **re-synthesises the sound on
demand** by driving a chosen sample with those causes. Nothing is "baked in":
- **Swap sample** → feed the same motion to a different preloaded buffer.
- **Mute / change beat** → it is an independent track the app mixes in, so it can drop it.
- **Disable crossfader cuts (XF Cuts / Invert)** → the cut events are stored separately and only
  *applied* at synthesis time, so application is optional.
- **Preserve notation** → notation is the stored gesture record, untouched by any of the above.

**Why a Serato-based ScratchLab workflow cannot do this cleanly.** If Serato owns the sample, the
beat, the engine, and the fader, then Serato produces a **mixed audio output**. An external
ScratchLab observing that output receives sound in which scratch, beat, and fader cuts are already
combined. You **cannot un-mix** a finished signal back into independent layers:
- The beat is already summed with the scratch → muting it after the fact is not reliably possible.
- The fader cuts are already applied (silences are already in the audio) → you cannot "turn cuts
  off" to hear the underlying continuous motion.
- The sample is already the audio you heard → there is no separate buffer to swap.
- Motion and fader can only be **inferred** from the mixed audio (lossy, ambiguous), not read as
  exact control data — so timing/notation become estimates, not ground truth.

In short: **the reference app's powers come from owning the input layer and synthesising audio;
an analyzer of someone else's mixed output is fundamentally downstream and lossy.** This is not a
feature gap ScratchLab can close with better analysis — it is a consequence of *where in the
signal chain* the data is captured.

# Recommended ScratchLab product architecture

**Recommendation: Option C — standalone-first, Serato as later import/analyze compatibility.**
This matches the preferred direction and is the only option that makes the V1.2 capabilities real.

Evaluation against each ScratchLab goal:

| Goal | Standalone (owns layers) | Serato analyzer (mixed output) |
|---|---|---|
| Learn scratching | App owns sample+beat+coaching → guided, repeatable | Possible, but depends on the user's separate Serato setup |
| Visualize notation | Reads exact gesture data → faithful trace | Must infer motion/fader from audio → approximate |
| Analyze timing | Exact event timestamps from MIDI/control | Onset-detected from audio → lossy, ambiguous |
| Replay a scratch | Trivial — re-synthesise from stored gestures | Can only replay captured audio; no re-voicing |
| Swap sample, keep notation | Native (own sample buffers) | **Impossible** from mixed audio |
| Mute beat | Native (separate track) | **Not reliable** (can't un-mix) |
| Mute crossfader cuts | Native (cuts applied at synthesis) | **Impossible** (silences already in audio) |
| App Store-safe scope | Clean: bundled content + MIDI input | Riskier: capturing/parsing another app's output |
| Avoid Serato-replacement creep | A focused *training/notation* tool ≠ a DJ suite | Tends to drift toward "do what Serato does" |

**Why standalone-first, in product terms:**
- Every differentiated ScratchLab capability (replay, sample-swap, beat-mute, cut-mute, faithful
  notation, exact timing) **requires owning the layers**. They are not achievable as an
  after-the-fact analysis of Serato. So the core engine must be standalone.
- It keeps ScratchLab's scope **honest and small**: a *training and notation* app that owns a
  curated library of samples/beats and reads gestures from hardware the user already has. That is a
  clearly bounded product, not a Serato competitor — it does performance *capture, coaching, and
  replay*, not library management, cueing, effects, or live mixing.
- It is **App-Store-friendly**: bundled audio content plus standard MIDI/control input is
  well-trodden ground. It avoids the fragile/grey-area paths of hooking into or capturing a
  third-party DJ app's output.
- The user keeps their existing setup: the same turntables/mixer plugged into the Mac feed
  ScratchLab instead of Serato. ScratchLab competes for the *input*, not for the hardware, and the
  user can switch apps without changing gear.

**Where Serato belongs (secondary, and honestly scoped):**
- Position Serato support as **later "import / analyze" compatibility**, explicitly best-effort and
  acknowledged-lossy: it can *visualize and time-analyze* a Serato performance, but it **cannot**
  offer replay-with-re-voicing, sample-swap, beat-mute, or cut-mute on that material, because those
  require owning the layers Serato already mixed.
- If a higher-fidelity Serato path is ever wanted, it would have to come from **control-level data**
  (a recorded control/automation stream), not from analyzing mixed audio — and even then it is a
  compatibility convenience, never the core engine.
- Treating Serato as the engine would invert the dependency, cap ScratchLab's feature ceiling at
  "what you can recover from a mix", and invite scope creep toward becoming a Serato replacement.

**Why not A (pure standalone) or B (pure Serato companion):**
- **Not B:** a pure Serato companion can never deliver the replay/sample-swap/mute capabilities that
  define the reference experience; it is structurally downstream and lossy.
- **Not strictly A:** pure standalone is technically sufficient, but explicitly *excluding* any
  Serato interoperability needlessly rejects users who already perform in Serato and just want to
  visualize/analyze. C keeps the clean standalone core *and* offers a modest, clearly-limited bridge
  — without letting that bridge dictate the architecture.

**One-line architecture statement:** *ScratchLab should own the sample, beat, synthesis engine,
MIDI/control input, replay, and notation as a standalone training app (so notation is captured as
gestures and audio is re-synthesised), and offer Serato only as a later, best-effort
import/analyze layer that visualizes and times performances without claiming to re-voice them.*

## Appendix — Demo evidence index
- Control panel: Scratch Sample "This beat is fresh", Beat "Worms (90)" + BPM + separate volumes,
  XF Reverse toggle: `@0:05`.
- Recording phase, split-screen: notation (motion trace + dashed fader gating + vertical sample
  waveform with red playhead) beside the live DJ: `@0:30`.
- X-fader Modifiers popup — **XF Cuts** + **XF Invert** toggles (fader rendering is a replay
  option): `@1:25`.
- **Scratch Sample Hot Swap 1–7** + **Scratch Pitch 100%**, status "Sample 'Freshhh' selected",
  sample waveform panel + playhead on the right: `@1:35`.
- Sample switched to **2** — notation unchanged, sample waveform changes: `@1:50`.
- Sample switched back to **1** — notation unchanged, waveform reverts: `@2:00`.
- App chrome: menus File / View / Playback / Tools / Help; left rail live-input / play / settings;
  title "Scratch Visualizer - by SXRATCH" / "Sound Collective".

## Open questions / flagged uncertainties
- **Crossfader storage granularity:** that cut events are stored is certain (they can be toggled);
  whether they are stored as discrete click timestamps or as a continuous fader-position curve was
  not directly shown. The Transformer (V1.1) argues for high-resolution discrete click timing.
- **Whether motion is stored as absolute position or velocity:** either reconstructs the trace; the
  demo does not disambiguate. Pitch-change support (Scratch Pitch) suggests motion is stored in a
  form independent of sample length (consistent with position/velocity, not audio frames).
- **"XF Invert" exact semantics** (swap which side is audible vs invert the cut pattern) inferred,
  not confirmed frame-by-frame.
- These uncertainties do not affect the core conclusion: notation = sample-independent performance
  gesture data, audio re-synthesised at replay.
