# Autolaunch — Revision 4

18.4-second launch-film revision. The first CCA passage ends around 12 seconds, the second around 15 seconds, then the unchanged final scene plays. Earlier exports remain archived separately.

> Launch markets for agents and onchain stocks.

## Story

| Time | Beat |
| --- | --- |
| 0–2.8s | Floating toolbar, Autolaunch crown, typing “a new way to launch” |
| 2.8–4.75s | Soft-focus Tangerine reveal: “A new way to launch” |
| 4.75–8.35s | “Launch markets for” with Agent revenue → Onchain stocks |
| 8.55–9.1s | “Create Uniswap CCA auctions on Base for:” heading enters |
| 9.1–12s | “agents and x402 service. Tokens are staked for stablecoin revshare.” |
| 12–15s | First text exits; “or pair your meme token with any onchain stock on Base” replaces it |
| 15–18.4s | Unchanged orange crown on charcoal end card, retimed; Autolaunch, autolaunch.sh, Coming soon |

This is a launch teaser, not a recording of working contracts or a claim that trading is enabled. Art is conceptual, not market data.

## Local commands

Node 22+, Python 3 (standard library only), FFmpeg and Chrome or the Remotion-managed browser are required.

```sh
npm ci --ignore-scripts
npm run audio
npm run typecheck
npm run review
npm run render
```

- `out/revision-4/autolaunch-master.mp4`: 1400×1400, 60 fps.
- `out/revision-4/autolaunch-x.mp4`: 1080×1080, 30 fps, H.264/AAC, fast start.
- `out/revision-4/frame-*.png`: storyboard checks.
- `src/scene.js`: editable motion, copy, positioning and end card.
- `scripts/audio.py`: original, repeatable stereo sound design.

The render script uses installed macOS Chrome when available; `REMOTION_BROWSER_EXECUTABLE` overrides it. All bundled imagery/fonts/audio render locally. No API key is needed to reproduce the video from bundled assets.

## Reference and scope

Motion reference: https://github.com/Tejashmakwana/astra-motion-recreation-remotion at `d83832cace7e984c58dd805b668d2c41c15946fe`, crediting original motion direction to @rajzmotion.

Preserved motion ideas: floating bar, type-on cursor, full-frame soft material reveal, collapse to a word-sized shape, scrolling labels, charcoal close. New explanatory passages enter line by line, hold for reading, and replace one another below a fixed heading. The collage section is no longer rendered. Earlier exports remain preserved; no platform, contract, database or deployment files are changed.

This is a local creative draft for Sean's acceptance, not approval to publish on X. Reference code's public availability is not an asserted redistribution license; no new license is assigned to adapted reference portions.
