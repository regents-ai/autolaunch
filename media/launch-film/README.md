# Autolaunch launch film

A 12.55-second, square Remotion film for the Autolaunch launch on X. It follows the pacing and motion grammar of Tejash Makwana's Astra motion recreation while replacing every scene, label, illustration, font, color and end card with Autolaunch-specific material.

The story is product-specific: **create an auction → discover a price through bids → graduate onchain**. It contains no generic AI copy and makes no claim that contracts are deployed.

## Run

Requires Node.js 22 or newer and FFmpeg on `PATH`.

```sh
npm ci
npm run studio
```

## Render and review

```sh
npm run typecheck
npm run verify
npm run review
npm run render
```

- Master: `out/autolaunch-launch.mp4` (1400 × 1400, 60 fps)
- X delivery: `out/autolaunch-launch-x.mp4` (1200 × 1200, 30 fps)
- Review frames: `out/frame-*.png`
- Composition: 1400 × 1400, 60 fps, 753 frames

Set `REMOTION_BROWSER_EXECUTABLE` to an installed compatible Chrome executable when Remotion's managed browser is unavailable.

## Edit

- `src/scene.js`: motion, product copy, geometry, illustrations and timing.
- `src/index.tsx`: composition and original audio track.
- `scripts/generate-audio.mjs`: deterministic FFmpeg synthesis for the original audio bed (`npm run audio`).
- `public/assets/`: Autolaunch mark, Regent fonts and generated soundtrack.

## Reference

Motion reference: [`Tejashmakwana/astra-motion-recreation-remotion`](https://github.com/Tejashmakwana/astra-motion-recreation-remotion), itself crediting the original motion design to [@rajzmotion](https://x.com/rajzmotion). This package does not include their source film, artwork, OpenAI marks, fonts, or soundtrack.
