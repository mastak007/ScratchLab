# Phase B + DJM-S9 capture

This candidate implements the RCA DVS route for the right deck B. Release builds include the input recorder and decoder; no diagnostic flag is needed. Physical acceptance of the candidate is still pending. Direct Phase HID/WIR is not implemented: the shared HID probe was refused while Serato owned the receiver.

## Wiring and playback

Keep the verified setup: Phase receiver B RCA to the S9 channel 2 LINE input, S9 USB to the Mac, and Serato right deck in REL with AHHH loaded. Serato supplies scratch playback. SL Capture does not render Phase audio itself.

For this explicitly selected route, S9 USB input 3/4 carries stereo control tone and input 5/6 carries programme audio. Two saved local recordings established that split for this rig. These are input channels, not output destinations. Other S9 routing configurations and the left Phase remote A are not claimed by this route. The recorder requires the observed eight-channel, 48 kHz, interleaved Float32 format and does not change mixer or system audio settings.

## SL Capture setup

1. Choose Phase DVS + DJM-S9 under Capture pathway and choose the camera.
2. Enable Selected Camera & Audio, then Connect Phase Input. Grant audio permission if requested.
3. Press Check Forward, move the right platter steadily forward, then Confirm Forward while it is moving. A full revolution is unnecessary. This records polarity for this connection only; it does not calibrate revolutions or touch.
4. Use the existing S9 guided MIDI check and fader learning for measured control positions. The S9 profile remains verification-required. Programme audio already includes the mixer/Serato cuts. Physical S9 gain is not represented as ScratchLab software gain; unverified gain intervals remain unknown.
5. Record, stop, review, save and export. Keep other decks/effects out of the scratch return. Do not treat a build or routing meter as final physical acceptance.

## Evidence and limits

Programme 5/6 and raw control 3/4 are recorded independently from the same input callbacks. The control WAV, original callback timestamps/sample counts, decoder rejections, device/connection identity, polarity check and camera-clock binding travel with the take. Draft reopening and export verify the control WAV hash, format and frame count. Session and reference packages retain the control WAV as a separate evidence artifact; it is never used as the audible scratch stem.

Notation integrates only accepted control-tone travel, with take-local normalisation and dense callback samples. It does not claim calibrated revolutions. The existing decoder and stability confidence/rate rules are unchanged. Missing/rejected control tone is unknown, never a stationary hold or a line across lost motion. No platter truth is inferred from silence or camera motion. Exact sample-time gaps, clock regressions, ring loss, malformed data, or incomplete movie/audio coverage fail closed and retain source files.

## Candidate acceptance pending

One combined operator check on the installed candidate remains: forward/backward direction, audible AHHH in the saved movie, both physical fader cuts present in recorded audio, and a saved/reopened/exported take with matching notation and retained control evidence. The earlier routing recordings are retained; no repeat routing investigation is required.
