export type Scene = {
  ready: Promise<unknown>;
  draw: (seconds: number) => void;
};
export function createScene(canvas: HTMLCanvasElement, assetUrl: (name: string) => string): Scene;
