import { describe, it, expect } from 'vitest';
import { isMobileDevice, deviceLabel, recorderDevices } from './remoteDevices';

const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1';
const ANDROID = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36';
const MAC = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15';

describe('isMobileDevice', () => {
  it('recognises phones', () => {
    expect(isMobileDevice(IPHONE, 5)).toBe(true);
    expect(isMobileDevice(ANDROID, 5)).toBe(true);
  });

  it('treats a desktop Mac as not mobile, but an iPad posing as a Mac as mobile', () => {
    expect(isMobileDevice(MAC, 0)).toBe(false);
    expect(isMobileDevice(MAC, 5)).toBe(true);
  });
});

describe('deviceLabel', () => {
  it('names the device', () => {
    expect(deviceLabel(IPHONE)).toBe('iPhone');
    expect(deviceLabel(ANDROID)).toBe('Android phone');
    expect(deviceLabel(MAC)).toBe('phone');
  });
});

describe('recorderDevices', () => {
  const devices = [
    { deviceId: 'me', isMobile: false },
    { deviceId: 'p1', isMobile: true, label: 'iPhone' },
    { deviceId: 'd2', isMobile: false },
  ];
  it('lists only other phones/tablets', () => {
    expect(recorderDevices(devices, 'me').map((d) => d.deviceId)).toEqual(['p1']);
  });

  it('excludes this device even if it is a phone', () => {
    expect(recorderDevices(devices, 'p1')).toEqual([]);
  });
});
