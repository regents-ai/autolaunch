import React, {useLayoutEffect, useRef} from 'react';
import {AbsoluteFill, Audio, Composition, cancelRender, continueRender, delayRender, registerRoot, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {createScene, type Scene} from './scene.js';

const Film: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const canvas = useRef<HTMLCanvasElement>(null);
  const scene = useRef<Scene | null>(null);
  useLayoutEffect(() => {
    const handle = delayRender(`Autolaunch frame ${frame}`);
    let active = true;
    if (!canvas.current) {cancelRender(new Error('Missing canvas')); return;}
    scene.current ??= createScene(canvas.current, name => staticFile(`assets/${name}`));
    const renderer = scene.current;
    renderer.ready.then(() => {
      if (active) renderer.draw(frame / fps);
      continueRender(handle);
    }).catch(cancelRender);
    return () => {active = false;};
  }, [frame, fps]);
  return <AbsoluteFill style={{background: '#f3f1e9'}}>
    <canvas ref={canvas} width={1400} height={1400} style={{width: '100%', height: '100%'}} />
    <Audio src={staticFile('assets/launch.wav')} />
  </AbsoluteFill>;
};
registerRoot(() => <Composition id="Autolaunch" component={Film} width={1400} height={1400} fps={60} durationInFrames={1104} />);
