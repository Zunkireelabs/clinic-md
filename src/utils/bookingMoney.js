// The one money model. Everything that shows "owed", "upcoming", "deposit" or "credit" goes through here.
// Amounts are handled as integer paisa internally (Math.round(x * 100)) and converted back to rupees on the way out, so
// 0.1 + 0.2 and 3 × 33.33 behave. `paid` is always the sum of payments[] — never derived from payment_status.
//
//   void       Cancelled / No Show      nothing owed; any payment is credit
//   rendered   In-Progress / Completed  due = price − paid; overpayment is credit
//   scheduled  Pending / Confirmed, date ≥ today   nothing owed; upcoming = price − paid; paid so far is a deposit
//   (In-Progress with date < today is also flagged `stale`: unfinished, but its money is already in due)
//   unclosed   Pending / Confirmed, date < today   nothing owed, but the visit was never closed: flagged with the amount at stake

const toPaisa = (x) => Math.round(Number(x || 0) * 100);
const toRupees = (p) => p / 100;

export const isVoidStatus = (s) => s === 'Cancelled' || s === 'No Show';
export const isRenderedStatus = (s) => s === 'In-Progress' || s === 'Completed';
const isScheduledStatus = (s) => s === 'Pending' || s === 'Confirmed';

/** Sum of recorded payments in paisa. */
export const paidPaisa = (b) => (b?.payments || []).reduce((s, p) => s + toPaisa(p.amount), 0);

/**
 * @param {{ id?, date, status, final_amount, payments? }} b
 * @param {{ today: string }} ctx  the clinic's local YYYY-MM-DD (from the local-date helpers, never toISOString)
 * @returns {{ kind: 'void'|'rendered'|'scheduled'|'unclosed'|'unknown', price, paid, due, upcoming, deposit, credit, atStake }}
 */
export function classifyBooking(b, { today }) {
  const price = toPaisa(b?.final_amount);
  const paid = paidPaisa(b);
  const out = { kind: 'unknown', due: 0, upcoming: 0, deposit: 0, credit: 0, atStake: 0 };
  if (isVoidStatus(b?.status)) {
    out.kind = 'void';
    out.credit = paid;
  } else if (isRenderedStatus(b?.status)) {
    out.kind = 'rendered';
    out.stale = b?.status === 'In-Progress' && String(b?.date || '').slice(0, 10) < today; // visit never finished
    out.due = Math.max(price - paid, 0);
    out.credit = Math.max(paid - price, 0);
  } else if (isScheduledStatus(b?.status)) {
    const date = String(b?.date || '').slice(0, 10);
    if (date && date < today) {
      out.kind = 'unclosed';
      out.atStake = Math.max(price - paid, 0);
    } else {
      out.kind = 'scheduled';
      out.upcoming = Math.max(price - paid, 0);
      out.deposit = Math.min(paid, price);
      out.credit = Math.max(paid - price, 0);
    }
  }
  return {
    kind: out.kind,
    price: toRupees(price),
    paid: toRupees(paid),
    due: toRupees(out.due),
    upcoming: toRupees(out.upcoming),
    deposit: toRupees(out.deposit),
    credit: toRupees(out.credit),
    atStake: toRupees(out.atStake),
    stale: !!out.stale,
  };
}

/** Rupees for display/tests from a paisa-exact sum. */
const sum = (rows, key) => toRupees(rows.reduce((s, r) => s + toPaisa(r.m[key]), 0));

/**
 * @param {object[]} bookings
 * @param {{ today: string, excludeBookingId?: string }} ctx
 */
export function summarizeMoney(bookings = [], { today, excludeBookingId } = {}) {
  const rows = (bookings || [])
    .filter((b) => !(excludeBookingId && b.id === excludeBookingId))
    .map((b) => ({ b, m: classifyBooking(b, { today }) }));
  const dueRows = rows.filter((r) => r.m.due > 0);
  const upcomingRows = rows.filter((r) => r.m.upcoming > 0);
  const unclosedRows = rows.filter((r) => r.m.kind === 'unclosed');
  return {
    due: sum(dueRows, 'due'),
    dueCount: dueRows.length,
    dueBookings: dueRows.map((r) => ({ ...r.b, money: r.m })),
    upcoming: sum(upcomingRows, 'upcoming'),
    upcomingCount: upcomingRows.length,
    deposit: sum(rows, 'deposit'),
    credit: sum(rows, 'credit'),
    paidToDate: toRupees(rows.reduce((s, r) => s + paidPaisa(r.b), 0)),
    unclosed: unclosedRows.map((r) => ({ ...r.b, money: r.m })),
    unclosedAtStake: sum(unclosedRows, 'atStake'),
    // In-Progress visits from a previous day: unfinished, but the money is already counted in `due`, so they carry no at-stake amount.
    staleInProgress: rows.filter((r) => r.m.stale).map((r) => ({ ...r.b, money: r.m })),
  };
}

/** Rounds a rupee amount for display so float residue never shows (e.g. 0.30000000000000004). */
export const roundMoney = (x) => toRupees(toPaisa(x));
