import { describe, it, expect } from 'vitest';
import { urlBase64ToUint8Array, subscriptionToRow, pushStatus } from './pushHelpers';

describe('urlBase64ToUint8Array', () => {
  it('decodes url-safe base64 without padding', () => {
    // "hello?>" -> aGVsbG8_Pg in url-safe base64
    expect(Array.from(urlBase64ToUint8Array('aGVsbG8_Pg'))).toEqual([104, 101, 108, 108, 111, 63, 62]);
  });
});

describe('subscriptionToRow', () => {
  it('flattens a push subscription for storage', () => {
    const sub = { toJSON: () => ({ endpoint: 'https://push.test/abc', keys: { p256dh: 'P', auth: 'A' } }) };
    expect(subscriptionToRow(sub)).toEqual({ endpoint: 'https://push.test/abc', p256dh: 'P', auth: 'A' });
  });
});

describe('pushStatus', () => {
  const base = { hasPushManager: true, hasNotification: true, permission: 'default', isIos: false, isStandalone: false };
  it('reports the browser permission when push is available', () => {
    expect(pushStatus(base)).toBe('default');
    expect(pushStatus({ ...base, permission: 'granted' })).toBe('granted');
    expect(pushStatus({ ...base, permission: 'denied' })).toBe('denied');
  });

  it('asks iPhone users to install the app first', () => {
    expect(pushStatus({ ...base, isIos: true, isStandalone: false })).toBe('needs-install');
    expect(pushStatus({ ...base, isIos: true, isStandalone: true })).toBe('default');
  });

  it('flags browsers without push', () => {
    expect(pushStatus({ ...base, hasPushManager: false })).toBe('unsupported');
  });
});
