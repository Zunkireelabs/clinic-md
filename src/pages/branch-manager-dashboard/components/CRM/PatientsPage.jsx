import React, { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { useNavigate, useSearchParams, useLocation } from 'react-router-dom';
import Icon from '../../../../components/AppIcon';
import { useCollectPayment } from '../../../../hooks/useCollectPayment';
import { getPatientsDirectory, fetchDuplicateCandidates } from '../../../../services/api';
import { useAuth } from '../../../../contexts/AuthContext';
import {
  SEGMENTS, SORTS, segmentCounts, matchesSearch, sortPatients, relativeDayLabel, monthsSince, initials, daysBetween, localISO,
} from '../../../../utils/patientDirectory';
import { formatPhoneDisplay } from '../../../../utils/phone';
import DuplicateCustomersPanel from './DuplicateCustomersPanel';
import Spotlight, { useSpotlight } from '../../../../components/ui/Spotlight';
import MoneyNoticeSpotlight from '../../../../components/ui/MoneyNoticeSpotlight';
import { pickSpotlight, canSeeMoneyNotice } from '../../../../utils/spotlightPriority';
import ConsultationSpotlightArt from '../../../../components/ui/spotlight/ConsultationSpotlightArt';
import { CONSULTATION_ENABLED } from '../../../../lib/featureFlags';
import PatientPanel, { InClinicTag } from './PatientPanel';

const PAGE_SIZE = 25;
const LAST_VISIT_OPTIONS = [
  { id: '30', label: 'In the last 30 days', test: (d) => d != null && d <= 30 },
  { id: '90', label: 'In the last 3 months', test: (d) => d != null && d <= 90 },
  { id: '180', label: 'In the last 6 months', test: (d) => d != null && d <= 180 },
  { id: 'old', label: 'More than 6 months ago', test: (d) => d != null && d > 180 },
  { id: 'never', label: 'Never visited', test: (d) => d == null },
];
const VIEWS = [
  { id: 'all', label: 'All patients' },
  { id: 'today', label: 'Today', dot: true },
  { id: 'upcoming', label: 'Upcoming' },
  { id: 'owes', label: 'Owes money' },
  { id: 'lapsed', label: 'Lapsed 6+ months' },
  { id: 'new', label: 'New this month' },
];
const EMPTY = {
  all: ['No patients yet', 'Patients are added automatically when bookings are made.'],
  today: ['No appointments today', 'Patients with a booking today appear here.'],
  upcoming: ['No upcoming appointments', 'Booked patients will show up here.'],
  owes: ['Nobody owes anything', 'Patients with an outstanding balance appear here.'],
  lapsed: ['No lapsed patients', 'Patients not seen for 6+ months with nothing booked appear here.'],
  new: ['No new patients this month', 'Patients registered this month appear here.'],
};

const npr = (n) => `NPR ${Number(n || 0).toLocaleString('en-IN')}`;

const Popover = ({ label, value, options, onChange, selectedLabel }) => {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const close = (e) => { if (!ref.current?.contains(e.target)) setOpen(false); };
    const esc = (e) => { if (e.key === 'Escape') { e.preventDefault(); setOpen(false); } };
    document.addEventListener('mousedown', close);
    document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('mousedown', close); document.removeEventListener('keydown', esc); };
  }, [open]);
  const set = value != null && value !== '';
  return (
    <div className="relative" ref={ref}>
      <span className={`h-7 rounded-full inline-flex items-center text-[12.5px] font-medium ${set ? 'border border-border bg-[#FAFAFB] text-text-primary' : 'border border-dashed border-[#D6D6DB] text-[#515152] hover:bg-[#FAFAFB]'}`}>
        <button type="button" onClick={() => setOpen((o) => !o)} className="h-full pl-2.5 pr-2.5 inline-flex items-center gap-[5px]" aria-haspopup="listbox" aria-expanded={open}>
          {!set && <Icon name="Plus" size={13} />}{set ? `${label}: ${selectedLabel}` : label}
        </button>
        {set && <button type="button" onClick={() => onChange('')} aria-label={`Clear ${label}`} className="h-full pr-2 -ml-1 text-[#8A8A90] hover:text-text-primary"><Icon name="X" size={12} /></button>}
      </span>
      {open && (
        <div role="listbox" className="absolute left-0 top-9 z-30 min-w-[200px] max-h-64 overflow-y-auto bg-white border border-border rounded-lg shadow-[0_8px_24px_rgba(14,13,12,.1)] py-1">
          {options.length === 0 && <p className="px-3 py-2 text-[12.5px] text-[#8A8A90]">Nothing to filter by yet</p>}
          {options.map((o) => (
            <button key={o.id} type="button" role="option" aria-selected={value === o.id} onClick={() => { onChange(o.id); setOpen(false); }}
              className={`w-full text-left px-3 py-1.5 text-[13px] hover:bg-[#FAFAFB] flex items-center justify-between gap-3 ${value === o.id ? 'font-medium' : ''}`}>
              <span className="truncate">{o.label}</span>{value === o.id && <Icon name="Check" size={13} />}
            </button>
          ))}
        </div>
      )}
    </div>
  );
};

const Menu = ({ trigger, children, align = 'right' }) => {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const close = (e) => { if (!ref.current?.contains(e.target)) setOpen(false); };
    const esc = (e) => { if (e.key === 'Escape') { e.preventDefault(); setOpen(false); } };
    document.addEventListener('mousedown', close);
    document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('mousedown', close); document.removeEventListener('keydown', esc); };
  }, [open]);
  return (
    <div className="relative" ref={ref}>
      {trigger(open, () => setOpen((o) => !o))}
      {open && <div className={`absolute ${align === 'right' ? 'right-0' : 'left-0'} top-9 z-30 min-w-[190px] bg-white border border-border rounded-lg shadow-[0_8px_24px_rgba(14,13,12,.1)] py-1`}>{children(() => setOpen(false))}</div>}
    </div>
  );
};

const WIDTHS = { name: 'sm:w-[34%]', next: 'w-[24%] hidden sm:table-cell', last: 'w-[22%] hidden md:table-cell', visits: 'w-[84px] hidden md:table-cell', balance: 'w-[150px] hidden sm:table-cell' };
const SortHeader = ({ id, label, sort, dir, onSort, right }) => (
  <th scope="col" aria-sort={sort === id ? (dir === 'asc' ? 'ascending' : 'descending') : 'none'} className={`h-[34px] text-[12px] ${WIDTHS[id] || ''} ${id === 'visits' ? 'pr-6' : id === 'balance' ? '' : 'pr-3'} font-medium whitespace-nowrap border-b border-border bg-white sticky top-0 z-10 ${right ? 'text-right' : 'text-left'} ${sort === id ? 'text-text-primary' : 'text-[#8A8A90]'}`}>
    <button type="button" onClick={() => onSort(id)} className={`inline-flex items-center gap-1 hover:text-text-primary ${right ? 'flex-row-reverse' : ''}`}>
      {label}{sort === id && <Icon name={dir === 'asc' ? 'ArrowUp' : 'ArrowDown'} size={12} />}
    </button>
  </th>
);

const csvEscape = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;

// readOnly is true for the Overall (all branches) view: no booking or payment actions there.
const PatientsPage = ({ branchId, readOnly: overallReadOnly = false }) => {
  const { profile } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const [searchParams, setSearchParams] = useSearchParams();
  const orgSlug = profile?.organizations?.slug;
  const role = profile?.role;
  const readOnly = overallReadOnly || role === 'admin_viewer';
  const isMgrUp = role === 'admin' || role === 'manager' || role === 'admin_viewer';
  const canExport = !readOnly && (role === 'admin' || role === 'manager');

  // `?view=customers&customer=<id>` (from the command palette) opens that patient's chart.
  const customerParam = searchParams.get('customer');
  useEffect(() => {
    if (customerParam && orgSlug) navigate(`/${orgSlug}/patients/${customerParam}`, { replace: true });
  }, [customerParam, orgSlug, navigate]);

  const segParam = searchParams.get('segment') === 'here' ? 'today' : searchParams.get('segment'); // 'here' was the old id
  const segment = SEGMENTS[segParam] ? segParam : 'all';
  const showDuplicates = searchParams.get('segment') === 'duplicates';
  const query = searchParams.get('q') || '';
  const page = Math.max(1, parseInt(searchParams.get('page') || '1', 10) || 1);
  const openId = searchParams.get('patient') || null;
  const explicitSort = SORTS[searchParams.get('sort')] && !SORTS[searchParams.get('sort')].hidden ? searchParams.get('sort') : null;
  // The Today view reads best in appointment order unless a sort was chosen explicitly.
  const sort = explicitSort || (segment === 'today' ? 'today' : 'next');
  const dir = searchParams.get('dir') === 'asc' || searchParams.get('dir') === 'desc' ? searchParams.get('dir') : SORTS[sort].dir;

  // Merge into the URL without adding history entries for typing/paging; opening a segment is a real navigation.
  // (react-router 6.0 has no functional setSearchParams, so merge into the latest params held in a ref.)
  const paramsRef = useRef(searchParams);
  paramsRef.current = searchParams;
  const patchParams = useCallback((patch, { push = false } = {}) => {
    const next = new URLSearchParams(paramsRef.current);
    for (const [k, v] of Object.entries(patch)) {
      if (v == null || v === '' || (k === 'segment' && v === 'all') || (k === 'page' && Number(v) === 1)) next.delete(k); else next.set(k, String(v));
    }
    paramsRef.current = next;
    setSearchParams(next, { replace: !push });
  }, [setSearchParams]);

  const spotlight = useSpotlight('ai-consultation-v1');
  const moneySpotlight = useSpotlight('money-model-v1');
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [filters, setFilters] = useState({ dentist: '', treatment: '', last: '', tier: '' });
  const [columns, setColumns] = useState({ visits: true, balance: true });
  const [dupCount, setDupCount] = useState(null);
  const [searchText, setSearchText] = useState(query);
  const searchRef = useRef(null);
  const today = localISO(new Date());

  const load = useCallback(async () => {
    if (!branchId) return;
    setLoading(true);
    setError(null);
    const result = await getPatientsDirectory({ branchId });
    if (result.error) setError(result.error.message || 'Failed to load patients.');
    else setData(result.data);
    setLoading(false);
  }, [branchId]);
  useEffect(() => { load(); }, [load]);

  // Possible-duplicates count (managers see only pairs touching their branch, same as the duplicates panel).
  useEffect(() => {
    if (!profile?.org_id || !isMgrUp) return;
    let off = false;
    fetchDuplicateCandidates(profile.org_id).then(({ data: rows }) => {
      if (off || !rows) return;
      setDupCount(role === 'admin' || role === 'admin_viewer' ? rows.length : rows.filter((c) => c.branch_id_a === profile.branch_id || c.branch_id_b === profile.branch_id).length);
    });
    return () => { off = true; };
  }, [profile?.org_id, profile?.branch_id, role, isMgrUp]);

  // Debounced search → URL
  useEffect(() => {
    const t = setTimeout(() => { if (searchText !== query) patchParams({ q: searchText, page: 1 }); }, 200);
    return () => clearTimeout(t);
  }, [searchText]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { setSearchText(query); }, [query]);

  // Focus search on open, and "/" focuses it from anywhere on the page.
  useEffect(() => { searchRef.current?.focus(); }, [loading]);
  useEffect(() => {
    const onKey = (e) => {
      const t = e.target;
      const typing = t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable);
      if (e.key === '/' && !typing && !e.metaKey && !e.ctrlKey && !e.altKey) { e.preventDefault(); searchRef.current?.focus(); }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);

  const patients = data?.patients;
  const counts = useMemo(() => (patients ? segmentCounts(patients) : null), [patients]);

  const treatmentOptions = useMemo(() => {
    const all = new Set();
    (patients || []).forEach((p) => p.treatments.forEach((t) => all.add(t)));
    return [...all].sort().map((t) => ({ id: t, label: t }));
  }, [patients]);
  const dentistOptions = useMemo(() => (data?.dentists || []).map((d) => ({ id: d.id, label: d.name })), [data]);
  const tierOptions = ['VIP', 'Regular', 'Occasional', 'At Risk', 'New', 'Standard'].map((t) => ({ id: t, label: t }));
  const labelOf = (opts, id) => opts.find((o) => o.id === id)?.label || id;

  const filtered = useMemo(() => {
    if (!patients) return [];
    const lastOpt = LAST_VISIT_OPTIONS.find((o) => o.id === filters.last);
    const list = patients.filter((p) => {
      if (!SEGMENTS[segment](p)) return false;
      if (!matchesSearch(p, query)) return false;
      if (filters.dentist && !p.dentistIds.includes(filters.dentist)) return false;
      if (filters.treatment && !p.treatments.includes(filters.treatment)) return false;
      if (filters.tier && p.tier !== filters.tier) return false;
      if (lastOpt && !lastOpt.test(p.lastVisit ? daysBetween(p.lastVisit.date, today) : null)) return false;
      return true;
    });
    return sortPatients(list, sort, dir);
  }, [patients, segment, query, filters, sort, dir, today]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const safePage = Math.min(page, pageCount);
  const rows = filtered.slice((safePage - 1) * PAGE_SIZE, safePage * PAGE_SIZE);
  const openPatient = useMemo(() => (openId && patients ? patients.find((p) => p.id === openId) || null : null), [openId, patients]);

  const setFilter = (k) => (v) => { setFilters((f) => ({ ...f, [k]: v })); patchParams({ page: 1 }); };
  const onSort = (id) => {
    if (id === sort) patchParams({ sort: id, dir: dir === 'asc' ? 'desc' : 'asc' });
    else patchParams({ sort: id, dir: SORTS[id].dir });
  };

  // ↑/↓ moves between patients while the panel is open.
  useEffect(() => {
    if (!openId) return undefined;
    const onKey = (e) => {
      if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
      const t = e.target;
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable)) return;
      const i = filtered.findIndex((p) => p.id === openId);
      if (i < 0) return;
      const nxt = filtered[i + (e.key === 'ArrowDown' ? 1 : -1)];
      if (!nxt) return;
      e.preventDefault();
      patchParams({ patient: nxt.id, page: Math.floor(filtered.indexOf(nxt) / PAGE_SIZE) + 1 });
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [openId, filtered, patchParams]);

  // ── Navigation helpers ────────────────────────────────────────────────────────
  const listUrl = `${location.pathname}${location.search}`;
  const openChart = (p) => navigate(`/${orgSlug}/patients/${p.id}`, { state: { from: listUrl, ids: filtered.map((x) => x.id) } });
  const bookFor = (p) => navigate('?view=new-booking', {
    state: { prefill: { fullName: p.fullName, phone: p.phone, email: p.email, gender: p.gender } },
  });

  const { startCollect, modal: payModal, error: payError } = useCollectPayment({ branchId, onPaid: load });

  const exportCsv = () => {
    const header = ['Name', 'Phone', 'Email', 'Next appointment', 'Last visit', 'Visits', 'Balance', 'Paid to date'];
    const lines = [header.join(',')];
    filtered.forEach((p) => lines.push([
      p.fullName, p.phone, p.email,
      p.nextAppointment ? `${p.nextAppointment.date} ${p.nextAppointment.time}` : '',
      p.lastVisit?.date || '', p.visits, p.balance, p.lifetime,
    ].map(csvEscape).join(',')));
    const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `patients-${segment}-${today}.csv`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  };

  // ── Render ─────────────────────────────────────────────────────────────────────
  const total = counts?.all;
  const anyFilter = query || Object.values(filters).some(Boolean);

  const header = (
    <div className="flex items-center justify-between gap-3 flex-wrap">
      <h1 className="text-[22px] font-semibold tracking-[-0.45px] flex items-baseline gap-2.5 text-text-primary">
        Patients{total != null && <span className="text-[15px] text-[#8A8A90] font-medium tracking-normal tabular-nums">{total}</span>}
      </h1>
      <div className="flex gap-2">
        {canExport && (
          <button type="button" onClick={exportCsv} disabled={!filtered.length} className="h-8 px-3 rounded-md border border-border bg-white text-[13px] font-medium inline-flex items-center gap-1.5 hover:bg-[#FAFAFB] disabled:opacity-50">
            <Icon name="Download" size={14} />Export
          </button>
        )}
        {!readOnly && (
          <button type="button" onClick={() => navigate('?view=new-booking')} className="h-8 px-3 rounded-md bg-primary text-white text-[13px] font-medium inline-flex items-center gap-1.5 shadow-[0_1px_2px_rgba(123,47,247,.25),inset_0_1px_0_rgba(255,255,255,.15)] hover:opacity-95">
            <Icon name="Plus" size={15} />New booking
          </button>
        )}
      </div>
    </div>
  );

  const views = (
    <div className="flex items-center gap-[22px] border-b border-border mt-5 overflow-x-auto overflow-y-hidden lg:overflow-visible" role="tablist" aria-label="Patient views">
      {VIEWS.map((v) => {
        const on = !showDuplicates && segment === v.id;
        return (
          <button key={v.id} type="button" role="tab" aria-selected={on} onClick={() => patchParams({ segment: v.id, page: 1 }, { push: true })}
            className={`h-[38px] flex items-center gap-[7px] text-[13px] font-medium relative whitespace-nowrap ${on ? 'text-text-primary' : 'text-[#515152] hover:text-text-primary'}`}>
            {v.dot && <span className="w-1.5 h-1.5 rounded-full bg-[#1F9D6C]" />}
            {v.label}{counts && <span className="text-[#8A8A90] tabular-nums">{counts[v.id]}</span>}
            {on && <span className="absolute left-0 right-0 -bottom-px h-0.5 bg-text-primary rounded" />}
          </button>
        );
      })}
      {isMgrUp && dupCount > 0 && (
        <button type="button" onClick={() => patchParams({ segment: 'duplicates', page: 1, patient: '' }, { push: true })}
          className={`ml-auto h-[38px] flex items-center gap-1.5 text-[12.5px] whitespace-nowrap hover:text-text-primary ${showDuplicates ? 'text-text-primary font-medium' : 'text-[#8A8A90]'}`}>
          <Icon name="GitMerge" size={14} />{dupCount} possible duplicate{dupCount === 1 ? '' : 's'}
        </button>
      )}
    </div>
  );

  // One banner per page: the AI-consultation announcement, only where consultations can actually be started.
  const liveNow = patients?.find((p) => p.inProgressId);
  // Earliest Confirmed booking still to come today, across all patients.
  const laterToday = patients?.filter((p) => p.laterTodayConfirmedId).sort((a, b) => a.laterTodayTime.localeCompare(b.laterTodayTime))[0];
  const spotlightPrimary = liveNow
    ? { label: `Start with ${liveNow.fullName.split(' ')[0]}`, onClick: () => navigate(`/${orgSlug}/bookings/${liveNow.inProgressId}/consultation`) }
    : laterToday
      ? { label: 'Try it on today\'s first visit', onClick: () => navigate(`?view=calendar&booking=${laterToday.laterTodayConfirmedId}`) }
      : { label: 'Open today\'s calendar', onClick: () => navigate('?view=calendar') };
  // One banner at a time: the AI-consultation announcement wins; the money notice waits until it is dismissed.
  const showAi = CONSULTATION_ENABLED && !readOnly && spotlight.visible && !!patients && !showDuplicates;
  const showMoney = canSeeMoneyNotice(role) && moneySpotlight.visible && !!patients && !showDuplicates;
  const winner = pickSpotlight([{ id: 'ai', show: showAi }, { id: 'money', show: showMoney }]);
  const banner = winner && (
    <div className="mt-5">
      {winner === 'ai' ? (
        <Spotlight
          id="ai-consultation-v1"
          eyebrow="New · AI consultation notes"
          title="Talk to your patient. The notes write themselves."
          body="Record the visit, get a transcript and a clinical summary in seconds, then review and save to the chart."
          primary={spotlightPrimary}
          art={<ConsultationSpotlightArt />}
          onDismiss={spotlight.dismiss}
        />
      ) : (
        <MoneyNoticeSpotlight onSee={() => navigate('?view=outstanding&section=needs-closing')} onDismiss={moneySpotlight.dismiss} />
      )}
    </div>
  );

  if (showDuplicates) {
    return (
      <div className="h-full lg:overflow-y-auto content-scroll px-3 sm:px-4 md:px-6 lg:px-10 pt-6 pb-6">
        {header}{views}
        <div className="pt-4"><DuplicateCustomersPanel orgId={profile?.org_id} role={role} branchId={profile?.branch_id} /></div>
      </div>
    );
  }

  const toolbar = (
    <div className="flex items-center gap-2 py-3.5 flex-wrap">
      <div className="relative w-full sm:w-[340px]">
        <Icon name="Search" size={15} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-[#8A8A90]" />
        <input ref={searchRef} value={searchText} onChange={(e) => setSearchText(e.target.value)} placeholder="Search name, phone or email"
          aria-label="Search patients" className="w-full h-[34px] pl-8 pr-8 border border-border rounded-[7px] text-[13px] bg-white placeholder:text-[#8A8A90] focus:outline-none focus:border-[#cfcfd4] focus:shadow-[0_0_0_3px_rgba(14,13,12,.05)]" />
        <kbd className="absolute right-2 top-1/2 -translate-y-1/2 text-[10.5px] font-medium text-[#8A8A90] border border-border rounded px-[5px] py-px bg-white">/</kbd>
      </div>
      <Popover label="Dentist" value={filters.dentist} options={dentistOptions} onChange={setFilter('dentist')} selectedLabel={labelOf(dentistOptions, filters.dentist)} />
      <Popover label="Treatment" value={filters.treatment} options={treatmentOptions} onChange={setFilter('treatment')} selectedLabel={filters.treatment} />
      <Popover label="Last visit" value={filters.last} options={LAST_VISIT_OPTIONS} onChange={setFilter('last')} selectedLabel={labelOf(LAST_VISIT_OPTIONS, filters.last)} />
      {isMgrUp && <Popover label="Tier" value={filters.tier} options={tierOptions} onChange={setFilter('tier')} selectedLabel={filters.tier} />}
      <div className="ml-auto flex items-center gap-2">
        <Menu trigger={(open, toggle) => (
          <button type="button" onClick={toggle} aria-haspopup="menu" aria-expanded={open} className="h-7 px-2 rounded-md text-[12.5px] text-[#515152] inline-flex items-center gap-1.5 hover:bg-[#FAFAFB]">
            Sort <b className="text-text-primary font-medium">{SORTS[sort].label}</b><Icon name="ChevronDown" size={13} />
          </button>)}>
          {(close) => Object.entries(SORTS).filter(([, s]) => !s.hidden).map(([id, s]) => (
            <button key={id} type="button" onClick={() => { patchParams({ sort: id, dir: '' }); close(); }} className={`w-full text-left px-3 py-1.5 text-[13px] hover:bg-[#FAFAFB] flex justify-between ${sort === id ? 'font-medium' : ''}`}>
              {s.label}{sort === id && <Icon name="Check" size={13} />}
            </button>))}
        </Menu>
        <Menu trigger={(open, toggle) => (
          <button type="button" onClick={toggle} aria-label="Columns" aria-haspopup="menu" aria-expanded={open} className="w-[30px] h-[30px] border border-border rounded-md grid place-items-center text-[#515152] hover:bg-[#FAFAFB]"><Icon name="Columns" size={15} /></button>)}>
          {() => ['visits', 'balance'].map((k) => (
            <label key={k} className="flex items-center gap-2 px-3 py-1.5 text-[13px] hover:bg-[#FAFAFB] cursor-pointer capitalize">
              <input type="checkbox" checked={columns[k]} onChange={() => setColumns((c) => ({ ...c, [k]: !c[k] }))} />{k}
            </label>))}
        </Menu>
      </div>
    </div>
  );

  const th = { sort, dir, onSort };
  const lapsedMonths = (p) => monthsSince(p.lastVisit.date, today);

  let body;
  if (loading) {
    body = Array.from({ length: 8 }).map((_, i) => (
      <tr key={i}><td colSpan={6} className="h-14 border-b border-[#F1F1F3]"><div className="h-8 rounded bg-[#F1F1F3] animate-pulse" /></td></tr>
    ));
  } else if (error) {
    body = null;
  } else {
    body = rows.map((p) => {
      const selected = p.id === openId;
      const appt = segment === 'today' && p.todayAppt ? p.todayAppt : p.nextAppointment; // the Today view shows today's appointment
      return (
        <tr key={p.id} onClick={() => patchParams({ patient: p.id })} tabIndex={0} aria-selected={selected}
          onKeyDown={(e) => { if (e.key === 'Enter') patchParams({ patient: p.id }); }}
          className={`group cursor-pointer ${selected ? 'bg-[#F6F2FF]' : 'hover:bg-[#FAFAFB]'}`}>
          <td className="h-14 border-b border-[#F1F1F3] pr-3">
            <div className="flex items-center gap-3">
              <div className="w-8 h-8 rounded-full bg-[#F1F1F3] text-[#4A4A4F] text-[11.5px] font-semibold grid place-items-center flex-shrink-0">{initials(p.fullName)}</div>
              <div className="min-w-0">
                <div className="font-medium text-[13.5px] tracking-[-0.1px] flex items-center gap-2 text-text-primary">
                  <span className="truncate">{p.fullName}</span>
                  {p.inClinic ? <InClinicTag /> : p.isFirstTime && <span className="h-5 rounded-full px-[7px] text-[11.5px] font-medium inline-flex items-center bg-[#F3EEFF] text-[#5B21B6]">New</span>}
                </div>
                <div className="text-[12.5px] text-[#8A8A90] mt-0.5 truncate">{formatPhoneDisplay(p.phone)}</div>
                <div className="sm:hidden text-[12.5px] text-[#515152] truncate">{appt ? `${relativeDayLabel(appt.date, today)} · ${appt.time}` : 'No appointment'}</div>
              </div>
            </div>
          </td>
          <td className="h-14 border-b border-[#F1F1F3] pr-3 hidden sm:table-cell">
            {appt ? (
              <>
                <div className="text-[13px] font-medium">{relativeDayLabel(appt.date, today)}</div>
                <div className="text-[12.5px] text-[#515152] truncate max-w-[220px]">{appt.time}{appt.treatment ? ` · ${appt.treatment}` : ''}</div>
              </>
            ) : <span className="text-[13px] text-[#B4B4BA]">No appointment</span>}
          </td>
          <td className="h-14 border-b border-[#F1F1F3] pr-3 hidden md:table-cell">
            {p.lastVisit ? (
              <>
                <div className="text-[13px] font-medium">
                  <span className={p.lapsed ? 'text-[#B45309]' : ''}>{relativeDayLabel(p.lastVisit.date, today)}</span>
                  {p.lapsed && <span className="text-[#515152] font-normal"> · {lapsedMonths(p)} months</span>}
                </div>
                <div className="text-[12.5px] text-[#8A8A90] truncate max-w-[220px]">{p.lastVisit.treatment}</div>
              </>
            ) : <span className="text-[13px] text-[#B4B4BA]">No visits yet</span>}
          </td>
          {columns.visits && <td className="h-14 border-b border-[#F1F1F3] pr-6 text-right text-[13px] tabular-nums hidden md:table-cell">{p.visits}</td>}
          {columns.balance && (
            <td className="h-14 border-b border-[#F1F1F3] text-right whitespace-nowrap hidden sm:table-cell">
              {p.balance > 0 ? (
                <span className="inline-flex items-center gap-[7px] text-[13px] font-medium text-text-primary tabular-nums"><i className="w-1.5 h-1.5 rounded-full bg-[#F59E0B]" />{npr(p.balance)}</span>
              ) : <span className="text-[#B4B4BA]">—</span>}
            </td>
          )}
          <td className="h-14 border-b border-[#F1F1F3] w-[88px] pl-3">
            <div className="flex gap-1.5 justify-end items-center text-[#8A8A90] opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100 transition-opacity">
              {!readOnly && <button type="button" onClick={(e) => { e.stopPropagation(); bookFor(p); }} className="h-[26px] px-[9px] border border-border rounded-md bg-white text-[12px] font-medium text-text-primary hover:bg-[#FAFAFB]">Book</button>}
              <Icon name="ChevronRight" size={15} />
            </div>
          </td>
        </tr>
      );
    });
  }

  const [emptyTitle, emptyHint] = anyFilter ? ['No patients match', 'Try a different search or clear a filter.'] : EMPTY[segment];

  return (
    <div className="h-full flex flex-col px-3 sm:px-4 md:px-6 lg:px-10 pt-5 lg:pt-7 overflow-hidden">
      {header}
      {banner}
      {views}
      {toolbar}
      {payError && <p role="alert" className="text-[13px] text-[#B45309] pb-2">{payError}</p>}
      <div className="flex-1 min-h-0 overflow-y-auto content-scroll">
        {error ? (
          <div className="border border-error/20 bg-error/5 rounded-lg p-4 flex items-center gap-3 text-[13px] text-error">
            <Icon name="AlertCircle" size={16} />{error}
            <button type="button" onClick={load} className="ml-auto underline font-medium">Retry</button>
          </div>
        ) : (
          <table className="w-full border-collapse table-fixed">
            <thead>
              <tr>
                <SortHeader id="name" label="Patient" {...th} />
                <SortHeader id="next" label={segment === 'today' ? "Today's appointment" : "Next appointment"} {...th} />
                <SortHeader id="last" label="Last visit" {...th} />
                {columns.visits && <SortHeader id="visits" label="Visits" right {...th} />}
                {columns.balance && <SortHeader id="balance" label="Balance" right {...th} />}
                <th className="h-[34px] w-[88px] border-b border-border bg-white sticky top-0" />
              </tr>
            </thead>
            <tbody>{body}</tbody>
          </table>
        )}
        {!loading && !error && filtered.length === 0 && (
          <div className="text-center py-16">
            <Icon name="Users" size={28} className="text-[#B4B4BA] mx-auto mb-3" />
            <p className="text-[14px] font-medium text-text-primary">{emptyTitle}</p>
            <p className="text-[13px] text-[#8A8A90] mt-1">{emptyHint}</p>
          </div>
        )}
      </div>
      <div className="flex items-center justify-between h-[52px] flex-shrink-0 text-[12.5px] text-[#8A8A90] border-t border-border">
        <span className="tabular-nums">{filtered.length === 0 ? '0 patients' : `${(safePage - 1) * PAGE_SIZE + 1}–${Math.min(safePage * PAGE_SIZE, filtered.length)} of ${filtered.length}`}</span>
        <div className="flex gap-1.5">
          <button type="button" aria-label="Previous page" disabled={safePage <= 1} onClick={() => patchParams({ page: safePage - 1 })} className="w-7 h-7 border border-border rounded-md grid place-items-center disabled:opacity-40 hover:bg-[#FAFAFB]"><Icon name="ChevronLeft" size={14} /></button>
          <button type="button" aria-label="Next page" disabled={safePage >= pageCount} onClick={() => patchParams({ page: safePage + 1 })} className="w-7 h-7 border border-border rounded-md grid place-items-center disabled:opacity-40 hover:bg-[#FAFAFB]"><Icon name="ChevronRight" size={14} /></button>
        </div>
      </div>

      <PatientPanel
        patient={openPatient}
        today={today}
        readOnly={readOnly}
        canCollect={!readOnly}
        onClose={() => patchParams({ patient: '' })}
        onNewBooking={() => openPatient && bookFor(openPatient)}
        onCollect={() => openPatient && startCollect(openPatient.phone)}
        onOpenChart={() => openPatient && openChart(openPatient)}
        onClosed={load}
        onOpenBooking={(bookingId) => navigate(`?view=calendar&booking=${bookingId}`)}
        onOpenConsultation={(bookingId) => navigate(`/${orgSlug}/bookings/${bookingId}/consultation`)}
      />

      {payModal}
    </div>
  );
};

export default PatientsPage;
