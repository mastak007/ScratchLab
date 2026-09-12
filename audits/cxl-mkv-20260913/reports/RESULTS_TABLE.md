# Per-technique results

Generated from `batch-state.json`. `state` is the runner's classification; the columns after it are
the measurements it classified on. An offset is always the SEARCHED value, never assumed to be half
the chapter.

| technique | state | titles | offset (fr) | = half? | audio ncc med | lag spread | divergence | missing angles | identical titles |
|---|---|---|---:|---|---:|---:|---|---|---|
| 1clickflare_85bpm | verified_duplicate_half | t44,t45,t46,t47 | 1355 | yes | 0.9999 | 0.0 | - | - | - |
| baby_79bpm | verified_duplicate_half | t00,t01,t02,t03 | 726 | NO | 0.9999 | 0.0 | - | - | t05+t06 |
| chirpflare_92bpm | verified_duplicate_half | t52,t53,t54,t55 | 1249 | yes | 0.9999 | 0.0 | - | - | - |
| chirps_98bpm | verified_duplicate_half | t20,t21,t22,t23 | 588 | yes | 0.9999 | 0.06 | - | - | - |
| clovertears_105bpm | verified_duplicate_half | t74,t75,t76,t77 | 549 | NO | 0.99995 | 0.0 | - | - | - |
| crabs_92bpm | verified_duplicate_half | t102,t103,t104,t105 | 1249 | yes | 1.0 | 0.0 | - | - | - |
| cresentflare_92bpm | verified_duplicate_half | t48,t49,t50,t51 | 1249 | yes | 0.9999 | 0.19 | - | - | - |
| cutting_79bpm | verified_duplicate_half | t04,t05,t07 | 726 | NO | 1.0 | 0.0 | - | 2 | t05+t06 |
| dicing_85bpm | verified_duplicate_half | t40,t41,t42,t43 | 1355 | yes | 0.9999 | 0.43 | - | - | - |
| drags_98bpm | verified_duplicate_half | t16,t17,t18,t19 | 1175 | yes | 0.9999 | 1.1 | - | - | - |
| lazers_92bpm | verified_duplicate_half | t56,t57,t58,t59 | 624 | NO | 0.9999 | 0.1 | - | - | - |
| long_short_tips_105bpm | verified_duplicate_half | t32,t33,t34,t35 | 1097 | yes | 0.9998 | 0.0 | - | - | - |
| marches_79bpm | verified_duplicate_half | t12,t13,t14,t15 | 726 | yes | 0.9999 | 1.08 | - | - | - |
| needledropping_105bpm | verified_duplicate_half | t78,t79,t80,t81 | 823 | yes | 0.9999 | 0.0 | - | - | - |
| orbits_85bpm | verified_duplicate_half | t100,t101,t98,t99 | 1016 | yes | 1.0 | 0.0 | - | - | - |
| originalflare_85bpm | verified_duplicate_half | t94,t95,t96,t97 | 1016 | yes | 1.0 | 0.0 | - | - | - |
| reversecutting_79bpm | verified_duplicate_half | t08,t09,t10,t11 | 726 | yes | 0.99965 | 2.17 | - | - | - |
| swipes_105bpm | verified_duplicate_half | t90,t91,t92,t93 | 548 | yes | 0.9999 | 0.17 | - | - | - |
| tears_98bpm | verified_partial_repeat | t24,t25,t26,t27 | 1175 | NO | 0.9999 | 30.52 | [[56.043, 58.043]] | - | - |
| tips_105bpm | verified_duplicate_half | t28,t29,t30,t31 | 548 | yes | 0.99975 | 0.39 | - | - | - |
| transformer_85bpm | verified_duplicate_half | t36,t37,t38,t39 | 1355 | yes | 1.0 | 0.02 | - | - | - |
| waves_105bpm | verified_duplicate_half | t86,t87,t88,t89 | 1097 | yes | 0.9999 | 0.0 | - | - | - |
| zigzags_105bpm | verified_duplicate_half | t82,t83,t84,t85 | 548 | yes | 0.9998 | 0.13 | - | - | - |

23 techniques classified of 23.

## Column meanings

- **offset (fr)** - repeat offset in video frames, found by searching every offset.
- **= half?** - whether that equals half the chapter-2 duration. `NO` is common and expected.
- **audio ncc med** - median isolated-scratch correlation across active 1 s windows at the best
  FRACTIONAL lag. Integer-lag correlation under-reports and is not used here.
- **lag spread** - how far the best lag moves across the span, in audio samples. A non-zero spread
  indicates a splice in the authored copy, not drift.
- **divergence** - spans where the picture still duplicates but the audio does not. These go to
  `reports/REVIEW_QUEUE.json`; the evidence never says which pass is faithful.
- **identical titles** - two titles in the group decoding to the same frames. Note that `baby` and
  `cutting` share a chapter group, so cutting's t05+t06 pair appears in both rows.

## What none of these columns establish

- Absolute audio/video synchronisation. Every timing figure is relative, across a title's own repeat.
- That any region is speech-free. Talking boundaries need operator audition.
