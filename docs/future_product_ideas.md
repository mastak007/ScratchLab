# Future product ideas — deferred by Karl

Recorded 13 September 2026 at Karl's request. These are future requirements and research questions, not implemented features or current delivery blockers. Resume only after evaluating the focused [free learner pilot](free_learner_pilot.md) and selecting one bounded next task.

## Live online DJ battles

- Connect remote DJs for live, timed, turn-taking battles with a host, opponents and spectators. Explore DMC or other competition organisers as possible customers or licensees; no interest, relationship or sale is established.
- Local mixer monitoring must stay direct. Internet transport must not become the performing DJ's monitoring path. Simultaneous zero-delay remote performance is not promised.
- Reuse capture, metadata, review and export where suitable. Existing nearby-camera relay and completed-file uploads are not an internet battle platform.
- Required investigation includes actual physical mixer-master capture, live transport, round handovers, reconnect policy, recordings, fair timing and organiser operations. Current CXL internal generated AHHH is not proven full-mixer master audio.
- Validate one small hosted exhibition with existing streaming infrastructure before building an extensive service.

## Private avatar presentation

- Karl wants live pictures replaced by Memoji-style DJ avatars to avoid exposing performers' faces, bodies and rooms publicly.
- Target custom characters using supported public APIs; do not assume access to Apple's own Memoji characters. Face expression animation and precise whole-body/finger reconstruction are different capabilities.
- Proposed privacy architecture: process cameras locally and transmit the rendered virtual scene and intended performance audio. A tracking failure must never reveal raw video. Provide a camera-free character option.
- Public avatar presentation does not itself prove that a DJ is performing live or establish anonymity. Any private competition verification would need a separately explained, agreed policy; no hidden camera upload.
- Future 3D battling DJs and motion reuse remain research. Watch is optional CXL-only supplementary wrist evidence under the policy in the pilot plan, not a required consumer sensor or a complete motion-capture system.

## Automatic live judging

- Karl wants the app to judge both DJs while they perform, rather than depend permanently on human judging.
- Judge actual performance evidence independently of avatar appearance. Show provisional running results, then finalise the round. Timing must use the recorded performance and its beat reference, not packet arrival time.
- First feasible validation target: defined scratch challenges with agreed patterns and tempos. Freestyle originality, phrasing, musicality and difficulty need separate expert-labelled evidence and evaluation across unseen DJs/equipment.
- More cuts, higher speed or more recognised techniques must not automatically imply better musical performance. Unknown measurements must remain unknown.
- Present recognition is research/advisory, not an established automatic competition judge. CXL good examples alone do not supply the full range of performances, comparative rankings or failure cases needed to validate judging.
- Ranked matches require replay/tamper resistance, reproducibility and a dispute process. Do not assume audio, MIDI or a score sent by a client proves live authenticity. DMC acceptance is an independent validation question.

## Promotion gate

Revisit after the three-skill learner trial, demonstrated capture reliability and an explicit funding/organiser demand decision. Define measurable acceptance for the chosen experiment before implementation. Do not start rebuilding the audited dataset, training models, capturing extra motion or adding network services merely because this file exists.
