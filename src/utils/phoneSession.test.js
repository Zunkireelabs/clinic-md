import { describe, it, expect, beforeEach } from 'vitest';
import { markPhoneUnlocked, touchPhone, isPhoneUnlocked, resetPhoneSession, LOCK_AFTER_MS } from './phoneSession';

describe('phone session lock', () => {
  beforeEach(() => resetPhoneSession());

  it('starts locked: a fresh open always needs the code', () => {
    expect(isPhoneUnlocked(1000)).toBe(false);
  });

  it('stays open while in use', () => {
    markPhoneUnlocked(1000);
    expect(isPhoneUnlocked(1000 + 30_000)).toBe(true);
    touchPhone(1000 + 30_000);
    expect(isPhoneUnlocked(1000 + 30_000 + 50_000)).toBe(true);
  });

  it('locks again after being away too long', () => {
    markPhoneUnlocked(1000);
    expect(isPhoneUnlocked(1000 + LOCK_AFTER_MS + 1)).toBe(false);
  });

  it('touching while locked does not unlock it', () => {
    touchPhone(5000);
    expect(isPhoneUnlocked(5000)).toBe(false);
  });
});
