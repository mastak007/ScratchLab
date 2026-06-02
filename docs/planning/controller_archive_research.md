# Controller Archive Research — Architecture Lessons for ScratchLab Input

**Research only.** No code, no ScratchLab changes, no Swift, no MIDI mappings, no RANE ONE
assumptions. Source: `controllers.zip` (a Mixxx-style controller-mapping collection). All numbers
below are from direct inspection of the extracted archive.

---

## 1. Executive summary

The archive is the Mixxx controller-mapping corpus: **159 mapping XML files (142 MIDI, 16 HID, 1
bulk), ~149 JavaScript scripts (+10 TS), across ~40 brands.** It is a decade-plus of community
work covering how mature DJ software ingests a huge variety of controllers without controller-
specific code leaking everywhere.

The single most important finding: **everything device-specific is pushed into a data-and-script
profile, and the application exposes stable "engine controls" (semantic targets).** Scratching in
particular is universal: `engine.scratchEnable(deck, intervalsPerRev, rpm, alpha, beta)` +
`scratchTick()` + `scratchDisable()` (used by 97 of ~149 scripts). Its parameters —
**ticks-per-revolution, RPM, and an alpha-beta smoothing filter** — are exactly the trio the
reference Scratch-visualizer app stores (`RPM33VELOCITY`, `SMOOTHING`) and exactly what ScratchLab's
planned `DeviceProfile` anticipates. Three independent sources converge on the same model.

**Bottom line for ScratchLab:** the archive *validates* the current direction
(`ScratchInputFrame` / `RawInputEvent` / `MIDITransport` / `ControllerInputNormalizer` /
`DeviceProfile` / `SemanticControl`) and the current phase order. The main lessons are (a) nothing
about a controller may be hard-coded — resolution, message types, RPM, smoothing, fader CC, and
encoding mode all vary per device; and (b) the transport/profile seam must be **HID-ready from the
start**, because high-resolution and motorized platters are frequently HID, not MIDI.

---

## 2. Controller ecosystem findings (Part 1 — Inventory)

- **Controllers represented:** ~140–159 (159 mapping XMLs; a few devices split into CH1/CH2 or
  L/R or "Advanced" variants).
- **Mapping formats:** Mixxx XML — `*.midi.xml` (142), `*.hid.xml` (16), `*.bulk.xml` (1).
- **Script languages:** JavaScript (~149 `.js`) with a small modern TypeScript set (10 `.ts`).
- **Common directory structure:** flat — each controller is `Brand Model.midi.xml` (or
  `.hid.xml`) plus an optional `Brand-Model-scripts.js`. XML = declarative bindings + device
  identity; JS = behavioural logic (jog/scratch, LEDs, shift layers).

| Brand | Controller Count (approx) | Mapping Type |
|---|---|---|
| Hercules | 25 | MIDI XML (+JS), some HID |
| Numark | 18 | MIDI XML (+JS) |
| Pioneer | 12 | MIDI XML (+JS), CDJ via HID |
| Vestax | 9 | MIDI XML (+JS) |
| Native Instruments (Traktor) | 9 | **HID XML** (S2/S3/S4, F1, Z1) |
| DJ-Tech / DJ TechTools | 8 | MIDI XML (+JS) |
| Behringer | 8 | MIDI XML (+JS) |
| Reloop | 7 | MIDI XML (+JS) |
| Stanton | 6 | MIDI XML (+JS) |
| Denon | 6 | MIDI XML (+JS) |
| Novation | 5 | MIDI XML (+JS) |
| Korg | 4 | MIDI XML (+JS) |
| American Audio | 4 | MIDI XML (+JS) |
| Gemini / Mixman | 3 each | MIDI XML (+JS) |
| Akai, Ion, Icon, MixVibes, MVave, MidiTech | 2 each | MIDI XML (+JS) |
| Long tail (Arturia, Roland, Sony, Nintendo, EKS, Electrix, FaderFox, Yaeltex, Evolution, …) | 1 each | MIDI or HID XML |

Device identity is declared in the XML header: `<info>` (`<name>`, `<author>`, `<description>`) and
`<controller>` → `<product …>`. MIDI devices match by port/name; HID devices match by
`vendor_id` / `product_id` / `usage_page` / `usage` / `interface_number` (e.g. the Pioneer CDJ HID:
`vendor_id="0x8e4"`, multiple `product_id`s).

---

## 3. Jog / platter findings (Part 2)

Aggregate counts across the archive:
- **Script-driven behaviour dominates:** 46 XMLs carry `Script-Binding` (2823 bindings). Jog/scratch
  is almost always handled in JS, not by a direct XML binding.
- **`engine.scratch*` is the universal scratch API:** 98 files call it; 97 use both `scratchTick`
  and `scratchDisable`. Real signatures observed:
  - `engine.scratchEnable(1, 128, 33+1/3, alpha, beta)` (typical)
  - `engine.scratchEnable("[Channel1]", 128*3, 45, 1.0/8, (1.0/8)/32)`
  - `engine.scratchEnable(1, 37056, NumarkV7.RPM, 1.0, 0.27, false)` (high-res platter)
  → arguments are **(deck, intervalsPerRevolution, rpm, alpha, beta)**: resolution, speed
  calibration, and a smoothing/inertia filter.
- **Touch-gated state machine:** a jog *touch* (a note button) calls `scratchEnable` on press and
  `scratchDisable` on release; the jog *turn* (a relative CC, or HID delta) feeds `scratchTick`
  while touched and does pitch-bend/seek while not touched.
- **Relative jog encodings (minority, varied):** `selectknob` (15 files), `<diff>` (5), `rot64`/
  `rot64fast` (~2). Several scripts hand-decode 2's-complement / offset-binary deltas. There is **no
  single relative encoding** — it is per device.
- **Absolute / high-resolution encodings:** `fourteen-bit-msb`/`-lsb` in 16 files (86/84 hits) —
  used for high-res faders and some absolute controls; HID (16 mappings) carries the genuinely
  high-resolution and motorized/touch platters (Traktor S-series, Pioneer CDJ).
- **Touch-sensitive platters:** handled as a separate note/HID-button event that toggles scratch
  mode — never inferred from the turn data.

### Most common jog approaches
1. **Script + `engine.scratchEnable/Tick/Disable`** driven by a relative turn signal, gated by a
   touch button. This is the de-facto standard.
2. Relative CC turn (small signed deltas) for pitch-bend/seek when not scratching.

### Least common jog approaches
- Direct XML-only jog bindings with no script (too inflexible for scratch).
- `rot64` family (largely legacy); raw 14-bit *absolute* jog is rare outside HID.

### Patterns worth copying
- **Resolution, RPM, and smoothing are explicit parameters, not constants** — the scratch engine is
  told ticks/rev + rpm + alpha/beta. ScratchLab's `DeviceProfile` should carry the same trio.
- **Touch is a first-class, separate input** that gates a scratch state machine.
- **One application-side scratch primitive**, fed by device-specific decode in the profile/script.

### Patterns worth avoiding
- Hard-coding ticks/rev or RPM in device logic (observed values span 100 → 37056 ticks/rev).
- Assuming the jog is one MIDI message — it is usually *touch (note) + turn (CC/HID)*.
- Inferring touch from movement instead of reading the dedicated touch signal.

---

## 4. Crossfader findings (Part 3)

- **157 files reference the crossfader.** Canonical binding: `<group>[Master]</group>`,
  `<key>crossfader</key>`, `<status>0xB0</status>` (a CC), `<midino>` = the CC number. Channel and
  CC number vary per device; **there is no universal crossfader CC** (e.g. Akai MPD24 = CC 17).
- **7-bit is the default; 14-bit is a minority.** Most crossfaders are a single 7-bit CC; a few
  controllers (e.g. Pioneer DDJ-400 / FLX4 / SB2 / SB3) use `fourteen-bit-msb`/`-lsb` for higher
  resolution.
- **Inversion is a mapping option** (`<invert>` appears in 22 files), not baked into device code.
- **Curve is application-side.** Mappings deliver a *raw normalized position*; the crossfader curve
  is Mixxx's own engine setting, not part of the mapping. (Mirrors the reference app's `XFCURVE`
  living in app settings.)
- **Threshold / open-closed** is not a mapping concept here — it is downstream interpretation. (For
  ScratchLab, open/closed threshold belongs in the profile/analysis layer, consistent with the
  reference app's separate `XOPEN`/`XCLOSE` graphics settings.)
- **Soft-takeover** (`soft-takeover`, 14 files, 147 hits) is applied to absolute controls to prevent
  value jumps when the physical and logical positions disagree.

### Common crossfader abstraction patterns
A crossfader is modelled as: *a normalized 0…1 absolute position from a CC (7- or 14-bit), with
optional invert, with curve/threshold handled by the application, and soft-takeover where needed.*

### Recommended ScratchLab abstraction
A crossfader configuration that stores, as data: **MIDI channel + CC number**, **bit depth
(7/14)**, **invert flag**, **curve descriptor**, and **open/closed threshold** — while the
normalizer emits a raw normalized position and the application applies curve/threshold. This matches
both the archive and the reference app's `XFADERCH`/`XFADERCC`/`INVERTXFADER`/`XFCURVE`.

---

## 5. DeviceProfile recommendations (Parts 4 & 5)

### How mature DJ software avoids controller-specific code everywhere
Mixxx separates concerns into four layers; the archive is the proof:

```
Raw MIDI / HID                ← bytes from the transport (status, data, or HID report)
      ↓  (transport delivers (channel, control, value, status, group) or HID buffer)
Mapping (XML bindings + JS)   ← device-specific: which byte means what, how to decode jog/touch
      ↓  (translates into…)
Semantic Control (engine)     ← stable app targets: [ChannelN] scratch/jog, [Master] crossfader,
      ↓                          scratchEnable/Tick/Disable, play, etc.
Application Logic             ← deck/scratch/mix engine; knows nothing about any specific device
```

The application never references a specific controller; controllers reference the application's
semantic controls. New device = new profile (XML + optional script) authored against the same
engine. Capability is declared by *what the profile binds* and by the `<product>`/transport
metadata.

### Proposed future ScratchLab DeviceProfile model (description only — no code)

**Required fields**
- **Profile identity** — id, display name, author/version. *Why:* provenance + `profileID` on
  frames; lets mappings evolve without breaking recordings.
- **Device matching** — for MIDI: port/name match; for HID: `vendor_id`/`product_id`/`usage_page`/
  `usage`/`interface_number`. *Why:* the archive matches devices exactly this way; needed to bind
  the right profile automatically.
- **Transport** — MIDI / HID (extensible to DVS). *Why:* high-res/motorized platters are often HID;
  the profile must declare which transport carries which controls.
- **Control map** — raw event (status+CC/note, or HID offset/bitfield) → semantic control. *Why:*
  this is the only place device specifics live.

**Optional fields**
- **Script/behaviour hook** — for state machines (touch-gated scratch, shift layers). *Why:* 46
  archive mappings need logic beyond static bindings.
- **Shift/layer descriptor** — modifier handling. *Why:* common across the corpus.

**Capability flags**
- hasMotorizedPlatter, platterIsTouchSensitive, platterIsHighRes, crossfaderIs14Bit,
  supportsAbsolutePlatter, supportsRelativePlatter. *Why:* lets the normalizer and (future)
  inspector adapt without per-device branches; mirrors how the archive's devices differ.

**Deck configuration**
- Deck count and per-deck control grouping (the archive's `[Channel1]`/`[Channel2]`; some devices
  split CH1/CH2 files). *Why:* maps onto `ScratchDeckID`; supports 2- and 4-deck devices.

**Platter configuration**
- **ticksPerRevolution**, **nominalRPM** (33⅓ / 45), **encoding** (relative ticks vs absolute
  angle), **bit depth**, **smoothing (alpha/beta)**, **touch source**. *Why:* exactly the
  `scratchEnable(deck, intervalsPerRev, rpm, alpha, beta)` parameter set — proven necessary and
  device-specific; also matches the reference app's `RPM33VELOCITY`/`SMOOTHING`/`JOGMODE`.

**Crossfader configuration**
- channel, CC, bit depth (7/14), invert, curve, open/closed threshold, soft-takeover. *Why:* §4;
  matches `XFADERCH`/`XFADERCC`/`INVERTXFADER`/`XFCURVE`.

**Mapping persistence**
- Profiles stored as editable data (the archive is literally a folder of editable XML+JS). *Why:*
  user-editable/extensible mappings, MIDI-Learn output, and recordings that can be re-derived.

---

## 6. ScratchInputFrame assessment (Part 6)

| Concept | Verdict | Why |
|---|---|---|
| `ScratchInputFrame` (normalized per-deck state) | **Supported** (with note) | Mixxx normalizes every input to engine-control state; the *normalized semantic state* concept is exactly the boundary it draws. The discrete-frame *packaging* is ScratchLab's own (reasonable for recording/replay); Mixxx keeps continuous control objects rather than sampled frames, so the framing is a design choice the archive neither requires nor contradicts. |
| `RawInputEvent` | **Supported** | Mixxx receives raw MIDI/HID and exposes `(channel, control, value, status, group)` / HID buffers; retaining raw events is standard. |
| `MIDITransport` | **Supported** | Mixxx runs MIDI and HID as parallel transports feeding one mapping engine — validates a transport abstraction. |
| `ControllerInputNormalizer` | **Supported** | The mapping+script layer *is* the normalizer: raw → semantic. ScratchLab naming the seam explicitly is consistent. |
| `DeviceProfile` | **Supported** | The XML `<info>`/`<controller>`/`<product>` + script bundle *is* a device profile (identity + matching + capability + constants + mapping). |
| `SemanticControl` | **Supported** | Mixxx "engine controls" (`scratch2`, `[ChannelN],jog`, `[Master],crossfader`, `scratchEnable`) are precisely semantic controls. |

**Conclusion:** the archive supports the full ScratchLab concept set. The only nuance is that
ScratchLab adds an explicit *sampled-frame* representation on top of the semantic-state model, which
is a sound choice for ScratchLab's recording/replay goals (V1.2) and is not contradicted by the
corpus.

---

## 7. RANE ONE risks (Part 7)

What must **not** be hard-coded for the RANE ONE (each is a real variation seen in the archive):

**Assumptions to avoid**
- That the RANE ONE behaves like any other device — author its profile from *observed* events, the
  way every mapping in the archive was made.

**Controller-specific traps**
- Hard-coding ticks/revolution (archive spans 100 → 37056). RANE ONE's value is unknown → profile
  constant, discovered via the inspector.
- Hard-coding RPM (33⅓ vs 45) or smoothing (alpha/beta) — per-device, per-mode.
- Assuming a single shift/layer scheme.

**MIDI assumptions**
- That the platter even appears on MIDI. Motorized/high-res platters in the archive (Traktor
  S-series, Pioneer CDJ) are **HID**, not MIDI — the RANE ONE may be the same. The profile/transport
  seam must be HID-ready.
- That jog is one message — it is typically *touch (note) + turn (CC/HID)* with a state machine.
- That the relative encoding is a known type — could be 2's-complement, offset-binary, rot64, etc.

**Platter assumptions**
- That the platter is relative *or* absolute — confirm which; support both in the profile.
- That touch can be inferred from motion — read the dedicated touch signal.
- That a motor-on baseline is zero velocity — motorized platters idle at nominal speed (ties to
  `ScratchInputFrame.platterBaseline`).

**Crossfader assumptions**
- That it is on any particular channel/CC — varies per device; `ch7/CC63` from the reference app is
  one user's saved config, not a RANE ONE fact.
- That it is 7-bit — could be 14-bit (MSB/LSB).
- That it is non-inverted, or that curve/threshold are part of the raw value — invert is a flag;
  curve/threshold are application-side.

---

## 8. Recommended roadmap (Part 8)

**Keep the current order — the archive strongly validates it.**

- **Phase 1 — MIDI inspector + raw event capture + `ScratchInputFrame`.** *Correct first.* Every
  mapping in this corpus was authored by first *watching the controller emit raw events*. You cannot
  profile what you cannot observe. The raw monitor is the prerequisite tool, and `ScratchInputFrame`
  is the normalized target the rest hangs off. (Also: the crossfader is MIDI in essentially every
  device here, so the MIDI path is universally useful regardless of platter transport.)
- **Phase 2 — `DeviceProfile` + normalizer.** *Correct second.* This is where all device specificity
  lives (the XML+JS layer of the archive). **Refinement from the evidence:** design the
  profile/transport seam to be **HID-ready from the start** (don't bake in MIDI-only), because
  high-res/motorized platters are frequently HID. The profile must carry the proven platter trio
  (ticks/rev, RPM, smoothing) and the crossfader config (channel/CC/bit-depth/invert/curve/
  threshold).
- **Phase 3 — RANE ONE mapping.** *Correct last.* A device mapping is *data authored on top* of the
  inspector + profile + semantic controls — exactly as the 159 mappings here were authored against
  the Mixxx engine. Authoring it before the engine exists would invert the dependency.

**No reordering recommended.** The only additions are caveats, not sequence changes: (1) make the
transport/profile seam HID-capable in Phase 2's design even if the first transport implemented is
MIDI; (2) author the RANE ONE profile strictly from inspector observations, never from assumptions.

---

### Appendix — evidence counts (from direct archive inspection)
- 159 mapping XML (142 `.midi.xml`, 16 `.hid.xml`, 1 `.bulk.xml`); ~149 JS; 10 TS; ~40 brands.
- `Script-Binding`: 46 files / 2823 hits. `engine.*`: 143 files. `engine.scratch*`: 98 files.
  `scratchTick` + `scratchDisable`: 97 files each.
- Jog encodings: `selectknob` 15, `<diff>` 5, `rot64`/`rot64fast` ~2; `fourteen-bit` 16 files.
- `soft-takeover`: 14 files / 147 hits.
- Crossfader referenced in 157 files; canonical `[Master],crossfader` on a CC (`0xB0`); `<invert>`
  in 22 files; 14-bit on a minority (e.g. Pioneer DDJ-400/FLX4/SB2/SB3).
- HID device matching via `vendor_id`/`product_id`/`usage_page`/`usage`/`interface_number`.
