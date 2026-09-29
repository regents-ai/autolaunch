import React, {useLayoutEffect, useRef} from 'react';
import {
  AbsoluteFill,
  Audio,
  Composition,
  cancelRender,
  continueRender,
  delayRender,
  registerRoot,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {createScene, type Scene} from './scene.js';

const AutolaunchFilm: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const canvas = useRef<HTMLCanvasElement>(null);
  const scene = useRef<Scene | null>(null);

  useLayoutEffect(() => {
    const handle = delayRender(`Drawing Autolaunch frame ${frame}`);
    let active = true;
    const element = canvas.current;
    if (!element) {
      cancelRender(new Error('Missing canvas'));
      return;
    }
    scene.current ??= createScene(element, (name: string) => staticFile(`assets/${name}`));
    const renderer = scene.current;
    renderer.ready
      .then(() => {
        if (active) renderer.draw(frame / fps);
        continueRender(handle);
      })
      .catch((error: unknown) => cancelRender(error));
    return () => {
      active = false;
    };
  }, [frame, fps]);

  return (
    <AbsoluteFill style={{backgroundColor: '#E5E3D2'}}>
      <canvas ref={canvas} width={1400} height={1400} style={{width: 1400, height: 1400}} />
      <Audio src={staticFile('assets/autolaunch-bed.m4a')} />
    </AbsoluteFill>
  );
};

const Root: React.FC = () => (
  <Composition
    id="AutolaunchLaunchFilm"
    component={AutolaunchFilm}
    width={1400}
    height={1400}
    fps={60}
    durationInFrames={753}
  />
);

registerRoot(Root);
