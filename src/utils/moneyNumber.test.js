import { describe, it, expect } from 'vitest';
import { formatMoneyNumber, printLabel, documentKindFor } from './moneyNumber';

// The same cases are asserted in SQL by supabase/tests/tenant-isolation.sql (section 3j) against money_format_number().
describe('formatMoneyNumber', () => {
  it('receipt mode: receipts and refund notes share the series, printed with the fiscal year', () => {
    expect(formatMoneyNumber('receipt', '2083/84', 1189)).toBe('2083/84-1189');
    expect(formatMoneyNumber('refund_note', '2083/84', 7)).toBe('2083/84-7');
    expect(formatMoneyNumber('receipt', '2083/84', 1)).toBe('2083/84-1');
  });
  it('PAN bill mode: bills are the bare number, credit notes are CN-n', () => {
    expect(formatMoneyNumber('pan_bill', '2083/84', 1189)).toBe('1189');
    expect(formatMoneyNumber('credit_note', '2083/84', 14)).toBe('CN-14');
  });
  it('the number does not carry the fiscal year in PAN mode, so the same text repeats each year (the database keys on year + seq)', () => {
    expect(formatMoneyNumber('pan_bill', '2083/84', 5)).toBe(formatMoneyNumber('pan_bill', '2084/85', 5));
  });
  it('refuses a bad sequence or kind', () => {
    expect(() => formatMoneyNumber('receipt', '2083/84', 0)).toThrow();
    expect(() => formatMoneyNumber('receipt', '2083/84', 1.5)).toThrow();
    expect(() => formatMoneyNumber('invoice', '2083/84', 1)).toThrow();
  });
});

describe('printLabel and documentKindFor', () => {
  it('first print is Original, later prints are Copy', () => {
    expect(printLabel(0)).toBe('Original');
    expect(printLabel(1)).toBe('Copy');
    expect(printLabel(7)).toBe('Copy');
  });
  it('PAN bill mode issues a bill, otherwise a receipt', () => {
    expect(documentKindFor(true)).toBe('pan_bill');
    expect(documentKindFor(false)).toBe('receipt');
  });
});
