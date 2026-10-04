import { describe, it, expect } from 'vitest';
import { fitWithin } from './imageResize';

describe('fitWithin', () => {
  it('keeps small images as they are', () => {
    expect(fitWithin(1200, 800, 2048)).toEqual({ width: 1200, height: 800 });
  });

  it('scales a landscape photo down by its longest side', () => {
    expect(fitWithin(4000, 3000, 2000)).toEqual({ width: 2000, height: 1500 });
  });

  it('scales a portrait photo down by its longest side', () => {
    expect(fitWithin(3000, 4000, 2000)).toEqual({ width: 1500, height: 2000 });
  });
});
