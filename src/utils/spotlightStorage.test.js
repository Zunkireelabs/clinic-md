import { describe, it, expect } from 'vitest';
import { spotlightKey, isSpotlightDismissed, dismissSpotlight } from './spotlightStorage';

const memory = () => { const m = new Map(); return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, v) }; };

describe('spotlight dismissal', () => {
  it('uses a per-banner, per-user key', () => {
    expect(spotlightKey('ai-consultation-v1', 'u1')).toBe('clinicmd.spotlight.ai-consultation-v1.u1');
  });
  it('is not dismissed until dismissed, then stays dismissed', () => {
    const s = memory();
    expect(isSpotlightDismissed('x', 'u1', s)).toBe(false);
    dismissSpotlight('x', 'u1', s);
    expect(isSpotlightDismissed('x', 'u1', s)).toBe(true);
  });
  it('does not leak across users or banners', () => {
    const s = memory();
    dismissSpotlight('x', 'u1', s);
    expect(isSpotlightDismissed('x', 'u2', s)).toBe(false);
    expect(isSpotlightDismissed('y', 'u1', s)).toBe(false);
  });
  it('survives a throwing storage', () => {
    const bad = { getItem: () => { throw new Error('denied'); }, setItem: () => { throw new Error('denied'); } };
    expect(isSpotlightDismissed('x', 'u1', bad)).toBe(false);
    expect(() => dismissSpotlight('x', 'u1', bad)).not.toThrow();
  });
});
