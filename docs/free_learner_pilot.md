# Free learner app: funding and four-week pilot

Decision date: 13 September 2026. Owner: Karl Watson.

Karl wants the learner app to be free. This supersedes the earlier proposal to require the ten pilot learners to pay to continue. The working funding hypothesis is direct sponsorship, with advertising as a possible supplement. No sponsor, revenue, learning benefit or commercial viability has been established.

The immediate sequence is reliable CXL capture, a small set of excellent teaching examples, one complete three-skill learner experience, then a four-week pilot with roughly ten target learners. Live battles, avatars and automated battle judging are saved in [future_product_ideas.md](future_product_ideas.md) and do not block this work.

## Funding options

| Model | Who pays and for what | Assessment and evidence needed |
| --- | --- | --- |
| Direct sponsorship | DJ equipment brands, retailers or education partners fund free lessons or a practice programme, with clearly labelled acknowledgement. | Preferred hypothesis. A relevant, engaged audience may be valuable at a smaller scale than generic advertising. Requires actual budget, a paid agreement and a reason to renew; none exists yet. |
| Conventional in-app advertising | Ad networks pay for delivered impressions. | Supplement to assess after retention is known. Revenue depends on audience, geography, format, fill and realised publisher eCPM. Interruptions can undermine practice. Do not assume ads will cover costs. |
| Institutional funding or licensing | A DJ school or community programme funds learner access, content or separately scoped instructor services. | Possible second route while the learner app stays free. Test demand before building school dashboards or custom integrations. No payment or distribution implementation is authorised by this document. |
| Physical-equipment referrals | A retailer pays commission on qualifying referred purchases. | Optional supplement, not dependable recurring income. Disclose relationships; maintain independent equipment advice and support criteria. No programme acceptance or conversion is assumed. |

Serato's existing DJ-school partnerships show that relationships between equipment/software businesses and DJ education exist. They do not show that Serato or any listed school will fund ScratchLab: [Serato Certified DJ Schools](https://serato.com/certified-dj-schools).

### Advertising arithmetic, not a revenue forecast

AdMob defines publisher eCPM as estimated earnings per thousand ad impressions. Revenue is therefore `delivered impressions / 1000 * realised eCPM`: [AdMob explanation](https://support.google.com/admob/answer/15337570?hl=en).

The following are deliberately hypothetical assumptions in NZD, not industry benchmarks: 12 practice visits per active learner per month, two actually delivered impressions outside practice per visit, and NZ$5 publisher eCPM.

| Monthly active learners | Delivered monthly impressions | Illustrative monthly ad revenue before our costs |
| --- | --- | --- |
| 1,000 | 24,000 | NZ$120 |
| 10,000 | 240,000 | NZ$1,200 |

At NZ$2 or NZ$10 eCPM, the 1,000-learner example becomes NZ$48 or NZ$240. These inputs have not been measured. Requests and installs are not delivered impressions, and ten pilot users cannot validate ad economics. Compare actual receipts against hosting, media delivery, content production, support, sales time, development and any future cloud analysis. Streaming battles would introduce separate costs and remain deferred.

### Initial sponsor offer to validate

A proposed four-week free beginner practice programme with an agreed sponsor acknowledgement outside playback/capture, CXL teaching examples, and an aggregate outcome report. Potential value includes relevant brand exposure and helping new owners use their equipment. Do not promise sales or share individual learner recordings, identities or motion data with a sponsor.

Before outreach, prepare a concrete scope, costed budget, audience definition, deliverables and renewal criteria. Ask several relevant organisations to fund a bounded pilot. An actual paid pilot is stronger evidence than a compliment or non-binding expression of interest. No outreach has been authorised or sent in this planning slice. Keep learners' continued access free if no sponsor materialises; assess whether the budget permits continuation rather than silently introducing a paywall.

### Advertising and privacy constraints

- No ads during a count-in, scratching, recording, lesson audio, critical feedback or recovery. Do not require an ad to save a recording or access the three core skills.
- Start the learner pilot without a third-party ad SDK. A clearly labelled sponsor acknowledgement can test acceptance without adding tracking dependencies.
- Sponsors cannot alter teaching advice, measurements, scores or future judging outcomes. Camera, microphone and Watch data are not advertising data.
- Prefer contextual placements and aggregate reporting. Any future cross-company tracking needs the relevant user permission; a third-party SDK's own use of data matters too. See [Apple privacy guidance](https://developer.apple.com/app-store/user-privacy-and-data-use/).
- Before implementing ads, check the then-current [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), including 2.5.18 for ad placement, dismissal and reporting. No ads belong in the CXL capture tools or Watch companion.

## Delivery and learner validation

### 1. Close CXL capture and collect a small teaching set

Review Claude's completed handoff and exact commits before integration. As inspected on 13 September, only the route-regression commit `3558128` is complete. Preferred-repetition/export changes are still dirty, the all-platform gate is running, and `HANDOFF_TO_CODEX.md` is absent. The pasted transcript is progress evidence, not proof of completion. The Mac meter task remains open: Claude did not reproduce the operator failure and made no production meter fix.

After integration and appropriate software checks, make one supported-rig physical check of direct sound and the actual app meter, primary/optional secondary recording, finalized playback, preference/notes export and draft reopening. Preserve recordings and stable CXL signing identity. Do not replace an app during capture or treat a Rane ONE pilot as Seventy-Two/Twelve acceptance. Do not repeat Claude's completed source-video audit.

Then collect a deliberately small set of clean slow and normal demonstrations with clear hands/fader visibility, correct timing, clean audio and CXL's preferred repetition and notes. Keep narration separate. CXL confirms the final three teaching skills before lesson authoring; a provisional candidate is Baby Scratch, plain Tear and Chirp, covering continuous movement, interrupted movement and fader coordination. This is not a claim that all three already have reliable automatic scoring.

### 2. Finish one learner journey

Support one explicitly documented setup whose routing and measurements have passed physical checks. Provisional development setup: Mac plus the existing Rane ONE MKII pilot hardware; select the final learner setup against the recruited learners' actual equipment before freezing the pilot. Do not imply support for arbitrary controllers, microphone-only analysis or untested operating systems.

For each of the three skills, finish: setup -> watch/listen -> understand one goal -> practise -> replay/compare -> receive supported feedback -> choose the next exercise -> save progress. Review can use evidence and expert-authored guidance; do not invent classifier certainty or scoring where the current profile documents research limitations. Learners do not need a Watch. The CXL app remains separate from the full learner app.

### 3. Run a four-week pilot with roughly ten target learners

Recruit people at the intended skill level, including people outside Karl's friends and collaborators. Record baseline and final performances under comparable conditions. Record setup help, first successful practice, voluntary practice sessions, return weeks, abandonment reasons, support minutes and delivery cost. Collect only the measurements needed for this evaluation, with appropriate consent for recordings and CXL review.

Where practical, compare with ordinary-video practice using a similar curriculum, equipment and planned practice time. A possible design is five learners per group with random assignment. Have CXL assess recordings in mixed order without app/video group labels where feasible, against a written rubric. Ten learners provide directional product evidence, not a statistically conclusive learning or market claim.

### 4. Evaluate learner benefit and payer demand separately

Learner questions: Can people start without live help, practise repeatedly, improve in independently reviewed recordings and voluntarily keep using the free app? Track whether sponsor placement distracts them and whether support effort is sustainable.

Business questions: Will a sponsor or institution actually pay for the defined programme, and renew after seeing the results? Replace the old mandatory learner-payment test with this payer test. Learner enthusiasm does not establish sponsor demand, and sponsor enthusiasm does not establish learning benefit.

Proposed decision thresholds, to freeze before recruitment rather than choose after seeing results: at least eight of ten complete setup and a first practice with written guidance only; at least six practise twice a week in at least three weeks; expert review finds meaningful improvement under its pre-written rubric; report the ordinary-video comparison and all missing outcomes. For funding, seek at least one paid pilot covering its defined incremental delivery costs and an explicit renewal decision. These are experiment choices, not established industry success benchmarks or proof of a profitable business.

If learning, retention or setup fails, improve that three-skill loop before adding scope. If learners benefit but funding fails, revise the sponsor offer and cost model before scaling; do not expand based on assumed ad income.

## Watch motion: optional CXL research only

Karl's constraint: Watch data capture is only for CXL reference capture, and only where there is a useful present or future purpose. It is not a learner requirement, battle entry requirement or prerequisite for teaching content. This is a product policy; this document does not claim existing learner Watch UI has been removed.

Potential use is wrist orientation/rotation and movement timing as supplementary reference evidence or future wrist/avatar animation. Core Motion provides device attitude, rotation rate and acceleration: [CMDeviceMotion](https://developer.apple.com/documentation/coremotion/cmdevicemotion). A wrist sensor does not by itself establish finger positions, crossfader state, platter travel, accurate full-body motion or scratch quality. No current learner benefit has been established by a comparison with and without Watch evidence.

Keep Watch off for ordinary CXL captures. If it adds no material setup burden, collect an optional small research subset within already planned takes, with a written wrist-animation or timing question. Confirm exact take identity, meaningful timestamp alignment and coverage; preserve missing/gapped states. Evaluate whether the extra signal adds useful information compared with audio, camera and available controller data. Continue collecting only if it does. Keep original consent/use restrictions with the evidence and do not train a model automatically.

Never delay good audio/video captures to troubleshoot optional Watch relay. In particular, the same iPhone's Continuity Camera and foreground Watch relay are not established as simultaneously reliable. A second camera can remain useful without Watch motion. Existing evidence integrity checks stay strict; optional does not mean falsely linked or silently repaired.

## Status of this decision

This slice records product direction, funding hypotheses, the pilot design and deferred work. It adds no ad SDK, billing, live battle, avatar, scoring, model training or runtime Watch changes. Learner recruitment, sponsor outreach and physical CXL performances have not happened through this document.
