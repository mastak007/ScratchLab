# CXL capture run sheets

Status date: 9 September 2026. These worksheets schedule work; they do not establish mechanics, readiness, approval, rights or capture evidence.

## Watch setup before the next pilot capture

Karl reports improved Watch availability after enabling **Settings → Display & Brightness → Wake On Crown Rotation**. For the current pilot, leave that setting enabled, open ScratchLab on the Watch, and turn the crown to wake its display before starting a take. Confirm the CXL Watch preflight is available. Apple documents this as a display-wake setting in its [Watch guide](https://support.apple.com/en-nz/guide/watch/apd748b87e2a/watchos).

This is an operator-reported workaround, pending a completed take; it is not a verified requirement for every Watch or a guarantee of background recording. Wake Duration was already 70 Seconds when wrist-down availability failed. Before accepting Watch capture, verify measured motion coverage with the arm lowered, Mac Stop reaching the Watch, completed transfer, and the saved artifact. Record any interruption explicitly; a green connection indicator alone is insufficient.

## Four-day Capture Ready boundary

The four-day build does not execute the full queue below. Its physical acceptance run uses only a minimal representative set: Baby Scratch, one plain Tear with an observable hold, and one independent fader-cut technique, across at least one slow and one demonstration configuration. These takes validate the operator pipeline and six-beat pilot; they do not fill or reduce the later 160 acceptance slots.

Mandatory Capture Ready proof for each pilot take is exact technique/variant/recipe and beat binding; actual BPM/count-in/media origin/duration; finalized audio/video review; platter/fader/Watch/source status; approval or rejection; Next-take behavior; raw hashes; approved-package verification/reopen; recovery result; operator identity/time/notes; and an explicit PASS, FAIL, BLOCKED or NOT RUN. Missing evidence blocks readiness.

## Minimum production accounting

Rows 07, 08, 09, 13, 15 and 17 split into forward/backward variants. Row 10 splits into explicit 1-, 2- and 3-Tear open-fader cycles. The retained 32 rows therefore produce at least **40 variants**. Each variant targets two independently accepted slow takes and two demonstration takes: **160 accepted takes**. Four repetitions per take yields **640 repetitions only where the confirmed recipe and supported duration permit it**. Retakes, negatives, alternate hands/decks/fader orientations and teaching footage are additional.

## Ordered queue

| Row | Required item | Minimum variants |
| ---: | --- | ---: |
| 01 | Baby Scratch | 1 |
| 02 | Forward Scratch | 1 |
| 03 | Backward Scratch | 1 |
| 04 | Release Scratch | 1 |
| 05 | Stab | 1 |
| 06 | Scribble | 1 |
| 07 | 1-Tear: forward then backward, distinct variants | 2 |
| 08 | 2-Tear: forward then backward, distinct variants | 2 |
| 09 | 3-Tear: forward then backward, distinct variants | 2 |
| 10 | Plain Tear forward/backward cycles: 1-, then 2-, then 3-Tear; explicit fader-open variants | 3 |
| 11 | Chirp | 1 |
| 12 | Transformer using the existing `transform` ID; CXL confirms cut/rhythm | 1 |
| 13 | 1-click Flare: forward then backward, distinct variants | 2 |
| 14 | 1-click Flare Orbit | 1 |
| 15 | 2-click Flare: forward then backward, distinct variants | 2 |
| 16 | 2-click Flare Orbit | 1 |
| 17 | 3-click Flare: forward then backward, distinct variants | 2 |
| 18 | 3-click Flare Orbit | 1 |
| 19 | Twiddle; CXL confirms finger technique/cut pattern | 1 |
| 20 | Crab; CXL confirms finger technique/cut pattern | 1 |
| 21 | Chirp + 1-click Flare Orbit | 1 |
| 22 | Chirp + 2-click Flare Orbit | 1 |
| 23 | Boomerang | 1 |
| 24 | Military | 1 |
| 25 | Autobahn | 1 |
| 26 | Prizm; preserve persisted spelling and verify aliases | 1 |
| 27 | Hydroplane | 1 |
| 28 | Foundation Flow / `combo_l1`: Baby → Forward → Backward → Release | 1 |
| 29 | Control Combo / proposed version of `combo_l2`: Baby → Forward 1-Tear → Chirp → Scribble | 1 |
| 30 | Fader Fury / proposed version of `combo_l3`: Transformer → 1-click Flare Orbit → 2-click Flare Orbit → Crab | 1 |
| 31 | Advanced Arsenal / proposed version of `combo_l4`: Twiddle → Boomerang → 3-click Flare Orbit → Hydroplane | 1 |
| 32 | Master Showcase / proposed version of `combo_l5`: Military → Autobahn → Prizm → Chirp + 2-click Flare Orbit | 1 |

The proposed `combo_l2`–`combo_l5` component sequences differ from current historical arrays. Preserve old IDs, arrays and takes; create immutable new recipe versions only after CXL signs off exact mechanics.

## CXL Beat Library matrix

Every usable beat is an original or explicitly licensed, immutable `BeatSpec`. Its record includes beat ID and version; family; exact BPM; time signature; straight/swing/half-time feel; count-in bars; loop length and sample rate; production-master, analysis-safe mix and stem hashes; loudness/peak measurements; creator and rights evidence; and approval state. A take binds that exact record before recording. A changed arrangement, mix, tempo render or master creates a new version.

The three-day pilot is capped at six `BeatSpec` variants: boom-bap straight/80 BPM, boom-bap swing/90 BPM, funk-break straight/90 BPM, funk light-swing/100 BPM, electro straight/110 BPM and half-time/80 BPM. Each receives a production master, sample-aligned sparse analysis mix and original stems. Seventy, 120 and 130 BPM renders and further family/feel combinations are deferred until after the pilot is accepted.

| Beat family | Feel variations | Required deliverables |
| --- | --- | --- |
| Classic boom-bap break | Straight/80 and swing/90 | Two production masters, two sparse analysis mixes, drums and bass stems |
| Funk break | Straight/90 and light-swing/100 | Two production masters, two sparse analysis mixes, drums and bass stems |
| Electro | Straight/110 | One production master, one sparse analysis mix, drums, bass and music stems |
| Half-time groove | Straight/80 | One production master, one sparse analysis mix and stems |

Masters use clean sample-accurate loops, a strong unambiguous downbeat, consistent count-in, controlled low end and transient headroom. Production treatment may add original fills, bass, musical accents and restrained vinyl character, but must not mask scratch attacks, fader cuts or platter timing. No uncleared break, melody, vocal, scratch phrase or third-party sample enters the library.

Beat coverage is an assigned matrix rather than an uncontrolled cross-product. During the three-day pilot, the six accepted beats are assigned only to Baby Scratch, one plain Tear and one fader-cut technique for timing and audibility validation. Each of those techniques must use at least one production master and its matched analysis-safe mix; all six beats receive loop, hash, rights and listening QA even if the four-day physical pilot does not record every technique against every beat. Applying beats across all 40 technique variants belongs to later production.

## Per-variant record

Before capture, record the stable parent/variant/recipe/version; CXL-approved mechanics and notation; performer/operator, hand/deck/fader orientation; rig/device/address/calibration; exact `BeatSpec` identity/version, production and analysis-safe hashes, family, feel and rights; BPM and beats/cycle; slow/demo category; count-in/media origin; supported duration/repetitions; required audio/video/platter/fader/Watch streams; explicit blockers; and purpose.

Acceptance slots `S1`, `S2`, `D1`, `D2` each require a distinct take ID, actual duration/repetition count, validation and selected-repetition result, attributed approval/notes, raw/source hashes, terminal Watch/source state, verified approved-package/reopen receipt and independent backup/read-back. Empty fields remain pending.

Capture order is Session Setup → verify rig/timing → read exact Capture brief → explicit Record/Stop → wait for finalization/Watch → actual Review → approve or reject → explicit Next take → verified package/reopen/backup. Missing evidence is never converted to a pass.

Teaching/content status is tracked independently per variant: script approved → clean reference captured → technically verified → CXL approved → separate explanation captured → edited with original notation/captions → rights cleared → lesson tested in Release → distributed. The canonical reference has no narration; CXL's separate explanation is preferred. No voice generation, purchase, upload or third-party asset use is authorized by this run sheet.
