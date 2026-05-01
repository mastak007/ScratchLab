# Naming Convention

## Purpose

Every renamed file must use one predictable, human-readable pattern.

## Canonical Format

```text
DJNAME_baby_BPM_takeNN_SOURCE.EXT
```

Examples:

```text
DJNAME_baby_090_take01_camA.mov
DJNAME_baby_090_take01_serato.wav
DJNAME_baby_090_take01_watch.csv
```

## Field Rules

### `DJNAME`

- uppercase letters and numbers only
- no spaces
- no punctuation

Example:

- `DJ Prime Cuts` becomes `DJPRIMECUTS`

### `baby`

- fixed value for this MVP
- always lowercase

### `BPM`

- use three digits
- allowed values: `070`, `090`, `110`

### `takeNN`

- two-digit take number
- numbering starts at `01`
- numbering restarts inside each BPM set

### `SOURCE`

Use one of these source tokens:

- `camA` for the primary iPhone video
- `camB` for the secondary iPhone video
- `serato` for the clean audio file
- `watch` for the Apple Watch export

### `EXT`

Use the real file extension:

- `.mov` for iPhone video
- `.wav` for Serato audio
- `.csv` for watch export

## Folder Placement

After rename, place files here:

- `video/` for `camA` and `camB`
- `audio/` for `serato`
- `watch/` for `watch`

Keep untouched originals in `raw/`.

## Examples By Take

For the first 90 BPM take:

```text
video/DJNAME_baby_090_take01_camA.mov
audio/DJNAME_baby_090_take01_serato.wav
watch/DJNAME_baby_090_take01_watch.csv
```

For a second 110 BPM take with two cameras:

```text
video/DJNAME_baby_110_take02_camA.mov
video/DJNAME_baby_110_take02_camB.mov
audio/DJNAME_baby_110_take02_serato.wav
watch/DJNAME_baby_110_take02_watch.csv
```

## Raw File Rule

Do not rename files in place on the phone or watch. Copy originals into `raw/` first, then rename into the final session folders.

Every `raw_*` value in `take_log.csv` must stay relative to that session's `raw/` folder. Absolute paths and `..` escapes are invalid.

## Overwrite Rule

Never overwrite an existing renamed file. If a filename already exists, `rename_files.py` stops with a conflict, removes any renamed files it copied during the current run, and leaves the current manifest unchanged until the conflict is resolved.

## Invalid Examples

These are not valid:

```text
djname_baby_90_take1_camA.mov
DJNAME_BABY_090_01.wav
DJNAME_baby_100_take01_serato.wav
DJNAME_baby_090_take01_audio.wav
```

Reasons:

- wrong DJ token format
- wrong BPM padding
- wrong take padding
- unsupported BPM
- unsupported source token
