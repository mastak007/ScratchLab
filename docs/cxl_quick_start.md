# ScratchLab CXL — capture pilot

This app is for recording scratch references. You can record and save now, and leave detailed review and canonical approval until later. The reference-example library is a starter set; completing or watching it is not required to capture new material.

## Set up once

1. Connect the controller and camera. Open **ScratchLab CXL** and select the actual MIDI source, camera and audio input in **Setup**.
2. Press **Enable Selected Camera & Audio** and allow the requested camera/microphone access. Check that the camera preview moves. A single front camera at about 45 degrees is fine; frame both hands, the platter and fader clearly.
3. Press **Load AHHH** if the sample is not loaded. Choose the intended **AHHH output**. For Mac speakers, select **Mac (system output)** and choose the Mac speakers in macOS Sound settings.
4. Watch motion is optional. Leave **Enable iPhone & Watch Relay** off when recording without a Watch. If you choose to use it, check the Mac's connection and each take's actual motion status; the Watch's paired status alone is not proof of captured motion.
5. Choose the technique, BPM, phrase length, starting direction, handedness and fader variant, then **Apply Authoring Setup**. Learn/calibrate the crossfader if needed; choose the correct active deck and open end. Check the live calibrated fader state before recording.

## Hearing scratch and beat through the Rane

The **AHHH output** choice also controls the backing preview, count-in and reference beat. On the Rane ONE/MKII, choose **Rane**: AHHH uses the right deck (USB 3/4), and the beat uses the left deck (USB 1/2). Select the USB source and cue both decks in the Rane headphones. Headphone cue lets you hear the backing while the crossfader is at the scratch deck's open end; the physical faders and headphone mix still control what you hear on the mixer.

Try **Preview backing sound** before recording. A missing or mismatched selected output blocks playback instead of silently sending it to Mac speakers. **Mac (system output)** sends both AHHH and backing through the selected macOS sound output. Stop preview before changing the output; output selection is locked during capture.

The Rane monitor mix is separate from the stored audio. The app retains the dry generated scratch and exact backing audio/timing so a timed reference can export **scratch only**, **beat only** and **scratch with beat**. The physical mixer/master sound is not claimed to be that exported mix. A no-beat movement check has no backing stem.

Confirm both sounds in the actual headphones before a teaching take. Rane ONE channel mapping does not establish the Seventy-Two/Twelve route.

## Optional second camera

After enabling the main camera, choose **Second camera (optional)** in Setup. For a body-and-decks view, mount the iPhone upright in portrait and select its Continuity Camera. Both devices must use the same Apple Account; a USB connection can improve connection stability. Keep the landscape main camera aimed at the hands, platter and fader. Check both previews before recording.

Record and Stop on the Mac control both views. The second movie retains its measured timing and orientation, plays beside the main view with the take's audio, and is included in saved drafts and exports. Missing frames or an unavailable second camera are reported; they do not block the main recording. Physical alignment still needs a short two-camera recording check.

Do not rely on that same iPhone for uninterrupted Watch relay while it serves as a Continuity Camera. Apple requires it to stay locked; unlocking pauses the camera, and ScratchLab's relay can suspend in the background. USB does not establish reliable background relay. Use another camera when the paired iPhone must stay available for Watch relay, or capture without optional Watch motion. See [Apple's Continuity Camera instructions](https://support.apple.com/en-us/102546).

## Make one short check first

Choose **Movement check (no beat)** before applying the setup. Record a short scratch, then **Stop and Finalize**. Use **Play whole take** to check the saved picture and sound, then **Save Capture…** to export the recording. A movement check cannot become a canonical reference by approving it later.

The meter shows captured/generated audio, not proof of sound from the physical speakers or mixer. Confirm the actual sound and saved playback once. The Seventy-Two/Twelve rig needs its own input, MIDI and output check; the Rane ONE MKII pilot does not establish that rig's routing.

## Capture the references

1. Press **New scratch**, choose **Reference take (four repetitions)**, set the technique and phrase, then **Apply Authoring Setup**.
2. Press **Record Draft**. Follow the count-in and perform the same chosen phrase in the four timed repetition slots. The app finishes automatically after the repetitions and tail bar. Stopping early produces diagnostic evidence, not a complete four-repetition reference.
3. Check **Play whole take**, then **Save Capture…**. Give each archive a clear name and keep it.
4. Use **Retake this scratch** for the same setup or **New scratch** to change technique/setup. Keep spoken explanations separate from the clean scratch performance.

## Review can wait

Finalized drafts are saved on this Mac. **Save for Later** also saves the current review notes. In review, **Mark as Preferred** records CXL's best repetition (1–4) for a four-repetition take; **Clear** removes it. The preference, who marked it and when, and the review notes are saved with the draft and included in **Save Capture…** as a separate `notation/*_reference_review_metadata.json` file bound to that exact take and its original media hashes. Marking a preference does not approve, publish, trim or train anything, and the original recording keeps all four repetitions. Movement checks have no numbered repetitions; only notes are exported. Use **Saved drafts → Open for Review** on this same Mac later, keeping the original recording files and beat assets available. A raw capture ZIP is an export, not a portable importable saved draft.

You do not need to press **Approve Canonical Draft** to save or send a raw capture. Later approval requires a complete reference take, a preferred (selected) repetition and the technique's evidence checks. No Watch is required, but a requested Watch transfer that is pending, failed or inconsistent must still be resolved. Approval never creates missing fader, movement or timing evidence.

After approval, **Export Approved Package…** creates the separate verified reference package. **Reopen & Verify Last Export** checks that package. Approval does not publish, install or authorize model training.

## Scope of this pilot

- Includes the rebuilt 23-technique reference library: 24 whole sequences, retaining both unresolved Tears versions, with 95 available camera videos and 72 source audio tracks. It does not treat the duplicated second halves as new performances.
- Automatic detection is advisory. A question mark in notation means uncertain or missing evidence; it is not a confirmed platter pause.
- The unresolved Tears source discrepancy, remaining audio-role and absolute-sync observations, and future avatar motion remain separate work. The completed source audit and rebuild do not need repeating.
- Saved-draft reopening and the production rig still need an operator check on the Mac being used for capture.

## Installing this candidate

Requires macOS 15 or later. The app includes Apple silicon and Intel builds.

Use the supplied signed app as an internal pilot. This candidate is Apple Development signed, not Developer ID notarized. Quit any existing CXL app before replacing it, retain the previous app and recordings, and keep using the same app name/location for later updates.

If macOS blocks this trusted candidate after you try opening it, follow Apple's app-specific **Privacy & Security → Open Anyway** instructions: [Open apps safely on your Mac](https://support.apple.com/en-gb/102445). Do not disable Gatekeeper or reset privacy permissions globally. If the Mac still rejects it, retain the exact message for diagnosis.

## Choosing a scratch to capture

The Technique menu contains exactly the 23 techniques in the reference collection. Extra practice types and combo levels are excluded. Previously saved 2-Click and 3-Click Flare drafts remain readable. Collection names such as Original Flare, Tips and Reverse Cutting keep separate identities. Choose the technique, then use Pattern name and Session notes to describe the variation. The same choice is retained in saved drafts and exports.

Every choice can be recorded; availability does not claim automatic recognition, verified target notation or training eligibility. New techniques keep the existing capture-integrity and operator-approval checks, without invented technique-specific cut counts. Older app builds may not read newly introduced technique identities; use this build or newer to reopen those takes.
