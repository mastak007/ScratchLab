# ScratchLab Input Layer — RANE ONE (macOS, standalone, no Serato)

**Scope of this document:** the **input layer only**. How ScratchLab captures scratch *gestures*
from a RANE ONE on macOS and turns them into a normalized, recordable stream.

**Explicitly out of scope (do not design here):** notation rendering, coaching, DVS/timecode
decoding, audio synthesis, networking, cloud, machine learning. Constraints: macOS only,
standalone, no Serato dependency.

This builds directly on the V1.2 system-model conclusion: ScratchLab's source of truth must be the
**performance gesture stream** (`motion(t)` + `crossfader(t)` + `clock`), not recorded audio. This
document defines the layer that *produces* that stream.

---

## 0. What we actually know (verified) vs must validate

**Verified from research:**
- The RANE ONE is **fully class-compliant on macOS** — no manufacturer driver required
  ([Rane FAQ](https://support.rane.com/en/support/solutions/articles/69000814127-rane-dj-one-frequently-asked-questions)).
  So it appears to the OS as a standard USB-MIDI (and USB-audio) device.
- It is **marketed/positioned as a Serato controller**; Rane does **not document** generic
  third-party MIDI use, and does **not document** the jog/platter wire format
  ([Rane FAQ](https://support.rane.com/en/support/solutions/articles/69000814127-rane-dj-one-frequently-asked-questions)).
- The platter uses a high-count optical encoder (community figures cite ~4096 counts/rev for the
  ONE; the related Rane Twelve MKII cites 3600 ticks/rev — both unverified for the *wire* protocol)
  ([Mixxx hardware discussion](https://github.com/mixxxdj/mixxx/wiki/Hardware-Compatibility)).

**Therefore the single most important fact is unverified:** *whether the motorized platter emits
usable position data over class-compliant MIDI to a non-Serato app, or whether high-resolution
platter data is only available via a HID / proprietary path used in Serato.* On motorized battle
controllers this is commonly HID. **We must not assume MIDI exposes the platter.** The architecture
below is built so the first thing we do is *find out*, cheaply, with a dev tool — and so that the
answer (MIDI, HID, or both) does not change the rest of the system.

This is why the design is **transport-abstracted and MIDI-first**: MIDI is the clean, class-
compliant, App-Store-safe path; HID is designed-for but deferred until the Inspector proves it is
needed.

---

## 1. Architecture (conservative, smallest viable)

Five layers, each replaceable, talking only to the next:

```
┌─────────────────────────────────────────────────────────────┐
│ 5. Consumers (LATER): notation / coaching / replay / analysis │  ← not built now
├─────────────────────────────────────────────────────────────┤
│ 4. GestureStream + Recorder  (source of truth)                │
│      • normalized ScratchInputFrame sequence                  │
│      • retains RawInputEvent log for re-derivation            │
├─────────────────────────────────────────────────────────────┤
│ 3. Normalizer / HAL                                           │
│      • DeviceProfile maps raw → semantic controls             │
│      • PlatterAccumulator (unwrap + velocity)                 │
│      • FaderNormalizer (7/14-bit → 0…1 + velocity)            │
│      → emits ScratchInputFrame                                │
├─────────────────────────────────────────────────────────────┤
│ 2. Transport(s)  → RawInputEvent (timestamped)                │
│      • MIDITransport (Core MIDI)         ← FIRST               │
│      • HIDTransport (IOHIDManager)       ← deferred stub       │
├─────────────────────────────────────────────────────────────┤
│ 1. Hardware: RANE ONE over USB (class-compliant)              │
└─────────────────────────────────────────────────────────────┘
                         │
              ┌──────────┴───────────┐
              ▼                      ▼
   ControllerInspectorView    (future consumers subscribe here)
   (dev-facing, display-only)
```

Key principles:
- **Transport is a detail.** Layers 3–5 never know whether a value came from MIDI or HID. Adding
  HID later does not touch the HAL, the frame, the recorder, or any consumer.
- **Raw is preserved.** Every byte that arrives is captured as a timestamped `RawInputEvent` before
  any interpretation. The normalized frame is *derived*; the raw log lets us re-derive if a mapping
  or calibration is wrong (this directly protects the "source of truth" guarantee).
- **One device first.** No multi-deck orchestration, no device manager complexity beyond "find the
  RANE ONE and read it."
- **Input only.** No MIDI/HID *output* to the device (no motor control, no LED feedback) in this
  layer. We only listen.

---

## 2. Transport facts and choices

### MIDI availability — PRIMARY path
- Class-compliant ⇒ the ONE's control surface (buttons, knobs, faders, FX paddles, and *possibly*
  the jog/platter) is reachable through **Core MIDI** with zero drivers.
- High confidence: the **crossfader and standard controls send MIDI CC/notes**. (Faders on class-
  compliant controllers are standard MIDI; 7-bit or 14-bit MSB/LSB to be determined.)
- Unverified: whether the **platter** appears on MIDI, and at what resolution/format.

### HID availability — FALLBACK path (deferred)
- macOS exposes the device's HID interface via **IOHIDManager** (IOKit). If the platter's full
  resolution is HID-only, this is where we get it.
- Cost: HID reports are proprietary/undocumented for the ONE → requires reverse-engineering byte
  offsets via the Inspector, and under the App Sandbox likely needs a USB/HID entitlement (App-
  Store-review risk). **This is exactly why MIDI is tried first.**

### Platter exposure — the decision rule
We do **not** decide in advance. Slice 1 (below) is a raw MIDI monitor. We spin the platter and
watch:
- **If** the platter produces sane, sufficiently-dense MIDI → ship MIDI-only; never build HID.
- **If** it produces nothing, or only coarse/low-rate data → escalate to the HID path (new
  transport, same HAL).

### Positional resolution — realistic expectations
- Encoder hardware is fine (thousands of counts/rev). The *deliverable* resolution depends on the
  wire format, which is the unknown:
  - 7-bit **relative** jog CC (e.g. ±1 tick messages): common in generic MIDI mode; adequate for
    nudging, **likely marginal for fast scratch** (aliasing/jitter).
  - 14-bit **absolute** angle (MSB/LSB) or a dense relative stream: good for scratch.
  - HID report with raw encoder counts: best.
- **Conservative assumption for planning: treat usable scratch-grade platter data as NOT YET
  PROVEN.** The Inspector exists to convert this assumption into a measured fact.

---

## 3. Data flow

```
RANE ONE (USB)
   │  class-compliant USB-MIDI
   ▼
Core MIDI  ── MIDIClientCreateWithBlock (hotplug notifications)
           └─ MIDIInputPortCreateWithProtocol(._1_0, receiveBlock)
              MIDIPortConnectSource(<RANE ONE source>)
   │  (receiveBlock fires on a high-priority Core MIDI thread)
   ▼
RawInputEvent { transport:.midi, deviceID, hostTime, bytes }   ← timestamp captured HERE
   │  pushed onto a lock-free ring buffer / serial queue (never block the MIDI thread)
   ▼
DeviceProfile (RaneOneProfile): bytes → SemanticControl updates
   │  e.g. CC 0x.. → .crossfaderAbsolute(value)
   │       <platter msg> → .platterDelta(ticks)  /  .platterAbsolute(angle)
   ▼
PlatterAccumulator (unwrap + accumulate → continuous position; dPos/dt → velocity)
FaderNormalizer (pair MSB/LSB if 14-bit; scale → 0…1; dVal/dt → velocity)
   ▼
ScratchInputFrame  (normalized, device-agnostic, timestamped)
   ├──────────────► Recorder / GestureStream   (full rate, in-memory first → source of truth)
   └──────────────► ControllerInspectorModel    (throttled to ~60 Hz for the UI; main actor)
```

**Threading discipline (conservative):**
- The Core MIDI receive block must do *minimal* work: copy bytes + timestamp into a `RawInputEvent`,
  enqueue, return. No allocation-heavy or UI work on that thread.
- A single serial `DispatchQueue` (or an actor) drains the queue, runs decode/accumulate, and emits
  frames.
- UI updates marshal to the main actor and are **throttled** (coalesce to display rate); recording
  consumes **every** frame.

**Timestamps:**
- Use the Core MIDI packet `MIDITimeStamp` (mach host-time units) as the authoritative event time,
  converted to seconds via `mach_timebase_info`. If a packet's timestamp is 0 ("now"), substitute
  `mach_absolute_time()` at receipt. One monotonic clock for everything so MIDI and (future) HID
  events are comparable.

---

## 4. Hardware Abstraction Layer (so future devices map identically)

The internal model is device-agnostic. A new device = a new **DeviceProfile** (data + a thin
decoder), not changes to the frame, accumulator, recorder, or consumers.

A `DeviceProfile` declares:
- **Identity / matching:** USB name string and/or VID:PID used to recognize the device in Core MIDI
  (and later HID).
- **Transport:** `.midi`, `.hid`, or `.hybrid` (which controls come from which transport).
- **Control map:** raw event (CC#, note, or HID byte offset/bitfield) → `SemanticControl`.
- **Platter constants:** `ticksPerRevolution`, encoding (`relativeTicks` | `absoluteAngle`),
  bit-depth, and whether the platter reports a **motor baseline** (continuous nominal rotation) or
  only hand-induced movement.
- **Fader constants:** range, bit-depth (7 / 14), and whether the hardware applies a cut/curve
  before reporting (we want raw position).

Target devices and what the HAL anticipates (all behind the same model):

| Device | Vendor | Likely transport for high-res platter | Notes for the profile |
|---|---|---|---|
| **RANE ONE** | inMusic/Rane | MIDI (TBD) → HID fallback | First profile; battle controller, motorized |
| RANE FOUR | inMusic/Rane | MIDI/HID (TBD) | 4-deck; more controls, same platter family expected |
| RANE PERFORMER | inMusic/Rane | MIDI/HID (TBD) | Mixer-style; platter exposure TBD |
| Pioneer REV7 | AlphaTheta | **HID likely** (motorized) | Pioneer high-res jog usually HID; may need a MIDI mode |
| Pioneer REV5 | AlphaTheta | HID likely (non-motorized jog) | |
| Pioneer FLX10 | AlphaTheta | HID likely | 4-deck |
| Pioneer GRV6 | AlphaTheta | HID likely | |

The table is **expectation, not fact** — each row is a future validation task. The point is the HAL
already has the slots (`transport`, `encoding`, `ticksPerRevolution`, control map) to absorb these
differences without restructuring. Pioneer devices are flagged HID-likely precisely so the HID
transport we *stub* now is the thing that unlocks them later.

---

## 5. Canonical `ScratchInputFrame`

A normalized, device-independent snapshot. Continuous quantities are **accumulated/unwrapped**, not
wrapped, because gesture capture needs displacement, not angle modulo one turn.

Conceptual fields (names indicative, not an API):

```
ScratchInputFrame
  timestamp            : monotonic seconds (Double), single clock
  sequence             : monotonically increasing frame index
  deck                 : deck identifier (RANE ONE: .left / .right)

  platterPosition      : Double  — accumulated revolutions, signed (forward +)
                                    continuous; not reset per turn
  platterVelocity      : Double  — revolutions/second, signed (derived dPos/dt)
  platterBaseline      : enum    — .motorNominal | .static  (is a play-speed baseline present?)

  crossfaderPosition   : Double  — normalized 0.0 … 1.0 (raw fader position, pre-curve)
  crossfaderVelocity   : Double  — units/second, signed

  source               : { deviceID, transport(.midi/.hid), profileID }
  rawRefs              : references to the RawInputEvent(s) that produced this frame
```

Supporting types:
- `RawInputEvent { transport, deviceID, hostTimeSeconds, bytes }` — the un-interpreted truth.
- `SemanticControl` — `.platterDelta(ticks)`, `.platterAbsolute(angle)`, `.crossfaderAbsolute(v)`,
  `.crossfaderMSB/LSB(...)`, extensible. The decoder's only job is raw → `SemanticControl`.

Design notes:
- **Position is the canonical platter quantity; velocity is derived** (don't trust device-reported
  velocity; compute from position + timestamp so all devices behave identically).
- **Why normalized units (revolutions, 0…1 fader):** lets every device map into the same numbers;
  consumers never special-case a device.
- **`platterBaseline`** captures the motorized-platter subtlety: with the motor on, the platter
  rotates continuously at nominal speed, so `platterVelocity` rests near nominal play speed, not 0.
  Recording this flag lets later layers reason about "scratch = deviation from baseline" without the
  input layer having to make that judgment now.
- Frames may be **event-driven** (one per processed input burst) rather than fixed-rate; a fixed
  resample is a later, optional convenience. Event-driven preserves true timing.

---

## 6. Recording gesture streams as the source of truth

Two tiers, mirroring the V1.2 model:

1. **Authoritative raw log:** the full `RawInputEvent` sequence (timestamped bytes + device/profile
   id + profile version). This is the ground truth — lossless, and re-derivable into frames if a
   mapping/calibration is later corrected.
2. **Working source of truth:** the derived `ScratchInputFrame` sequence (the normalized
   `motion(t)` + `crossfader(t)` + `clock`). This is what consumers read.

A recording = `{ deviceProfile snapshot, raw event log, derived frame stream, clock metadata }`.
**No audio is recorded.** This is the whole point: because we persist *gestures*, not sound, the
later features in §7 become possible. In-memory capture is enough to *prove* the slice; a durable
on-disk format is deliberately deferred (it does not affect the architecture).

---

## 7. How this input layer enables later features (no design here — only the link)

Because the captured artifact is the normalized gesture stream (motion + fader + time), and audio is
absent:
- **Notation generation:** the motion lane is `platterPosition/velocity` over time; the fader lane
  is `crossfaderPosition` over time. The stream is exactly the notation renderer's input.
- **Replay:** re-emit the recorded frames (or raw log) through a future synthesis engine →
  deterministic reproduction, because gestures fully determine the performance.
- **Sample swapping:** gestures drive a playhead through *whatever* sample buffer; the input layer
  guarantees gestures are stored independently of any audio, so the sample is free to change.
- **Beat muting:** the beat is a separate layer the input never touches/entangles; muting it cannot
  affect the captured gestures.
- **Crossfader mute bypass ("XF Cuts off"):** the crossfader is stored as *position data*, not as
  applied silence — so replay can choose to apply or ignore the cut. Only possible because we
  captured the fader **gesture**, not gated audio.
- **Timing analysis:** every frame carries a high-resolution monotonic timestamp → inter-event
  timing, velocity, and rhythm come straight from the stream.

---

## 8. Required frameworks (macOS native, no third-party)

- **Core MIDI** (`CoreMIDI`) — primary transport. Client + input port + source connection +
  block receive. Provides `MIDITimeStamp`.
- **IOKit / IOHIDManager** (`IOKit`) — HID fallback transport. **Deferred** (stub only in slice 1).
- **Mach time** (`mach_time` / `mach_timebase_info`) — convert host timestamps to a monotonic
  seconds clock.
- **SwiftUI** + **Combine/AsyncStream** (or a simple observable model) — the dev-facing Inspector
  window and the frame/event pipelines. UI is display-only.
- **Foundation** — basic types/queues.
- No audio framework yet (input layer only). No networking/cloud/ML frameworks (and none allowed).

---

## 9. Controller Inspector (developer-facing, display-only)

Purpose: the discovery + validation instrument. It is how we answer the §0/§10 unknowns.

Displays, live:
- **Raw incoming events:** a scrolling, timestamped list — transport, source name, status/CC/note,
  data bytes, channel. (Slice-1a is essentially *only* this.)
- **Derived per-deck values:** `platterPosition`, `platterVelocity`, `crossfaderPosition`,
  `crossfaderVelocity`, each with the **timestamp** of last update.
- **Connection state:** which device(s) Core MIDI sees, profile matched (or "unrecognized").
- Useful read-outs for validation: event **rate (Hz)** for the platter, min/max observed values,
  and whether timestamps are device-provided or substituted.

It writes nothing to the device and renders no notation — it is a numeric/event monitor only.

### 9.1 Uploaded MIDI nib reference — UI ideas only

A set of compiled macOS `.nib` files (`MIDI.nib/keyedobjects*.nib`) was supplied as **visual/UX
reference for a generic MIDI window**. They are **inspiration only** — explicitly:
- **Not source code** for ScratchLab, not to be imported, decompiled, or reused.
- **No controller mappings** and **no RANE ONE support** inside them. A read-only `strings` scan
  confirmed this: the nibs contain only the generic UI outlets/actions below and **no** `rane`,
  `scratch`, `crossfader`, `platter`, `jog`, or CC-number strings.
- The main class string is `MIDIMessagesWindowController` (a third-party/sample MIDI window).

What the nib shows (and which maps onto a *future* ScratchLab Controller Inspector, §9):

| Nib concept (outlet/action) | ScratchLab Inspector idea (future) |
|---|---|
| `_inputPopUpButton` / Inputs | MIDI input device picker |
| `_outputPopUpButton` / Outputs | MIDI output device picker (optional; we are input-first) |
| `_inIndicator` / `_outIndicator` | input / output activity indicators |
| `_statusMessageView` / `_dataMessageView` | raw MIDI status + data event log |
| `_mappingTableView` / Mappings | normalized-event table + a mapping table |
| `onMappingSave/Load/Reset/Delete:` | mapping save / load / reset (delete optional) |
| `toggleMessageLogging:` / "Log MIDI Messages" | raw-event logging toggle |
| `onUseMIDIClock:` / "Sync Beat to MIDI Clock" | MIDI clock sync toggle (optional / later) |
| "Channel 1 Mode" / "Channel 2 Mode" | Deck 1 / Deck 2 mode sections |
| "Shift/Layer Buttons" | shift/layer button mapping support |

**Scope note:** these are UI ideas for a *later* developer-facing Inspector. They do **not** change
Phase 1, which remains model/protocol/stub + tests only (no UI). The output-selector, MIDI-clock
sync, and mapping persistence are explicitly **optional/later**; the first build of the Inspector
(when approved) is still just the raw-event monitor described in §9 and the slice-1a of §12.

### 9.2 Reference app XML settings findings

The reference notation app ("Scratch visualizer.app") stores its config as plain XML
(`Contents/Resources/data/settings.xml`, `SVMidiMap.xml`). These were inspected as **reference
only** (not imported). `cacert.pem` in the same folder is unrelated to MIDI and is ignored.

**`settings.xml` — real MIDI/control configuration (verified):**

| Key | Value | Meaning |
|---|---|---|
| `MIDIDEVICE` | `Other` | a manually-configured generic device (not an auto-detected named profile) |
| `XFADERCH` | `7` | crossfader MIDI channel |
| `XFADERCC` | `63` | crossfader MIDI CC number |
| `INVERTXFADER` | `0` | fader inversion flag |
| `XFCURVE` | `0.333…` | crossfader curve shape |
| `JOGMODE` | `1` | jog/platter mode selector |
| `CONTROLLER` | `5` | a controller preset index |
| `FORMAT` | `Serato` | timecode/control format label |
| `SAMPLERATE` / `BUFFERSIZE` | `44100` / `256` | audio I/O config |
| `RPM33VELOCITY` | `1.172…` | platter RPM/velocity calibration |
| `SMOOTHING` | `0.583…` | platter motion smoothing |
| `PITCHBEND` / `NOTEONOFF` | `1` / `1` | MIDI message-type options |

**`SVMidiMap.xml` — generic mapping table:** a small set of `KEYnn` entries, each holding
`CHANNEL`, `MESSAGETYPE` (an opaque enum — note/CC/etc., not assumed), `MESSAGEVALUE`, and
`KNOBBINDING`. It is a generic MIDI→action persistence table; it does **not** reveal platter/jog
mapping. Useful only as a *shape* for how ScratchLab might persist mappings.

**Conclusions for ScratchLab (input layer):**
1. **Persist controller mappings as data, not hard-coded.** Mirrors the existing `DeviceProfile`
   seam (§4); these XML files confirm the reference app does exactly this.
2. **Crossfader mapping should be a configurable record:** MIDI channel, CC number, invert, curve,
   and an open/closed threshold.
3. **Jog/platter mapping should carry:** jog mode, smoothing, and RPM/velocity calibration (the
   `ScratchInputFrame.platterBaseline` concept in §5 pairs with `RPM33VELOCITY`-style calibration).
4. **The Controller Inspector (§9) should display and save discovered mappings** (MIDI-Learn style),
   matching the nib's `_mappingTableView` + `onMappingSave/Load/Reset` ideas (§9.1).
5. **RANE ONE Phase 1 must *test* — not assume — that the crossfader appears on channel 7 / CC 63.**
   That value is **this user's saved "Other"-device setup**, configured by hand — it is **not** a
   universal RANE ONE fact. Slice-1a (§12) should check whether ch 7 / CC 63 carries the crossfader
   on the actual hardware and record what it finds; the profile is data, not a constant.

**Bonus cross-validation of the notation specs (not input-layer, noted for completeness):** the
`GRAPHICS` block corroborates the V1/V1.1 notation findings — `WAVECOLOR` = red (255,0,0) trace;
`XOPEN`/`XCLOSE` + `…DOTSIZE` = the open/close **click/reversal dots**; `CLOSEDALPHA` ≈ 0.34 =
the **dim muted segments** seen in the Transformer; `COLORVELOCITY` = **colour-by-velocity**
(the cyan/green gradient). These confirm the fader-cut/click and audibility rendering described in
`notation_truth_spec*.md`.

**Scope note:** this changes nothing in Phase 1 — still model/protocol/stub + tests, no UI, no
implementation. It only sharpens what a future `DeviceProfile` and Inspector should eventually carry.

---

## 10. Risks

- **R1 — Platter may not be on MIDI at all** (Serato-only HID/proprietary). *Highest risk.* Could
  force the HID path (more work, sandbox/entitlement questions). Mitigation: discover in slice 1a
  before building anything else.
- **R2 — Platter MIDI resolution/rate too low for scratch** (e.g. 7-bit relative). Mitigation:
  measure ticks/rev and event Hz in the Inspector; decide MIDI-vs-HID on data.
- **R3 — Device needs initialization to report** (handshake/SysEx/HID enable, or expects motor/
  Serato-style setup before sending platter data). Could mean "nothing arrives" misread as "no MIDI
  platter." Mitigation: test with controls we *know* are simple (crossfader) first to confirm the
  device is talking at all.
- **R4 — Motor-baseline confusion:** motorized platter rotates continuously; velocity baseline ≠ 0.
  Mitigation: `platterBaseline` flag; validate motor-on vs motor-off behavior.
- **R5 — 14-bit fader pairing:** MSB/LSB must be paired or the fader looks coarse/jumpy. Mitigation:
  handle in `FaderNormalizer`; detect bit-depth in Inspector.
- **R6 — Relative-vs-absolute platter / wrap handling:** wrong assumption → drift or discontinuities.
  Mitigation: determine encoding empirically; `PlatterAccumulator` supports both.
- **R7 — Timestamp fidelity:** device may not populate `MIDITimeStamp` meaningfully. Mitigation:
  substitute receipt time; surface which is in use.
- **R8 — App Store / sandbox for HID:** IOHIDManager access likely needs a USB/HID entitlement and
  review scrutiny. MIDI path avoids this. Mitigation: keep MIDI-first; treat HID as a scoped,
  reviewed addition only if R1/R2 force it.
- **R9 — Hot-plug / USB disconnect** mid-session. Mitigation: Core MIDI setup-change notifications;
  handle gracefully (out of slice-1 critical path but designed for).
- **R10 — MIDI-thread misuse** (blocking/allocating in the receive block) → dropped/late events.
  Mitigation: strict "copy + enqueue + return" discipline.

---

## 11. Unknowns requiring hardware validation (the test checklist)

1. Does the **platter emit anything over class-compliant MIDI** to a non-Serato app? (yes/no)
2. If yes: **which message** (CC#/note), **relative or absolute**, **7- or 14-bit**, and **effective
   ticks/rev** actually delivered.
3. **Event rate** of the platter during slow vs fast scratching (Hz); does macOS/the device
   coalesce or drop events under load?
4. Any **initialization** required before the platter reports?
5. **Motor baseline:** does the encoder report continuous nominal rotation when playing? Is there a
   motor-off/vinyl mode that zeroes it?
6. **Crossfader:** CC#, bit-depth, range; is a hardware cut/curve applied before reporting?
7. **Latency** physical-move → event-arrival (subjective first, instrumented later).
8. **Timestamp** fidelity: are `MIDITimeStamp`s meaningful or zero?
9. The ONE's **USB name / VID:PID** as seen by Core MIDI (for profile matching).

Slice 1 is designed to answer 1, 2, 6, 8, 9 immediately and 3–5, 7 with light experimentation.

---

## 12. Recommended first implementation slice (smallest proof)

**Goal of the slice:** prove that ScratchLab can see the RANE ONE's gestures in real time over MIDI,
standalone, and produce sane normalized platter + crossfader values with timestamps.

- **1a — Raw MIDI monitor.** A minimal SwiftUI macOS app: open a Core MIDI client + input port,
  connect *all* sources, and stream **every** raw event into the Inspector list (timestamped).
  Move the crossfader, spin the platter; observe what arrives. *This alone answers R1/R3 and
  unknowns 1, 2, 6, 9.* No HAL, no frames yet.
- **1b — RANE ONE profile + normalized values.** Add `RaneOneProfile` mapping the observed
  crossfader CC and platter message to `SemanticControl`s; run `PlatterAccumulator` +
  `FaderNormalizer`; display the four derived values + timestamps. Add an in-memory `GestureStream`
  capture (start/stop → list of `ScratchInputFrame`) to confirm the stream is coherent.

**Deliberately excluded from the slice:** HID, multi-device, any output to the device, on-disk
recording format, audio, notation, coaching, replay. MIDI-only, one device, in-memory.

**Definition of done:** with a RANE ONE plugged in and no Serato running, the Inspector shows live
crossfader position and live accumulated platter position/velocity with monotonic timestamps, and a
short capture yields a coherent in-memory `ScratchInputFrame` sequence. If platter data is absent or
too coarse, the slice has still *succeeded* — it has produced the measured decision to pursue HID.

---

## 13. Files / classes to create (slice 1)

Small and flat; transport-abstracted so HID drops in later.

- `RawInputEvent.swift` — struct: transport, deviceID, hostTimeSeconds, bytes.
- `ScratchInputFrame.swift` — the canonical normalized frame (§5).
- `SemanticControl.swift` — enum of decoded controls.
- `Clock.swift` — mach timebase → monotonic seconds; timestamp helpers.
- `MIDITransport.swift` — Core MIDI client/port/source plumbing; emits `RawInputEvent`; hotplug
  notifications. (Conforms to an `InputTransport` protocol.)
- `InputTransport.swift` — protocol both transports implement (so HID is interchangeable).
- `HIDTransport.swift` — **stub** conforming to `InputTransport` (no implementation yet).
- `DeviceProfile.swift` — protocol/struct for identity, transport, control map, platter/fader
  constants.
- `RaneOneProfile.swift` — the first concrete profile (filled in from slice-1a observations).
- `PlatterAccumulator.swift` — unwrap/accumulate position; derive velocity.
- `FaderNormalizer.swift` — bit-depth/pairing → normalized position + velocity.
- `InputEngine.swift` — owns transport(s) + profile; drains events; emits `ScratchInputFrame`s;
  exposes a frame stream + raw-event stream.
- `GestureStream.swift` — in-memory recorder (frames + retained raw events) = source of truth.
- `ControllerInspectorModel.swift` — observable, throttled view model for the UI.
- `ControllerInspectorView.swift` — SwiftUI dev window (raw event list + derived values + timestamps).

That is the entire footprint to prove RANE ONE gesture capture works — and it is already the
skeleton that notation, replay, sample-swap, beat-mute, cut-bypass, and timing analysis will hang
off later.

---

## 14. DVS / timecode comparison (added — does DVS help standalone capture?)

This section was added to evaluate whether a **DVS/timecode** input path would help ScratchLab
capture scratch gestures standalone. **It does not change the recommended first slice** (§12) — the
evidence below supports keeping MIDI/HID first and treating DVS as a later, parallel transport.

### 14.0 What DVS is
A Digital Vinyl System reads a **control vinyl** (or control CD) pressed with a **timecode signal**:
a stereo audio tone (two channels in quadrature) whose **frequency encodes speed**, whose
**inter-channel phase encodes direction**, and which usually carries an embedded **bitstream
encoding absolute position** on the record (so needle-drops land in the right place). Software
digitizes the turntable's phono output and decodes that tone into platter motion.

### 14.1 RANE ONE MIDI/HID vs DVS — head to head

| Dimension | RANE ONE MIDI/HID | DVS / timecode |
|---|---|---|
| Platter position | Maybe (unverified; §0) | **Yes** — relative immediately, absolute once locked |
| Platter velocity | Derived from position | **Yes** — from decoded frequency/pitch |
| Platter direction | From position sign | **Yes** — from quadrature phase lead/lag |
| Crossfader position | **Likely yes** (CC) | **No** (not in the timecode) |
| Line faders / EQ / buttons | **Yes** (MIDI) | **No** |
| Fader *clicks* (cut timing) | **Yes** (if mixer/controller sends them) | **No** |
| Hardware reach | Controllers (RANE ONE, etc.) | **Real turntables** + any DVS-capable rig |
| Input medium | USB control data (bytes) | **Audio signal** (must be captured + DSP-decoded) |
| Setup complexity | Low (class-compliant MIDI) | High (audio interface, decode, calibration) |
| App-Store / IP profile | Clean (MIDI); HID needs entitlement | **Multiple IP + entitlement concerns** (§14.4) |

### 14.2 What DVS GIVES ScratchLab
- **Platter position** — relative tracking is available the instant the stylus is reading tone;
  **absolute position** is available if the timecode's position bitstream is decoded and locked
  (this is what makes needle-drop and skip detection possible).
- **Platter velocity** — directly from the decoded tone frequency vs the nominal tone frequency.
- **Direction** — from which channel leads in the quadrature pair (forward vs reverse).
- **Absolute vs relative** — both are theoretically available: relative is cheap and immediate;
  absolute requires more decode work and a brief lock-in. ScratchLab's gesture capture mostly needs
  *relative displacement over time*, which DVS supplies well.

In short, DVS is a **strong platter-motion source**, and uniquely it works with **real turntables**,
not just controllers.

### 14.3 What DVS does NOT give ScratchLab
- **Crossfader position** — not in the timecode. Must come from the mixer/controller via MIDI/HID.
- **Line-fader position** — same.
- **Button / pad / FX states** — same.
- **Exact fader clicks (cut timing)** — the rhythmic core of Chirp/Transformer/flare-family
  scratches (per V1.1/V1.2) is **invisible to DVS**. It lives in the mixer's crossfader, not the
  vinyl.
- **Beat / sample ownership** — DVS only tells you how the record is moving; it does not own or
  provide the audio material, the beat, or the sample. (ScratchLab still owns those per V1.2.)

**This is the crux:** the V1.1/V1.2 conclusion is that notation is a **hybrid of two co-equal
timelines — motion AND crossfader**. DVS captures the motion timeline beautifully but captures
**none** of the crossfader timeline. So **DVS alone cannot capture a scratch performance** the way
ScratchLab defines it; it must still be paired with MIDI/HID for the fader. That single fact
answers the replace-vs-augment question.

### 14.4 New risks introduced by DVS
- **Timecode IP / licensing.** Serato's **NoiseMap is proprietary, copyright-registered IP**
  (LFSR-generated control tone) — ScratchLab cannot freely decode Serato control vinyl. DVS-era
  patents (N2IT/Final Scratch, ~2001) may be expiring but **require legal review**. ScratchLab would
  need an **open or self-generated timecode**, not a third-party proprietary one.
- **Decoder license contamination.** The obvious reference decoder, **xwax/libxwax, is GPL**, and
  its own documentation states the timecode decoder **may not be copied into proprietary software**
  without a separate license. A closed, App-Store ScratchLab therefore **cannot link GPL DVS code**
  — it would need a clean-room/permissively-licensed or self-written decoder. Significant effort/risk.
- **Decoding complexity.** Real-time quadrature decode, phase/PLL tracking, absolute-position
  bitstream extraction, and noise rejection are far more involved than reading MIDI bytes.
- **Audio-interface routing.** DVS needs the turntable's **phono signal digitized** (phono preamp +
  audio interface, or a Rane/RANE-ONE input path). The standalone app must **capture audio input**
  and manage device routing — a new dependency the MIDI path does not have.
- **Latency.** Audio-buffer + DSP latency exceeds MIDI's near-immediate events; cross-aligning DVS
  platter data with MIDI fader data requires a **common clock** (already in the architecture, §3).
- **Noisy signal.** Dust, worn vinyl, hum/grounding, cheap interfaces → tracking errors and jumps;
  needs robustness work.
- **Absolute vs relative ambiguity** at start / after dropout.
- **33 / 45 RPM calibration.** Timecode is tuned to a nominal RPM; the turntable's pitch fader and
  RPM setting change effective speed — must be known/declared and calibrated.
- **Needle drop / skipped groove.** Stylus lift → signal loss (must detect dropout + re-lock);
  groove skip → position discontinuity (must detect and not mis-record as a gesture).
- **App-Store review.** Audio-input capture needs a microphone/audio entitlement + usage string;
  bundling/decoding proprietary timecode is a **rejection/legal risk**; GPL decoder is
  **license-incompatible** with a closed app. Several stacked concerns vs the clean MIDI path.

### 14.5 Replace the inspector slice, or parallel transport?
**Parallel transport, later — not a replacement.** Reasons:
1. **Crossfader is mandatory and DVS cannot provide it.** Even a perfect DVS build still needs
   MIDI/HID for the fader. So MIDI/HID is non-optional regardless.
2. **The cheapest way to learn the RANE ONE platter situation is the MIDI inspector** (§12), which
   we need to build anyway.
3. **DVS carries materially higher IP, complexity, and review risk**; front-loading it would slow
   the core proof.
4. The existing **transport abstraction + single clock** (§1, §3) already make DVS a clean drop-in
   later: it is just another `InputTransport` emitting platter `SemanticControl`s.

### 14.6 How both feed the same normalized model
No new model is needed — DVS slots into §4/§5:
- Add `transport: .dvs`. A `DVSTransport` decodes the audio tone and emits **platter**
  `SemanticControl`s (`.platterAbsolute`/`.platterDelta`, direction, velocity) → the **same**
  `PlatterAccumulator` → the **same** `ScratchInputFrame.platterPosition/Velocity`.
- The **crossfader** continues to come from a MIDI/HID transport (the mixer/controller) →
  `ScratchInputFrame.crossfaderPosition`.
- The `InputEngine` **fuses** the two transports by **timestamp on the common monotonic clock**
  (§3) into unified frames. This requires a notion of a **composite device** (platter source = DVS,
  fader source = a MIDI mixer) — a small extension to `DeviceProfile`, not a model change.
- `RawInputEvent` gains a DVS variant (decoded tone samples/derived position) so the raw log stays
  the re-derivable source of truth.

### 14.7 Practical order
**MIDI/HID controller inspector first; DVS as a later research spike; not in parallel for slice 1.**
The fader requirement (14.3) and the lower risk/effort of MIDI make the inspector the correct first
move. A DVS spike should be **offline first** (decode a *recorded* timecode audio file into platter
position/velocity/direction) to evaluate feasibility, IP, and robustness **before** any real-time or
product integration.

### Key decision — does DVS make ScratchLab more capable, or just broaden hardware?
**It broadens the platter hardware ScratchLab can understand (adding real turntables) and provides
excellent platter-motion data — but it does not make ScratchLab fundamentally more capable, because
it captures none of the crossfader/control timeline that a scratch performance also requires.**
Therefore DVS is a **later parallel transport**, layered onto the same normalized model alongside
MIDI/HID — **never a replacement** for the RANE ONE input-inspector slice.

---

## 15. Revised roadmap

The first slice (§12) is **unchanged**. DVS is appended as later phases.

- **Phase 1 — RANE ONE MIDI/HID inspector.** The §12 slice: raw MIDI monitor (1a) → RANE ONE profile
  + normalized platter/crossfader values + timestamps (1b). Answers the §11 unknowns. MIDI-only,
  one device, in-memory.
- **Phase 2 — Controller profile + gesture stream.** Harden `RaneOneProfile`; finalize
  `ScratchInputFrame` capture end-to-end; durable `GestureStream` recording (raw log + derived
  frames) = source of truth. If Phase 1 shows the platter is HID-only/too coarse, implement the HID
  transport here (behind the same HAL).
- **Phase 3 — DVS / timecode research spike.** **Offline, non-product.** Decode a *recorded*
  timecode signal into platter position/velocity/direction; assess accuracy, noise handling,
  absolute-lock, RPM calibration, needle-drop/skip behaviour; and resolve the **IP/licensing**
  question (open/self-generated timecode; clean-room/permissive decoder — **no GPL**). Output: a
  go/no-go with measured feasibility, not code in the product.
- **Phase 4 — Unified input transport model.** If Phase 3 is go: add `DVSTransport` and `.dvs` as a
  parallel `InputTransport`; introduce **composite-device** profiles (platter ← DVS, fader ← MIDI
  mixer); fuse transports by timestamp on the shared clock into unified `ScratchInputFrame`s. Add
  audio-input capture + the required entitlements. The normalized model, recorder, and consumers are
  untouched — DVS simply becomes another way to fill `platterPosition`.

---

## 16. Input-source reassessment — DVS-central reinterpretation (v1.3)

New evidence (all notation videos use real turntables + control vinyl; the reference app runs
standalone with Serato closed; `settings.xml` stores `FORMAT=Serato`, `RPM33VELOCITY`, `SMOOTHING`,
`JOGMODE`, audio-input channels, and the crossfader as MIDI **but no jog/platter CC**) forces a
re-reading of how the *reference app* captures platter motion. This section reassesses only; it does
**not** change the committed Phase 1 stubs and does **not** discard `ScratchInputFrame`.

### 16.1 The key realization
The reference config stores the **crossfader as MIDI (ch7/CC63)** yet stores **no jog/platter CC at
all** — instead it stores a **timecode-decode pipeline** (`FORMAT=Serato`, `RPM33VELOCITY`,
`SMOOTHING`, `JOGMODE`) plus **audio input channels** (`LEFTIN/RIGHTIN`). With real vinyl in every
video, the most likely reading is:
> **Reference app = DVS-format timecode for platter motion + MIDI CC for crossfader + its own
> sample/beat/replay engine.** Not Serato-integrated; not mixed-audio.

### 16.2 What FORMAT = Serato most likely means
A **decoder-format selector** — "interpret incoming control-vinyl timecode with the Serato-format
(NoiseMap) decoder," chosen among formats the way xwax/Mixxx pick a vinyl type. It is **not**
"control the Serato application" and **not** "require Serato running." The adjacent audio-I/O + RPM +
smoothing keys are exactly a timecode-decode pipeline's settings.

### 16.3 Why Serato-format timecode ≠ Serato-app dependency
Control vinyl is just an audio tone pressed to a record. Any app with a decoder for that tone reads
it from its own audio input; the Serato app is a *separate* consumer of the same record. (Caveat,
§14.4: the NoiseMap tone is proprietary IP — decoding it in a shipping product is a licensing
question — but functionally it implies **no** dependency on the Serato app.)

### 16.4 Reclassified input models (evidence table)

| Model | Evidence for | Evidence against | Confidence |
|---|---|---|---|
| **A. MIDI/HID controller-only** | crossfader IS MIDI (ch7/CC63) | **no jog CC** stored; videos use turntables/vinyl; RPM/SMOOTHING/JOGMODE/FORMAT=Serato are timecode params | **Low** (for the reference app) |
| **B. DVS timecode platter + MIDI crossfader** | FORMAT=Serato, RPM33VELOCITY, SMOOTHING, JOGMODE, audio-in channels; vinyl in all videos; fader-as-MIDI but platter absent from MIDI map; standalone | needs an IP-cleared decoder; not yet hardware-confirmed by us | **High** (leading) |
| **C. Serato-app integration** | "Serato" string in config | Serato not open; standalone; no IPC config; FORMAT is a format label | **Very low** |
| **D. Mixed-audio analysis** | — | can mute beat / disable cuts / swap samples / replay (V1.2 — impossible from a mix); fader read as MIDI, not inferred | **Very low** |

→ The reference app is **Model B**.

### 16.5 Does the ScratchLab recommendation change? — the distinction that matters
**Critical:** the reference app's method ≠ the RANE ONE's capability. **RANE ONE is a controller, not
a turntable** — its motorized platter is an *encoder that emits MIDI/HID*; it has no stylus and
produces **no timecode**. So **DVS does not apply to the RANE ONE platter**; for that target,
MIDI/HID remains the *only* platter path.

Two distinct hardware families now exist:
- **Controllers (RANE ONE, REV7, …):** platter = MIDI/HID → the §12 inspector slice.
- **Turntables + control vinyl (videos/reference app):** platter = DVS timecode.
- **Crossfader = MIDI/control in *both* families** — the reference app reads the fader as MIDI CC
  even in its DVS rig.

Consequences:
1. **The RANE ONE MIDI/HID inspector stays the first slice — unchanged.** It is the only way to get
   the RANE ONE platter, and it *also* captures the crossfader, which every configuration needs.
2. **DVS's strategic priority rises** (it is the reference app's actual method and the path to
   real-turntable support), so its POC is **promoted to a parallel track** that can start sooner —
   still **offline** and gated by the IP/licensing decision. It does not replace or block the
   controller slice.
3. **Final architecture = parallel platter transports into one model** (as anticipated): DVS
   transport (turntables) ∥ MIDI/HID transport (controllers), both → `ScratchInputFrame`, crossfader
   always from MIDI. `ScratchInputFrame` already supports this (optional crossfader, transport
   provenance, shared clock) — **no model change**.

### 16.6 Revised roadmap (supersedes §15 ordering only where noted)
- **Phase 1 — RANE ONE MIDI/HID inspector.** Unchanged, still first; now explicitly also the
  universal **crossfader** capture path.
- **Phase 2 — Controller profile + gesture stream.** Unchanged.
- **Parallel track (promoted) — DVS offline POC + IP decision.** Was §15 "Phase 3"; now runs **in
  parallel** with Phases 1–2 (offline, touches no product code): decode recorded Serato-format (or
  open-format) timecode → platter position/velocity/direction; resolve licensing (prefer
  open/self-generated timecode + non-GPL decoder). Output: go/no-go.
- **Phase 4 — Unified transport model.** Unchanged target, higher confidence: fuse DVS + MIDI on the
  shared clock; composite-device profiles (platter ← DVS *or* ← controller, fader ← MIDI).

### 16.7 Definitive experiments to prove the input source (run on your Mac)
Each isolates one variable.

| # | Experiment | Expected if Model B | Proves |
|---|---|---|---|
| 1 | Quit Serato entirely, run reference app | platter + notation still work | no Serato-**app** dependency (standalone) |
| 2 | Feed only control-vinyl audio, no MIDI connected | platter tracks | platter source = **timecode audio**, not MIDI |
| 3 | Disconnect MIDI mixer, keep timecode | platter tracks; **crossfader cuts stop** | platter = timecode, **crossfader = MIDI** |
| 4 | Move crossfader with needle **up** (no timecode) | fader still responds | crossfader is independent **MIDI**, not audio-derived |
| 5 | Set XFADERCH/XFADERCC to wrong values | crossfader dies; restore → fixes | fader reads that **specific CC**; mapping is **data**, ch7/CC63 not hardwired |
| 6 | Inspect audio routing (Audio MIDI Setup vs `AUDIODEVICE`/`LEFTIN`) | input carries phono/line timecode | platter is **audio-input** based |
| 7 | MIDI monitor while spinning platter vs moving fader | platter → **no MIDI**, fader → MIDI | **cleanest single proof**: platter ≠ MIDI, fader = MIDI |
| 8 | **(RANE-ONE-specific)** MIDI monitor, spin the **RANE ONE** platter | platter emits MIDI/HID (or nothing) | answers the §0/§11 unknown for ScratchLab's **actual target device** |

Experiments 2/3/7 together are decisive for the reference app; **experiment 8 is the one that
matters for the RANE ONE build** (and is independent of the reference app's DVS method).

### 16.8 What does NOT change
- The committed Phase 1 stubs stand (model/protocol/stub + tests).
- `ScratchInputFrame` is retained and *validated* — its optional crossfader, transport provenance,
  and shared clock are exactly what a DVS ∥ MIDI fusion needs.
- Standalone ScratchLab still owns audio/replay/notation (V1.2).

---

### Sources
- [Rane DJ One — Frequently Asked Questions (class-compliant on macOS; Serato-oriented)](https://support.rane.com/en/support/solutions/articles/69000814127-rane-dj-one-frequently-asked-questions)
- [How to Troubleshoot Your Class-Compliant MIDI Keyboard or Controller Connection — Rane DJ](https://support.rane.com/en/support/solutions/articles/69000809440-how-to-troubleshoot-your-class-compliant-midi-keyboard-or-controller-connection)
- [Mixxx Hardware Compatibility wiki](https://github.com/mixxxdj/mixxx/wiki/Hardware-Compatibility)
- [Mixxx Advanced Topics — MIDI scripting for jog/platter rotations](https://manual.mixxx.org/2.3/en/chapters/advanced_topics)
- [RANE DJ ONE product page](https://www.rane.com/one/)
- [xwax — Wikipedia (GPL DVS; decoder not for proprietary use without separate license)](https://en.wikipedia.org/wiki/Xwax)
- [Serato DJ Pro — Control Vinyl (proprietary NoiseMap control tone)](https://serato.com/dj/pro/resources/control-vinyl)
- [Digital vinyl system / vinyl emulation — Wikipedia (timecode principles)](https://en.wikipedia.org/wiki/Vinyl_emulation)
- [Final Scratch — Wikipedia (N2IT DVS origins / patent licensing)](https://en.wikipedia.org/wiki/Final_Scratch)
