# DJ Operator Quickstart

## Goal

Run one clean baby-scratch session with as few decisions as possible.

## Before You Start

Have these ready:

- Serato DJ Pro ready to record clean WAV audio
- primary iPhone charged and mounted as `camA`
- optional second iPhone ready as extra `camB` coverage
- optional Apple Watch on the scratching hand
- session folder already created for the DJ and date

## Rane ONE MKII Controller Setup (MIDI Learn)

Only relevant if you are mapping a Rane ONE MKII through MIDI Learn.

Before you run MIDI Learn, set the channel-assign switch above the fader fully
left. If it is not fully left, the mixer section's MIDI output is silenced: the
upfaders and the normal (unshifted) hot-cue pads may not transmit any MIDI, so
MIDI Learn cannot see them. Only the crossfader and the SHIFT + pad layer still
transmit in that position. With the switch fully left, every control transmits.

Verified addresses with the switch fully left (1-indexed channel, raw 0-indexed
in parentheses):

- crossfader: `CC 8`, channel 16 (raw 15)
- left upfader: `CC 28`, channel 1 (raw 0)
- right upfader: `CC 28`, channel 2 (raw 1)
- Hot Cue 1: `NoteOn` channel 6 (raw 5), note 20
- Hot Cue 2: `NoteOn` channel 6 (raw 5), note 21
- SHIFT + Hot Cue 1: `NoteOn` channel 16 (raw 15), note 50 (shift layer only)

## Session Rules

Do not change these during the session:

- scratch type: `baby scratch` only
- BPMs: `70`, `90`, `110` only
- take structure: `3` scratches per take
- scratch length: about `20` seconds each

## One Take Workflow

For every take:

1. Start recording on every device you are using.
2. Say the slate: `baby scratch, [BPM], take [number]`
3. Clap three times: `CLAP CLAP CLAP`
4. Perform scratch 1 for about 20 seconds.
5. Clap once.
6. Perform scratch 2 for about 20 seconds.
7. Clap once.
8. Perform scratch 3 for about 20 seconds.
9. Stop recording.
10. Move all source files into the session `raw/` folder.

## Minimum Session

Get at least one usable take at:

- one valid take at `70` BPM
- one valid take at `90` BPM
- one valid take at `110` BPM

If a take is bad, stay on the same BPM and use the next take number.

## What To Say

Use this exact wording:

- `baby scratch, 70, take 1`
- `baby scratch, 90, take 1`
- `baby scratch, 110, take 1`

Do not add extra talk before the first clap.

## What Good Looks Like

A good take has:

- clear hands and deck in frame
- clear Serato audio
- obvious clap markers
- three full baby-scratch segments
- no change of scratch type mid-take

## Stop And Retake If

- you forgot the verbal slate
- you forgot the opening triple clap
- you missed a separator clap
- the wrong BPM was used
- the camera missed the hands, platter, or fader
- audio did not record cleanly

## After Each Take

Before you move on:

1. Confirm the files exist.
2. Put originals into `raw/`.
3. Note any issue while it is still fresh.
4. If the take is usable, keep it.
5. If the take is not usable, redo that BPM with the next take number.

## End Of Session

Before you pack up:

1. Make sure `70`, `90`, and `110` BPM each have at least one usable take.
2. Make sure the raw files are copied into the session folder.
3. Rename the files into the standard naming format.
4. Run session validation.

If those four things are true, the session is ready.
