import { describe, it, expect } from 'vitest';
import { pickSpotlight, canSeeMoneyNotice } from './spotlightPriority';

describe('pickSpotlight', () => {
  it('the first eligible candidate wins', () => {
    expect(pickSpotlight([{ id: 'ai', show: true }, { id: 'money', show: true }])).toBe('ai');
  });
  it('the next one shows once the first is dismissed or ineligible', () => {
    expect(pickSpotlight([{ id: 'ai', show: false }, { id: 'money', show: true }])).toBe('money');
  });
  it('null when nothing qualifies', () => { expect(pickSpotlight([{ id: 'a', show: false }])).toBeNull(); });
});

describe('canSeeMoneyNotice', () => {
  it('admin and manager only', () => {
    expect(['admin', 'manager'].every(canSeeMoneyNotice)).toBe(true);
    expect(['staff', 'admin_viewer', undefined].some(canSeeMoneyNotice)).toBe(false);
  });
});
