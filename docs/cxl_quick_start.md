# CXL capture controls

This guide covers the CXL operator capture flow. The Rane ONE MKII is the test rig; acceptance on the production Rane Seventy-Two plus Rane Twelve remains a separate run.

## Session Setup

CXL automatically prefers a connected physical Rane audio input unless you previously chose a different input yourself. Check **MIDI source** and **Audio input** before enabling capture. If you select Serato Virtual Audio by mistake, choose your Rane in **Audio input** between takes. The enabled camera/audio session reconnects automatically; you do not need to restart the app. Wait for the connection to finish before recording. If activation fails, select the correct input and press **Enable Selected Camera & Audio** again. Device selection alone does not verify the physical recording channel pair.

| Control | What to choose or do |
| --- | --- |
| Capture | Choose **Movement check (no beat)** for one slow movement, or a timed canonical reference for four repetitions. |
| Technique | Choose what you intend to perform, such as Tear. Detection does not choose it for you. |
| Pattern ID / name | Leave the automatically filled values unless you need your own naming. |
| Phrase length | Length of **one repetition**. One bar = four beats. Use more bars if your slow phrase needs more time; repeat it four times. |
| BPM | Speed of the clicks and backing beat. |
| Backing sound | Boom Bap Trainer is a straight drum pattern; Minimal Funk adds swing; Battle Loop is more forceful. Click track is metronome-only. |
| Preview backing sound | Hear the choice before recording. Uses the Mac's selected sound output. Press Stop preview to finish. |
| Starting direction | Your first platter movement: push forward or pull back. |
| Handedness | The hand moving the record and wearing the Watch. |
| Fader variant | For plain Tear, choose **Fader open throughout**. Choose a cut variant only when you actually use it. |
| Active deck / Open end | The platter being scratched and the fader side where that deck is audible. Match your existing calibration. |
| Apply Authoring Setup | Apply the form before Record. For timed references, ScratchLab prepares and verifies the exact backing audio. Movement checks have no backing or count-in. Setup becomes fixed when Record begins. |

Timed reference captures use a saved, verified backing asset set (runtime v2). Record checks those files again before fixing the take's capture intent and starting capture. The take keeps the identity of the audio actually played and a copy of its assets for review and export. If preparation or verification fails, resolve the displayed error before recording.

Reuse the saved crossfader calibration when it already matches the device, MIDI address, deck and open end. Calibration applies to new recordings; it cannot repair unknown fader evidence in an older take. The [Watch crown-wake workaround](cxl_capture_run_sheets.md#watch-setup-before-the-next-pilot-capture) remains provisional; verify actual sample continuity, Stop and transfer for each acceptance take.

Live preflight groups green checks at the top in two columns, with errors and warnings underneath. After a real platter or crossfader message arrives on the current connection, **Ready — idle** stays green when you stop moving. **Moving** describes recent activity only. Reconnecting a controller requires a new observed message; old readings cannot certify the new connection. Green readiness does not certify the contents of a recorded take.

A freshly recorded, calibrated fader that stays parked can now retain its observed state through Stop. This requires the same connection, mapping and calibration throughout; changing them or receiving an unresolved MIDI update leaves coverage unknown. Existing recordings with only a take-start reading are not repaired. Selecting an open position today cannot change an older take.

## Capture

For a simple test, choose **Movement check (no beat)** and apply the setup. Press **Record movement check** directly above the video. Wait for **Recording started**, perform one slow movement, then press **Stop and Finalize**. Use **Play whole take** to review it. This mode saves diagnostic evidence and does not produce a canonical reference.

The camera starts with left-platter, wide-mixer and right-platter boxes filling the image. These are manual framing estimates. Use **Adjust camera boxes**, drag or resize to match the equipment, then **Lock camera boxes**. **Fit full frame** restores the CXL layout. Adjustments are retained separately from the main app and are fixed during capture; the take keeps the guide snapshot in its audit metadata.

The **AHHH PLAYHEAD** waveform below the camera shows the loaded ScratchLab sample and the latest rendered audio-engine position. If unloaded, press **Load AHHH**; loading itself does not audition it. Move the right platter to play. **Platter from cue** separately shows physical movement relative to the sample start, including negative positions. The playback cursor may wrap while this physical position remains continuous. The display refreshes around 25 times a second and does not compensate for speaker or interface latency.

The main meter shows ScratchLab's generated AHHH output in dBFS before and during capture. Silent means real zero-valued audio; Unavailable means no fresh output measurement. Hardware input activity remains a separate preflight check. The saved scratch WAV contains the software fader's result; the physical Rane mixer can change the sound afterward.

AHHH playback uses the selected Rane ONE directly on USB3/4. Listen through the Rane to check timing. **Also hear AHHH on Mac (delayed)** enables an optional second monitor; it is off by default and cannot validate Rane timing. Disconnecting the intended Rane reports unavailable rather than silently moving playback to another device.

Beat and count-in remain on the macOS default output. Their independent Rane bus has not been verified. Use **Movement check (no beat)** for the next diagnostic: record one slow movement, Stop and Finalize on Mac, play the whole take, then save and inspect the export. Timed reference and Seventy-Two/Twelve acceptance remain pending. A valid quiet input and any known fader position allow diagnostic recording; missing Watch is advisory.

Press **Record Draft**. After four count-in clicks, perform the same phrase four times over the selected backing sound, then leave one clean tail bar. Recording stops automatically at the end of that plan. **Stop and Finalize** is still available to end a diagnostic take early.

Wait for finalization and any pending Watch transfer before saving or moving to another take. Saved raw evidence is separate from canonical approval.

An unavailable Watch does not prevent a diagnostic recording; its missing motion is recorded explicitly. **Stop and Finalize** normally stops the Watch too. If the Watch remains recording, press **Stop** on the Watch once. With the updated phone and Watch apps, the phone retains a received Stop request and retries when the Watch becomes reachable. This cannot force the Watch awake or recover a command that never reached the phone. Verify Stop and motion transfer on a fresh take.

## Review & Export

- **Play whole take** plays the actual recorded WAV and available video from the beginning. A missing beat-library binding does not prevent listening to your recording.
- **Play repetition** plays only that repetition's range. **Stop playback** stops playback; it does not stop a new recording.
- **Show notation** highlights the repetition and dims either side. **Zoom to repetition** enlarges its time range; **Whole take** restores the overview. Looking at or playing a repetition does not select it for approval.
- **Start / End beat** adjust that repetition's review range, without changing the original media. Beat 4 is the first beat after a four-click count-in. New captures retain the measured recording offset, so review does not count those clicks twice. Older takes without that origin keep their existing ranges; use Play whole take to hear all of the old recording. A range outside the recorded take shows an explanation.
- **Select for Approval** chooses your best repetition while the take is actively under review. **Approve Canonical Draft** requires the exact beat binding and the other evidence checks to pass. The screen lists any approval blockers separately from recorded-evidence findings; playback alone does not make a take valid.
- **Save Capture…** preserves the raw diagnostic take independently of approval. Keep the archive even when validation reports a problem.
- **Export Approved Package…** saves the selected reference and its supporting evidence after approval, checking the package as it is written. Approval itself does not export, publish or install anything.

The review uses the technique saved with that take. Tear correction controls appear only for Tear; a Chirp take has a Chirp motion review.

## Another take or another scratch

- **Retake this scratch** keeps the technique, tempo and backing choice and returns to Capture. Press Record Draft when ready.
- **New scratch** returns to Setup so you can choose another technique and apply its settings.

Neither action requires approval of the previous take. Both retain its saved media and evidence, and wait while finalization, export or a Watch transfer is pending. A retained previous take is read-only but can still be played or saved.

An older capture without an exact beat binding cannot acquire one afterward. Changing settings or installing this build cannot establish which audio played in that old take. Keep its raw archive and use Retake this scratch to make a new capture with verified backing assets.
