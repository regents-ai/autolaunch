# Render evidence — revision 4

- Timing-only revision: first passage transitions out around 12s; second passage transitions out around 15s; final scene begins at 15s with its original 3.4-second duration preserved.
- Composition and synthesized stereo sound are now 18.4s. Retimed text transition, closing cues, motion sampling and review frames together. Copy and design are unchanged.
- Audio generation, TypeScript checking, seven storyboard stills, and full render passed.
- Both master (1400×1400, 60 fps, 1,104 frames) and X delivery (1080×1080, 30 fps, 552 frames) decoded completely through FFmpeg without errors. Both video streams are exactly 18.4s; AAC padding extends containers slightly.
- Inspected the second passage at 13s, crown close at 16s, and chronological frames extracted from the encoded delivery. File copies were hash-matched; earlier exports are preserved.
- Outputs: `out/revision-4/autolaunch-master.mp4` and `out/revision-4/autolaunch-x.mp4`. No posting, deployment or commits.

## Prior revision 3 evidence (historical)

Actual local execution for the founder's two requested edits:

- Opening field now types the complete lowercase `a new way to launch`.
- The entire `Two paths.` collage section is removed from rendering. The fixed CCA heading introduces the exact requested agent/x402/revshare passage, then the meme/onchain-stock passage replaces it with staggered text animation.
- Extended the composition and original generated stereo audio to 24 seconds for reading time. The earlier reveal/chips and crown close retain their design; the close is retimed.
- `npm run audio`, `npm run typecheck`, `npm run review`, and `npm run render` passed.
- Rendered twelve review stills and all 1,440 master frames. Inspected the full field, both explanatory passages, a contact sheet extracted from the encoded X video, and its full-size final crown card.
- Both MP4 files fully decoded through FFmpeg without errors. `git diff --check` passed (the media package remains untracked).

| Output | Video | Audio | Container duration | Size | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| `out/revision-3/autolaunch-master.mp4` | H.264, 1400×1400, 60 fps, full-range 4:2:0 | AAC, stereo, 48 kHz | 24.042667s | 2,751,470 bytes | `c7ec3875c1f5067c06fe2a0645859acb936735ee43fcef5b5fcc5d7fd188150c` |
| `out/revision-3/autolaunch-x.mp4` | H.264, 1080×1080, 30 fps, limited-range 4:2:0 | AAC, stereo, 48 kHz | 24.042000s | 1,223,398 bytes | `110bf13e8debc2d868f3175ea148dc6cb2f0c15b9faeb495992cd1bb748d26eb` |

Video duration is exactly 24 seconds; container duration includes AAC padding. Revision 3 is for creative review, not yet approved for publication. Prior approved-v2 exports are unchanged. No website, database, wallet, contract, deployment, commit, push or posting changes.

## Prior v2 evidence (historical; not the current composition)

Actual local execution:

- Installed pinned Remotion 4.0.521 dependencies; TypeScript check passed.
- Ran `scripts/audio.py` to synthesize a 15-second stereo track without external samples.
- Rendered ten storyboard frames; inspected actual collage composition and the canonical orange/charcoal crown.
- Rendered all 900 frames of the new composition, then encoded an X delivery.
- Both files fully decoded through FFmpeg with no errors.
- Inspected a chronological contact sheet and full-resolution end card extracted from the encoded X file (not just source canvas).

| Output | Video | Audio | Container duration | Size | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| `out/autolaunch-master.mp4` | H.264, 1400×1400, 60 fps, full-range 4:2:0 | AAC, stereo, 48 kHz | 15.061333s | 3,163,214 bytes | `acc48efa54bd7f91813fde0aed342de7bf7b3dd072da8198abfedf1faaf84233` |
| `out/autolaunch-x.mp4` | H.264, 1080×1080, 30 fps, limited-range 4:2:0 | AAC, stereo, 48 kHz | 15.061s | 1,351,984 bytes | `afa13ec84ff95cada8c88a9e9ed0164a71c477389af2ca3bbe50fcff588d1704` |

The composition is exactly 15 seconds; container duration includes AAC padding. No website routes, databases, wallets, contracts, deployment configuration or other apps were changed. No commits, pushes or X upload occurred.

This evidence establishes a renderable, inspectable creative draft. It does not establish Sean's creative acceptance or an accepted X upload.
