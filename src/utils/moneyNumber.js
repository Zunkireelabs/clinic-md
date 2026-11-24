// How a receipt, refund note, PAN bill or credit note number is printed (migration-021, CMD-115).
// The database holds the same rule in money_format_number(); money-number.test.js and the test:rls run the same cases so the two cannot drift.
//   receipt / refund note (one shared series):  2083/84-1189
//   PAN bill (per fiscal year):                  1189
//   credit note (per fiscal year):               CN-14
export function formatMoneyNumber(kind, fiscalYear, seq) {
  const n = Number(seq);
  if (!Number.isInteger(n) || n < 1) throw new Error(`Invalid sequence number: ${seq}`);
  switch (kind) {
    case 'receipt':
    case 'refund_note':
      return `${fiscalYear}-${n}`;
    case 'pan_bill':
      return String(n);
    case 'credit_note':
      return `CN-${n}`;
    default:
      throw new Error(`Unknown document kind: ${kind}`);
  }
}

// The word printed on a copy: the first print is the Original, every later one a Copy.
export function printLabel(printCount) {
  return Number(printCount) > 0 ? 'Copy' : 'Original';
}

// The kind of document a collect issues, by the organisation's billing mode.
export function documentKindFor(panBillMode) {
  return panBillMode ? 'pan_bill' : 'receipt';
}
