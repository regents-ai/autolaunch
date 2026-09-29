# Verification

Verified locally on macOS with Node.js 26.8.1, FFmpeg 8.0.1 and the installed Google Chrome executable.

- `npm ci --ignore-scripts --no-audit --no-fund` completed.
- `npm run typecheck` passed.
- `npm run verify` matched all 8 bundled media assets against `assets-manifest.json`.
- `npm run audio` produced the same soundtrack SHA-256 on two consecutive runs with its fixed noise seed.
- `npm run review` rendered nine review frames; the stable copy and final end card were visually inspected after correcting the journey-line layout.
- `npm run render` completed all 753 frames.
- FFmpeg decoded the finished MP4 without errors.
- FFprobe confirmed the H.264/AAC master at 1400 × 1400 and 60 fps, 12.55 seconds, and 2,210,027 bytes.
- The X delivery decodes as H.264/AAC at 1200 × 1200 and 30 fps, 12.566 seconds, and 1,281,669 bytes. Both MP4 files place `moov` before `mdat` for fast start.
- The original synthesized audio measures -17.20 dB peak and -26.25 dB RMS in the final mux.
- `git diff --check` passed.

The master is `out/autolaunch-launch.mp4`. The conservative X delivery is `out/autolaunch-launch-x.mp4` at 1200 × 1200, 30 fps, H.264/AAC and fast-start MP4. The output directory is intentionally ignored; regenerate both files from the tracked source and asset manifest.

The film uses only Autolaunch-specific copy and artwork. It does not bundle the motion reference's film, soundtrack, OpenAI font, OpenAI/ChatGPT mark or generated collages.
