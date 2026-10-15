// Pure derivation for the Patients list: one row per patient with next/last appointment, in-clinic flag, balance, etc.
// "Today"/"now" come from the caller's local clock (never toISOString(), which shifts the date in Nepal).

import { summarizeMoney, roundMoney } from './bookingMoney';

const LAPSED_DAYS = 180;
const VISIT_STATUSES = ['Completed', 'In-Progress'];
const UPCOMING_STATUSES = ['Pending', 'Confirmed'];

const pad = (n) => String(n).padStart(2, '0');
export const localISO = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const localHM = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}`;
const hm = (t) => (t ? String(t).slice(0, 5) : '');
const dayNumber = (iso) => {
  const [y, m, d] = String(iso).slice(0, 10).split('-').map(Number);
  return Math.round(Date.UTC(y, m - 1, d) / 86400000);
};
export const daysBetween = (fromISO, toISO) => dayNumber(toISO) - dayNumber(fromISO);

export const loyaltyTier = ({ completed, revenue, lastDate, today }) => {
  let tier = 'Standard';
  if (completed === 0) tier = 'New';
  else if (completed >= 8 && revenue >= 25000) tier = 'VIP';
  else if (completed >= 4 && revenue >= 10000) tier = 'Regular';
  else if (completed >= 1 && completed <= 3) tier = 'Occasional';
  if (completed >= 2 && lastDate && tier !== 'VIP' && tier !== 'New' && daysBetween(lastDate, today) > 60) tier = 'At Risk';
  return tier;
};

/**
 * @param {{customers: object[], bookings: object[], now?: Date}} input
 *  customers: { id, full_name, phone, email, gender, created_at }
 *  bookings:  { customer_id, status, payment_status, final_amount, date, start_time, treatment_name_snapshot, dentist_id, payments?: [{amount}] }
 */
export function buildPatientDirectory({ customers = [], bookings = [], now = new Date() }) {
  const today = localISO(now);
  const nowHM = localHM(now);
  const monthPrefix = today.slice(0, 7);

  const byCustomer = new Map();
  for (const b of bookings) {
    if (!b.customer_id) continue;
    if (!byCustomer.has(b.customer_id)) byCustomer.set(b.customer_id, []);
    byCustomer.get(b.customer_id).push(b);
  }

  return customers.map((c) => {
    const list = byCustomer.get(c.id) || [];
    let lastVisit = null;
    let next = null;
    let inClinic = false;
    let todayTime = null;
    let todayAppt = null;
    let inProgressId = null;
    let laterTodayConfirmedId = null;
    let laterTodayTime = '';
    let visits = 0;
    let completed = 0;
    const dentistIds = new Set();
    const treatments = new Set();

    for (const b of list) {
      const date = String(b.date).slice(0, 10);
      const time = hm(b.start_time);
      if (VISIT_STATUSES.includes(b.status)) {
        visits += 1;
        if (b.status === 'Completed') completed += 1;
        if (date <= today && (!lastVisit || date > lastVisit.date)) {
          lastVisit = { date, treatment: b.treatment_name_snapshot || '' };
        }
        if (b.status === 'In-Progress' && date === today) { inClinic = true; inProgressId = b.id || null; }
      }
      if (UPCOMING_STATUSES.includes(b.status) && (date > today || (date === today && time > nowHM))) {
        if (b.status === 'Confirmed' && date === today && (!laterTodayConfirmedId || time < laterTodayTime)) { laterTodayConfirmedId = b.id || null; laterTodayTime = time; }
        if (!next || date < next.date || (date === next.date && time < next.time)) {
          next = { date, time, treatment: b.treatment_name_snapshot || '' };
        }
      }
      if (date === today && !['Cancelled', 'No Show'].includes(b.status) && (todayTime == null || time < todayTime)) {
        todayTime = time || '00:00';
        todayAppt = { date, time, treatment: b.treatment_name_snapshot || '' };
      }
      if (b.dentist_id) dentistIds.add(b.dentist_id);
      if (b.treatment_name_snapshot) treatments.add(b.treatment_name_snapshot);
    }

    // All the money comes from bookingMoney: due (owed for rendered visits), upcoming, deposit, credit, unclosed past bookings.
    const money = summarizeMoney(list, { today });
    const lifetime = money.paidToDate;
    const lapsed = !!lastVisit && !next && daysBetween(lastVisit.date, today) > LAPSED_DAYS;
    return {
      id: c.id,
      fullName: c.full_name || '',
      phone: c.phone || '',
      email: c.email || '',
      gender: c.gender || '',
      createdAt: c.created_at,
      lastVisit,
      nextAppointment: next,
      inClinic,
      todayAppt,
      inProgressId, // booking id of today's In-Progress booking (for the Consultation route)
      laterTodayTime: laterTodayConfirmedId ? laterTodayTime : null,
      laterTodayConfirmedId, // earliest Confirmed booking later today (Spotlight deep link)
      todayTime, // earliest start time of a non-cancelled booking today, else null
      visits,
      isFirstTime: visits === 0, // no Completed/In-Progress visit yet
      balance: money.due, // owed now (rendered visits only)
      unpaidVisits: money.dueCount,
      // Owed on bookings of CLOSED (locked) days: still debt, but it can't be collected from here until the closed-day policy is decided.
      lockedDue: roundMoney(money.dueBookings.filter((b) => b.is_locked).reduce((x, b) => x + b.money.due, 0)),
      upcoming: money.upcoming, // scheduled, not yet owed
      deposit: money.deposit,
      credit: money.credit,
      unclosed: money.unclosed.map((b) => ({ id: b.id, date: String(b.date).slice(0, 10), treatment: b.treatment_name_snapshot || '', status: b.status, atStake: b.money.atStake, isLocked: !!b.is_locked })),
      staleInProgress: money.staleInProgress.map((b) => ({ id: b.id, date: String(b.date).slice(0, 10), treatment: b.treatment_name_snapshot || '', status: b.status, isLocked: !!b.is_locked })),
      lifetime, // paid to date: every payment recorded
      isNew: String(c.created_at || '').slice(0, 7) === monthPrefix, // created_at is UTC; month granularity is close enough
      lapsed,
      tier: loyaltyTier({ completed, revenue: lifetime, lastDate: lastVisit?.date, today }),
      dentistIds: [...dentistIds],
      treatments: [...treatments],
    };
  });
}

// ── Views, search, sort ──────────────────────────────────────────────────────────────────────

export const SEGMENTS = {
  all: () => true,
  today: (p) => p.todayTime != null,
  upcoming: (p) => !!p.nextAppointment,
  owes: (p) => p.balance > 0,
  lapsed: (p) => p.lapsed,
  new: (p) => p.isNew,
};

export const segmentCounts = (patients) => Object.fromEntries(
  Object.entries(SEGMENTS).map(([k, fn]) => [k, patients.filter(fn).length])
);

/** Digits only, minus a leading Nepal country code or trunk zero, so "+977 984-12" and "98412" both match. */
export const phoneSearchDigits = (value) => {
  let d = String(value || '').replace(/\D/g, '');
  if (d.startsWith('977') && d.length > 3) d = d.slice(3);
  return d.replace(/^0+/, '');
};

export function matchesSearch(p, query) {
  const q = String(query || '').trim().toLowerCase();
  if (!q) return true;
  if ((p.fullName || '').toLowerCase().includes(q)) return true;
  if ((p.email || '').toLowerCase().includes(q)) return true;
  const qd = phoneSearchDigits(q);
  // Only treat the query as a phone number when it is mostly digits/punctuation.
  if (qd && /^[\d\s+\-()]+$/.test(q)) return phoneSearchDigits(p.phone).includes(qd);
  return false;
}

const cmpStr = (a, b) => String(a).localeCompare(String(b), undefined, { sensitivity: 'base' });
const cmpDate = (a, b, dir) => {
  // Missing values always sort last regardless of direction.
  if (!a && !b) return 0;
  if (!a) return 1;
  if (!b) return -1;
  return dir * (a < b ? -1 : a > b ? 1 : 0);
};

export const SORTS = {
  today: { label: 'Appointment time', dir: 'asc', hidden: true },
  next: { label: 'Next appointment', dir: 'asc' },
  last: { label: 'Last visit', dir: 'desc' },
  name: { label: 'Name', dir: 'asc' },
  balance: { label: 'Balance', dir: 'desc' },
  visits: { label: 'Visits', dir: 'desc' },
};

export function sortPatients(list, key = 'next', dir = SORTS[key]?.dir || 'asc') {
  const d = dir === 'asc' ? 1 : -1;
  const out = [...list];
  out.sort((a, b) => {
    let r = 0;
    if (key === 'next') r = cmpDate(a.nextAppointment && `${a.nextAppointment.date} ${a.nextAppointment.time}`, b.nextAppointment && `${b.nextAppointment.date} ${b.nextAppointment.time}`, d);
    else if (key === 'today') r = cmpDate(a.todayTime, b.todayTime, d);
    else if (key === 'last') r = cmpDate(a.lastVisit?.date, b.lastVisit?.date, d);
    else if (key === 'balance') r = d * (a.balance - b.balance);
    else if (key === 'visits') r = d * (a.visits - b.visits);
    else r = d * cmpStr(a.fullName, b.fullName);
    return r || cmpStr(a.fullName, b.fullName);
  });
  return out;
}

// ── Labels ───────────────────────────────────────────────────────────────────────────────────

const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const parts = (iso) => { const [y, m, d] = iso.slice(0, 10).split('-').map(Number); return { y, m, d, dow: new Date(y, m - 1, d).getDay() }; };

/** "Today" / "Tomorrow" / "Yesterday" / "Fri 16 Oct" (future, within a year) / "2 Oct" (past; adds the year when not this year). */
export function relativeDayLabel(iso, todayISO) {
  if (!iso) return '';
  const diff = daysBetween(todayISO, iso);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Tomorrow';
  if (diff === -1) return 'Yesterday';
  const p = parts(iso);
  const yr = p.y !== Number(todayISO.slice(0, 4)) ? ` ${p.y}` : '';
  return diff > 0 ? `${DOW[p.dow]} ${p.d} ${MON[p.m - 1]}${yr}` : `${p.d} ${MON[p.m - 1]}${yr}`;
}

export const monthsSince = (iso, todayISO) => Math.floor(daysBetween(iso, todayISO) / 30.44);

export const shortDate = (iso) => { const p = parts(iso); return `${p.d} ${MON[p.m - 1]}`; };
export const monthYear = (isoOrTs) => { if (!isoOrTs) return ''; const p = parts(String(isoOrTs).slice(0, 10)); return `${MON[p.m - 1]} ${p.y}`; };
export const dayBlock = (iso) => { const p = parts(iso); return { dow: DOW[p.dow].toUpperCase(), day: p.d }; };

export const initials = (name) => {
  const w = String(name || '').trim().split(/\s+/).filter(Boolean);
  if (!w.length) return '?';
  return ((w[0][0] || '') + (w.length > 1 ? w[w.length - 1][0] : '')).toUpperCase();
};
