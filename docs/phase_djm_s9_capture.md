# Phase + DJM-S9 capture route

## Supported route in SL Capture

Use Phase as a DVS source:

`PLX-1000 platter -> Phase Remote -> Phase Receiver RCA -> DJM-S9 line input -> DJM-S9 USB -> SL Capture DVS input`

The DJM-S9 MIDI stream is captured separately for mixer evidence. Its crossfader is a high-resolution CC pair (CC31/63 on MIDI channel 7), and its channel faders use CC19/51 on their deck channels. The shipped profile is verification-required until the connected mixer and firmware have been exercised in the guided MIDI check.

## What is not supported directly

Phase is not exposed as a generic MIDI controller. Phase documents two integrations: HID over USB with supported DJ software, and DVS through the Receiver's RCA outputs. SL Capture does not claim to parse Phase's HID protocol. The `hidThroughSupportedDJSoftware` path is therefore descriptive only; it is not an SL Capture input.

## Operator verification

1. Update Phase firmware and connect the DJM-S9 to the Mac with the current Pioneer driver.
2. Connect the Phase Receiver RCA outputs to the S9 line inputs and place the Phase Remotes on the PLX-1000 platters.
3. Select the DJM-S9 audio device and the correct stereo DVS input pair in SL Capture.
4. Confirm a clean control tone on both channels while each platter is still, then rotate each platter forward and backward.
5. Run the guided S9 MIDI check: move both channel faders and the crossfader through their full ranges.
6. Record a short take and confirm the review contains DVS platter motion, crossfader events, audio, and camera evidence.

The S9 profile is not certified by this code change. Physical signal, channel order, firmware, and Phase pairing still require a real-rig pass.
