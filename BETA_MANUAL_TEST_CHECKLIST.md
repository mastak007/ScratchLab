# ScratchLab V3.2 — Beta Manual Test Checklist

Commit `7efbb70` · branch `feature/v3.2-swiftui-20260815` · NOT pushed / NOT uploaded.

Fill in **Pass / Fail** by hand. A "Fail" needs a one-line note (and, if it's a blocker, it
blocks the beta upload). These eight items are the runtime gaps the build/archive gates cannot
cover — the app has **not** been exercised on real hardware or by VoiceOver as of this writing.

| # | Test | Platform(s) | What to do | Expected | Pass/Fail | Notes |
|---|------|-------------|------------|----------|-----------|-------|
| 1 | Practice — listen/copy/result | macOS, iPhone, iPad | Open Practice → tap "Watch"/"Listen" (demo plays, notation animates) → "Start Copying" → perform a baby scratch → end → read the RESULT screen | Demo audio plays; notation playhead follows; RESULT shows a score/coaching, never a fake "MY PERFORMANCE" trace | ☐ | |
| 2 | Capture — record/stop/save | macOS | Configure a session (name, baby scratch, BPM) → Record → perform a take → Stop | Stage advances setup→readiness→record→finalizing→complete; a take appears; "Review this take" becomes available; no state-update warnings in console | ☐ | Needs camera + audio input |
| 3 | Review — correct/confirm/export | macOS | Open Review → "Correct label" / "Leave unknown" / "Accept" → check the badge → "Export ZIP" | Header badge shows CORRECTED/CONFIRMED (not Pending); export produces a ZIP; media files unchanged | ☐ | Needs a real recorded take from #2 |
| 4 | Advanced — diagnose & return | macOS | Open Advanced → view Audio/DVS, MIDI, Calibration, Performer Monitor sections → switch back to Practice/Review | No crash; selected session + captured take still present after returning | ☐ | |
| 5 | Permission grant + denial | macOS, iPhone | Fresh install → trigger camera/mic → **grant** once, then **deny** once (Settings → reset) | Grant: feed works. Deny: honest "go to Settings" recovery, no crash, no hang | ☐ | Test BOTH grant and denial |
| 6 | DVS/MIDI hardware | macOS | Connect RANE ONE MKII (platter CC6) and DDJ-GRV6 (crossfader) → check Capture/Advanced readiness | Platter motion + crossfader map to ready/detected states; DVS shows usable only with real signal | ☐ | HARDWARE REQUIRED |
| 7 | Companion camera + Performer Monitor | macOS + iPhone | Open Performer Monitor on Mac; open Companion Camera on iPhone; connect over local network | Devices discover over Bonjour; frames relay; no local-network rationale re-prompt | ☐ | HARDWARE REQUIRED |
| 8 | Layout + VoiceOver + Dynamic Type | macOS, iPhone, iPad | Resize macOS window to 1440×900 and 1280×800; enable VoiceOver; set a larger Dynamic Type size | No blank/clipped/oversized layouts; primary controls have VoiceOver labels; key text scales (or documented as fixed) | ☐ | |

## Summary

- **Pass:** ___ / 8
- **Blockers (fails that stop upload):**
- **Tester:** __________  **Date:** __________
