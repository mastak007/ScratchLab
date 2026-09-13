# Current physical boundary — 2026-09-12

Use the installed `~/Applications/ScratchLab CXL.app` only after its new candidate receipt is verified. Source and current receipts are under `/Users/karlwatson/Developer/ScratchLab-CXL-Recovery-20260912/`; all prior temporary paths/PIDs below are historical. The new diagnostic build is installed, SHA256 `19f0fea027a5503c31e93c290497c6ea649264690967806bfbaea4a1ff2b4380`, observed running PID47873. The prior build is retained for rollback.

The current repair gives AHHH a direct Rane ONE USB3/4 output and measures its real internal PCM peak. The optional Mac monitor is delayed and off by default. Input activity, generated scratch audio and the physical master return are different signals; do not infer pair correctness or physical gain parity from the meter. Beat/count-in still use a separate system-default output; their Rane bus is unverified.

Next bounded check after installation: Rane headphones/speakers, Movement check (no beat), one slow scratch, Stop and Finalize on Mac, Play whole take, then Save Capture. Inspect actual exported media and Watch Stop outcome before marking this pilot check complete. Keep previous captures. Seventy-Two plus Twelve cannot be accepted from ONE MKII results; this candidate refuses unvalidated Rane output mappings.

The user now authorizes checkpoint commits/pushes as needed. Use the new recovery checkpoint branch, preserve unrelated WIP and exclude captured media/builds/signing assets. No production-ready claim until the physical gates pass.

--- Historical handoff follows ---

# RANE physical handoff — CXL hardware-feedback candidate

## Latest physical update — Watch crown wake, 2026-09-09

This update supersedes the older first-action instructions below. Camera/audio work; the latest screen shows calibration in force and no take recorded. Karl reports immediate wrist-down loss of Watch availability, restored by wrist-up, then improved stability after enabling Wake On Crown Rotation. Preserve that setting and use the [Watch setup checklist](docs/cxl_capture_run_sheets.md#watch-setup-before-the-next-pilot-capture) before the next pilot take. Full motion continuity, count-in, Stop and Save remain unverified. Do not restart or reinstall the working apps for this observation.

Next bounded action: press Record Draft once and listen for four count-in beats without performing a scratch. Continue physical validation one action at a time, including arm-lowered sample coverage before acceptance. The setup workaround is provisional, not a universal connection lock.

## 2026-09-09 capture-ready candidate supersedes the older P22c binary

- Installed app: `/Users/karlwatson/Applications/ScratchLab CXL.app`
- Source candidate: `/private/tmp/scratchlab-cxl-auto-20260909/cxl-ready-release/products/Release/ScratchLab.app`
- Executable SHA-256: `cd1e106b10366d00e08bd6e674515c22a102190457fed716d60116b093b63e82`
- Running PID: `41283`; `ps` and `lsof` both resolve the executable to the installed path.
- Architectures: `x86_64 arm64`; bundle: `com.machelpnz.scratchlab.cxl-authoring`; strict deep signature verification passed.
- Previous installed app preserved at `/Users/karlwatson/Applications/ScratchLab CXL.previous-20260909-001920.app`.
- Agent-visible launch state: Setup is visible; Rane ONE MKII MIDI/audio and MacBook Pro Camera are selected; camera/audio and companion relay are both off; no permission sheet is visible.
- Software closure: direct-route Watch Stop, real four-beat count-in/start boundary, pending Watch transfer handling, and exact Watch evidence/source binding are repaired. Fresh full gate passed Python 82/82, XCTest 7,960 configured executions with 110 skips and zero failures, Swift Testing 537/537, and iOS/macOS/Watch builds.

First physical action: press **Enable Selected Camera & Audio** once and confirm the local camera preview appears and the Rane audio input is active. Continue one action at a time. Before performing the one slow take, run a count-in-only check: four audible beats must finish before recording starts. The older candidate details below are retained as historical evidence and must not be launched for this test.

Software candidate only. The exact executable launch has agent evidence; no UI, permission, or physical Rane check in this document has been run or accepted.

## Frozen candidate

- App: `/private/tmp/scratchlab-cxl-auto-20260908/products-p22c-cxl-hardware-fix/Release/ScratchLab.app`
- Executable: `/private/tmp/scratchlab-cxl-auto-20260908/products-p22c-cxl-hardware-fix/Release/ScratchLab.app/Contents/MacOS/ScratchLab`
- Executable SHA-256: `7c1d4edaba6646b15dcd6cbd9234685661924f9aa0a77667f0710be943989cc9`
- Architectures: `x86_64 arm64`
- Bundle ID: `com.machelpnz.scratchlab.cxl-authoring`
- Signature: complete local ad-hoc bundle signature; sealed Info.plist/resources/entitlements; `codesign --verify --deep --strict` PASS
- Beat root: `/private/tmp/scratchlab-cxl-auto-20260908/p21-final-gates/CXLBeatPilotCandidates`
- Container boundary: only `~/Library/Containers/com.machelpnz.scratchlab.cxl-authoring`; do not use or copy the normal ScratchLab container.

## Rig boundary

- Immediate diagnostic only: Rane ONE MKII.
- Intended CXL production rig: Rane Seventy-Two plus Rane Twelve, with the Twelve connected through the Seventy-Two to the Mac.
- A Rane ONE result cannot accept the production rig. Every Seventy-Two/Twelve result remains NOT RUN.

## First bounded diagnostic

Stop at the first FAIL or BLOCKED result. Preserve the app, logs, and screenshots. Record Karl's observation separately from software/agent evidence.

1. Unlock the Mac. PID `80042` has already been agent-verified running the exact executable above. Confirm the app shows **Setup**, **Capture**, and **Review & Export**. PASS only if Camera is unselected, **iPhone & Watch Relay** says off, and no camera, microphone, local-network, system-audio, or Continuity-camera prompt/activity appeared merely because the route opened.

2. With the Rane ONE MKII connected, deliberately select its exact MIDI and audio entries plus a local camera physically in the room. Leave companion relay off. Press **Enable Selected Camera & Audio** once. A newly signed local build may receive one camera and one microphone prompt at this explicit boundary. FAIL if a remote iPhone camera starts, if local-network/system-audio permission appears without enabling its separate feature, or if the UI silently changes the selected source.

3. Select Tear. Let AHHH loop while moving the platter, then perform one plain same-direction Tear with an observable stationary hold. PASS only if the coordinate description remains take-local/normalized, the trace does not switch to calibrated revolutions, split or restart at an AHHH rotation, and a qualifying provisional second travel run remains visible. Genuine packet loss may remain explicitly `MOTION UNKNOWN`; do not infer motion or a Tear hold through it. The established 3.2-second rolling window may refit when old events age out, which is separate from an AHHH-boundary reset.

Do not continue to the production sequence below until all three diagnostic checks pass and a separate production-rig setup slice exposes and verifies the Seventy-Two/Twelve signal routing. The current Setup selects an audio device but truthfully does not prove a DVS input pair or master-return pair.

## Deferred production sequence — NOT RUN

Stop at the first FAIL or BLOCKED result. Preserve the app, package, logs, and media. Record Karl's observation separately from the software evidence.

1. If the app must be relaunched, quit every ScratchLab instance and use LaunchServices with the exact beat root:

   ```sh
   open -n -F --env CXL_BEAT_PILOT_ROOT=/private/tmp/scratchlab-cxl-auto-20260908/p21-final-gates/CXLBeatPilotCandidates /private/tmp/scratchlab-cxl-auto-20260908/products-p22c-cxl-hardware-fix/Release/ScratchLab.app
   ```

   In another Terminal window, run `pgrep -fl ScratchLab`. Record the PID, then run `ps -p <PID> -o pid=,command=`. PASS only if the command names the executable above, the app opens directly to Setup / Capture / Review & Export, and the bundle/container identity is the CXL identity above.

2. Connect the Rane Twelve through the Rane Seventy-Two, then connect the Seventy-Two to the Mac. Select the exact Seventy-Two/Twelve MIDI and audio identities shown by the app. Learn the crossfader from the production mixer and record its observed status/channel/controller address; do not reuse the Rane ONE identity or mapping by assumption. FAIL if another source/address moves the crossfader evidence.

3. After the production-rig setup slice supplies the necessary controls/evidence, verify the right-deck DVS input pair and audible master-return pair on the Seventy-Two. The established expected routing is DVS `3/4` and audible master `13/14`, but PASS only if both DVS channels have fresh AC energy, the master is audible on both sides, and the app shows no silent substitution. Do not accept a device selection, aggregate level, or an old file as proof.

4. Calibrate the normal right-deck crossfader: hold far-left closed; move just beyond the learned cut-in and confirm open; confirm centre and far-right remain open. Record raw position, normalized position, audible gain, learned curve, source/address, and confidence. Run mirrored/reverse checks only if that configuration is part of this pilot.

5. Use `boom_bap_straight_80` for three separate takes. Confirm its manifest SHA-256 is `084f43d2cd5de9bf904c9fc1e9e1bb36a40fc536f77dc0624075181fdd1093fe` before recording:

   - Baby: four plain forward/backward Baby repetitions.
   - Tear: one plain Tear containing an observable same-direction stationary hold between two travel runs.
   - Fader cut: independent platter motion plus an explicit closed/open crossfader cut.

   Do not combine the Tear and fader-cut proof into one inferred event.

6. For every take, review the actual finalized WAV and MOV, the exact bound production master and sparse-analysis hashes, witnessed timing, raw/calibrated fader, platter intervals, notation, Watch/source terminal state, and validation findings. Unknown evidence must remain unknown. A missing WAV, missing required Watch evidence, timing drift, identity mismatch, or low-confidence committed evidence blocks approval.

7. Select one repetition and approve exactly one passing take. Reject one different take. Choose **Next take** and verify the next take retains the same immutable CaptureIntent and BeatSpec. PASS only if the approved, rejected, and next takes remain distinct and their histories are preserved.

8. Export the approved package. Copy it to a second new local directory, then use **Reopen & Verify Last Export** on the copied package. PASS only if every listed artifact rehashes, no extra file is accepted, immutable identity/review history is restored, and no install, publish, upload, or training action occurs.

## Evidence board

Post-repair software gate: Python 82/82 passed; desktop 4,515 unique tests and 9,302 runs across two configurations completed with zero failures; iOS, macOS, and separately isolated Watch builds passed. The 702-path source manifest remained unchanged. This strengthens only the software column below and does not change any physical status.

| Check | Software/agent evidence | Karl/operator observation | Physical status |
| --- | --- | --- | --- |
| Exact PID and executable | PID 80042 matches the frozen executable | — | NOT RUN |
| Setup visible; no launch-time prompt | Source/tests and Release build verified; screen locked before inspection | — | NOT RUN |
| Camera/audio explicit enable only | Source/tests verified | — | NOT RUN |
| Companion relay remains off | Source/tests verified | — | NOT RUN |
| AHHH loop keeps one CXL coordinate basis | Source/tests verified | — | NOT RUN |
| Plain Tear keeps qualifying second travel | Source/tests verified | — | NOT RUN |
| Rane ONE MIDI source `midi_498545357` | Expected diagnostic identity only | — | NOT RUN |
| Rane ONE crossfader `BF` / channel 15 / CC8 | Synthetic diagnostic tests only | — | NOT RUN |
| Seventy-Two/Twelve exact MIDI/audio identities | No physical input | — | NOT RUN |
| Seventy-Two crossfader learned address | No physical input | — | NOT RUN |
| Right DVS 3/4 fresh AC energy | No physical input | — | NOT RUN |
| Audible master 13/14 both sides | No physical output | — | NOT RUN |
| Normal right-deck calibration | Synthetic boundary tests only | — | NOT RUN |
| Baby take | Software pipeline verified | — | NOT RUN |
| Tear same-direction hold | Software segmentation verified | — | NOT RUN |
| Independent fader-cut take | Software fader provenance verified | — | NOT RUN |
| Finalized WAV/MOV review | Synthetic media verified | — | NOT RUN |
| Watch/source terminal evidence | Synthetic relay states verified | — | NOT RUN |
| Approve / reject / Next take | Domain tests verified | — | NOT RUN |
| Export / second-root reopen | Synthetic package round-trip verified | — | NOT RUN |
| Rane Seventy-Two plus Twelve production rig | No physical input | — | NOT RUN |

Do not publish, install into training, upload, or train from this pilot. A software PASS does not establish physical acceptance.
