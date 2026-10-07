import React, { useState, useEffect, useCallback } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import Icon from '../../components/AppIcon';
import Button from '../../components/ui/Button';
import StaffSidebar from '../../components/ui/StaffSidebar';
import StaffTopBar from '../../components/ui/StaffTopBar';
import { AIAssistantPanel } from '../../components/ui/AIAssistant';
import VisitRecord from './VisitRecord';
import { parseSummarySections } from '../../utils/summarySections';
import { useAuth } from '../../contexts/AuthContext';
import { fetchCustomerProfile, fetchConsultationsForCustomer } from '../../services/api';

const TIER_STYLE = {
  VIP: 'bg-amber-100 text-amber-800',
  Regular: 'bg-primary/10 text-primary',
  Occasional: 'bg-blue-100 text-blue-700',
  'At Risk': 'bg-error/10 text-error',
  New: 'bg-success/10 text-success',
  Standard: 'bg-gray-100 text-text-secondary',
};

const STATUS_STYLE = {
  Pending: 'bg-amber-100 text-amber-800',
  Confirmed: 'bg-blue-100 text-blue-700',
  'In-Progress': 'bg-primary/10 text-primary',
  Completed: 'bg-success/10 text-success',
  Cancelled: 'bg-error/10 text-error',
  'No Show': 'bg-gray-100 text-gray-600',
};

const npr = (n) => `NPR ${Number(n || 0).toLocaleString('en-IN')}`;
const fmt = (d, opts = { day: 'numeric', month: 'short', year: 'numeric' }) =>
  d ? new Date(d).toLocaleDateString('en-GB', opts) : '—';

const TABS = [
  { key: 'visits', label: 'Visits & treatments', icon: 'Stethoscope' },
  { key: 'notes', label: 'Doctor notes', icon: 'FileText' },
  { key: 'billing', label: 'Billing', icon: 'CreditCard' },
];

const PatientChart = () => {
  const navigate = useNavigate();
  const { customerId, orgSlug: urlOrgSlug } = useParams();
  const { profile } = useAuth();
  const userRole = profile?.role || 'staff';
  const orgSlug = urlOrgSlug || profile?.organizations?.slug;

  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [tab, setTab] = useState('visits');
  const [consultations, setConsultations] = useState({});
  const [closed, setClosed] = useState({});

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [res, cons] = await Promise.all([fetchCustomerProfile(customerId), fetchConsultationsForCustomer(customerId)]);
    const byBooking = {};
    (cons.data || []).forEach((row) => { if (!byBooking[row.booking_id]) byBooking[row.booking_id] = row; });
    setConsultations(byBooking);
    if (res.error) setError(res.error.message || 'Could not load this patient.');
    else setData(res.data);
    setLoading(false);
  }, [customerId]);

  useEffect(() => { load(); }, [load]);

  const goBack = () => navigate(`/${orgSlug}/dashboard?view=customers`);
  const c = data?.customer;
  const s = data?.stats;
  const history = data?.history || [];
  const notes = data?.treatmentNotes || [];
  const initial = (c?.fullName || '?').trim().charAt(0).toUpperCase();
  const unpaid = history.filter((b) => b.paymentStatus !== 'paid' && !['Cancelled', 'No Show'].includes(b.status));
  const unpaidTotal = unpaid.reduce((sum, b) => sum + b.finalAmount, 0);

  const countBy = (list, key) => Object.entries(list.reduce((m, b) => ({ ...m, [b[key]]: (m[b[key]] || 0) + 1 }), {})).sort((x, y) => y[1] - x[1]);
  const doctorsSeen = countBy(history.filter((b) => b.dentistName && b.dentistName !== 'Unassigned'), 'dentistName');
  const treatmentsDone = countBy(history, 'treatmentName');
  const consRows = Object.values(consultations);
  const imageCount = consRows.reduce((n, r) => n + (r.xray_image_paths || []).length + (r.photo_image_paths || []).length, 0);
  const latestWithDx = history.map((b) => ({ b, c: consultations[b.id] })).find(({ c: r }) => r && (r.final_summary || r.doctor_notes));
  const latestDx = latestWithDx ? (parseSummarySections(latestWithDx.c.final_summary || '').diagnosis || latestWithDx.c.doctor_notes || latestWithDx.c.final_summary) : '';
  const preview = (b) => {
    const r = consultations[b.id];
    const txt = r && (parseSummarySections(r.final_summary || r.preliminary_summary || '').diagnosis || r.doctor_notes || r.final_summary || r.preliminary_summary);
    return txt ? txt.split('\n')[0] : '';
  };

  return (
    <div className="min-h-screen bg-surface-sidebar">
      <StaffSidebar userRole={userRole} onCollapseChange={setSidebarCollapsed} />
      <div className={`${sidebarCollapsed ? 'lg:ml-16' : 'lg:ml-60'} pb-20 lg:pb-0 transition-all duration-200`}>
        <StaffTopBar orgSlug={orgSlug} />
        <div className="relative z-0 flex gap-2 sm:gap-3 min-h-[calc(100vh-52px)]">
          <main
            className="flex-1 min-w-0 px-3 sm:px-4 md:px-6 lg:px-8 py-3 sm:py-4 bg-surface-dim"
            style={{ borderRadius: '16px 0 0 0', borderLeft: '1px solid #e5e7eb', borderTop: '1px solid #e5e7eb' }}
          >
            <button onClick={goBack} className="inline-flex items-center gap-1.5 text-sm text-text-secondary hover:text-text-primary mb-3">
              <Icon name="ArrowLeft" size={16} /> All patients
            </button>
            <div>
              {loading && (
                <div className="p-16 text-center">
                  <div className="animate-spin w-8 h-8 border-2 border-primary border-t-transparent rounded-full mx-auto mb-3" />
                  <p className="text-text-secondary">Loading patient record…</p>
                </div>
              )}

              {!loading && error && (
                <div className="p-10 text-center bg-white rounded-xl border border-gray-200">
                  <Icon name="AlertCircle" size={40} className="text-error mx-auto mb-3" />
                  <p className="text-text-secondary mb-4">{error}</p>
                  <Button variant="primary" onClick={load}>Retry</Button>
                </div>
              )}

              {!loading && data && (
                <div className="grid grid-cols-1 lg:grid-cols-[300px_1fr] gap-4 items-start">
                  {/* Patient summary — stays in view while scrolling the record */}
                  <aside className="lg:sticky lg:top-4 space-y-3">
                    <div className="bg-white rounded-xl border border-gray-200 shadow-sm p-5">
                      <div className="flex items-center gap-3">
                        <div className="w-14 h-14 rounded-full bg-primary/10 text-primary flex items-center justify-center text-xl font-heading font-heading-semibold shrink-0">
                          {initial}
                        </div>
                        <div className="min-w-0">
                          <h1 className="font-heading font-heading-semibold text-lg text-text-primary leading-tight break-words">{c.fullName}</h1>
                          <span className={`inline-flex mt-1 px-2 py-0.5 rounded-full text-xs font-caption ${TIER_STYLE[s.loyaltyTier] || TIER_STYLE.Standard}`}>
                            {s.loyaltyTier}
                          </span>
                        </div>
                      </div>
                      <dl className="mt-4 space-y-2.5 text-sm">
                        <div className="flex items-center gap-2 text-text-primary"><Icon name="Phone" size={14} className="text-text-tertiary" />{c.phone || '—'}</div>
                        {c.email && <div className="flex items-center gap-2 text-text-primary break-all"><Icon name="Mail" size={14} className="text-text-tertiary shrink-0" />{c.email}</div>}
                        <div className="flex items-center gap-2 text-text-secondary"><Icon name="Calendar" size={14} className="text-text-tertiary" />Patient since {fmt(c.createdAt, { month: 'short', year: 'numeric' })}</div>
                      </dl>
                      <div className="grid grid-cols-2 gap-2 mt-4">
                        <div className="rounded-lg bg-surface-dim border border-gray-100 p-2.5">
                          <p className="text-[11px] text-text-tertiary">Visits</p>
                          <p className="font-heading font-heading-semibold text-text-primary">{s.completedVisits}<span className="text-xs text-text-secondary font-normal"> / {s.totalVisits}</span></p>
                        </div>
                        <div className="rounded-lg bg-surface-dim border border-gray-100 p-2.5">
                          <p className="text-[11px] text-text-tertiary">Last visit</p>
                          <p className="font-heading font-heading-semibold text-text-primary text-sm">{fmt(s.lastVisitDate, { day: 'numeric', month: 'short' })}</p>
                        </div>
                      </div>
                      {s.mostBookedTreatment && (
                        <p className="mt-3 text-xs text-text-secondary flex items-center gap-1.5">
                          <Icon name="Heart" size={12} className="text-primary" /> Most frequent: <span className="font-medium text-text-primary">{s.mostBookedTreatment}</span>
                        </p>
                      )}
                    </div>

                    <div className="bg-white rounded-xl border border-gray-200 shadow-sm p-4">
                      <h3 className="text-xs uppercase tracking-wider text-text-tertiary mb-2 flex items-center gap-1.5"><Icon name="Users" size={12} /> Care team</h3>
                      {doctorsSeen.length === 0 ? <p className="text-sm text-text-tertiary italic">No doctor assigned yet</p> : (
                        <ul className="space-y-1.5">
                          {doctorsSeen.map(([n, k]) => (
                            <li key={n} className="flex items-center justify-between text-sm"><span className="text-text-primary truncate">{n}</span><span className="text-xs text-text-tertiary shrink-0">{k} visit{k > 1 ? 's' : ''}</span></li>
                          ))}
                        </ul>
                      )}
                    </div>
                    <div className="bg-white rounded-xl border border-gray-200 shadow-sm p-4">
                      <h3 className="text-xs uppercase tracking-wider text-text-tertiary mb-2 flex items-center gap-1.5"><Icon name="Stethoscope" size={12} /> Treatments</h3>
                      <ul className="space-y-1.5">
                        {treatmentsDone.map(([n, k]) => (
                          <li key={n} className="flex items-center justify-between text-sm"><span className="text-text-primary truncate">{n}</span><span className="text-xs text-text-tertiary shrink-0">×{k}</span></li>
                        ))}
                      </ul>
                    </div>

                    {c.notes && (
                      <div className="bg-amber-50 border border-amber-200 rounded-xl p-4">
                        <p className="text-xs font-medium text-amber-700 mb-1 flex items-center gap-1.5"><Icon name="AlertTriangle" size={12} /> Alerts / notes</p>
                        <p className="text-sm text-amber-900 whitespace-pre-wrap">{c.notes}</p>
                      </div>
                    )}
                    {unpaid.length > 0 && (
                      <div className="bg-error/5 border border-error/20 rounded-xl p-4 text-sm text-error flex items-center gap-2">
                        <Icon name="AlertCircle" size={16} /> {unpaid.length} unpaid · {npr(unpaidTotal)}
                      </div>
                    )}
                  </aside>

                  {/* Clinical record */}
                  <section className="min-w-0">
                    <div className="flex gap-1 border-b border-gray-200 mb-4 overflow-x-auto">
                      {TABS.map((t) => (
                        <button
                          key={t.key}
                          onClick={() => setTab(t.key)}
                          className={`flex items-center gap-2 px-4 py-2.5 text-sm font-medium border-b-2 -mb-px whitespace-nowrap ${
                            tab === t.key ? 'border-primary text-primary' : 'border-transparent text-text-secondary hover:text-text-primary'
                          }`}
                        >
                          <Icon name={t.icon} size={16} /> {t.label}
                          {t.key === 'visits' && <span className="text-xs text-text-tertiary">({history.length})</span>}
                          {t.key === 'notes' && <span className="text-xs text-text-tertiary">({notes.length})</span>}
                        </button>
                      ))}
                    </div>

                    {tab === 'visits' && (
                      <div className="grid grid-cols-2 xl:grid-cols-4 gap-3 mb-5">
                        <div className="col-span-2 rounded-xl bg-primary/5 border border-primary/20 p-4">
                          <p className="text-[11px] uppercase tracking-wider text-primary mb-1 flex items-center gap-1.5"><Icon name="ClipboardCheck" size={12} /> Latest diagnosis / notes</p>
                          <p className={`text-sm line-clamp-3 ${latestDx ? 'text-text-primary' : 'text-text-tertiary italic'}`}>{latestDx || 'Nothing recorded yet'}</p>
                        </div>
                        <div className="rounded-xl bg-white border border-gray-200 p-4">
                          <p className="text-[11px] uppercase tracking-wider text-text-tertiary mb-1">Consultations</p>
                          <p className="font-heading font-heading-semibold text-2xl text-text-primary">{consRows.length}</p>
                        </div>
                        <div className="rounded-xl bg-white border border-gray-200 p-4">
                          <p className="text-[11px] uppercase tracking-wider text-text-tertiary mb-1">X-rays & photos</p>
                          <p className="font-heading font-heading-semibold text-2xl text-text-primary">{imageCount}</p>
                        </div>
                      </div>
                    )}

                    {tab === 'visits' && (
                      history.length === 0 ? (
                        <p className="text-center text-text-tertiary py-12">No visits yet.</p>
                      ) : (
                        <ol className="relative border-l-2 border-gray-200 ml-2 space-y-4">
                          {history.map((b) => {
                            const open = !closed[b.id];
                            return (
                              <li key={b.id} className="pl-5 relative">
                                <span className={`absolute -left-[7px] top-5 w-3 h-3 rounded-full border-2 border-white ${b.status === 'Completed' ? 'bg-success' : 'bg-gray-300'}`} />
                                <div className="bg-white rounded-xl border border-gray-200 shadow-sm">
                                  <button
                                    type="button"
                                    onClick={() => setClosed((m) => ({ ...m, [b.id]: open }))}
                                    className="w-full text-left p-4 flex items-center gap-3"
                                    aria-expanded={open}
                                  >
                                    <div className="min-w-0 flex-1">
                                      <p className="text-xs text-text-tertiary">{fmt(b.date, { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' })}</p>
                                      <p className="font-heading font-heading-semibold text-text-primary truncate">{b.treatmentName}</p>
                                      <p className="text-xs text-text-secondary mt-0.5 flex items-center gap-1"><Icon name="Stethoscope" size={12} />{b.dentistName} · {b.bookingNumber}</p>
                                      {!open && (
                                        <p className={`text-sm mt-2 line-clamp-1 ${preview(b) ? 'text-text-primary' : 'text-text-tertiary italic'}`}>
                                          {preview(b) || 'No consultation recorded'}
                                        </p>
                                      )}
                                    </div>
                                    <span className={`px-2 py-0.5 rounded text-xs font-caption ${STATUS_STYLE[b.status] || 'bg-gray-100 text-text-secondary'}`}>{b.status}</span>
                                    <Icon name="ChevronDown" size={18} className={`text-text-tertiary transition-transform ${open ? 'rotate-180' : ''}`} />
                                  </button>
                                  {open && (
                                    <VisitRecord
                                      visit={b}
                                      consultation={consultations[b.id]}
                                      customerName={c.fullName}
                                      notes={notes.filter((n) => n.bookingId === b.id)}
                                    />
                                  )}
                                </div>
                              </li>
                            );
                          })}
                        </ol>
                      )
                    )}

                    {tab === 'notes' && (
                      notes.length === 0 ? (
                        <p className="text-center text-text-tertiary py-12">No doctor notes recorded.</p>
                      ) : (
                        <div className="space-y-3">
                          {notes.map((n) => (
                            <div key={n.id} className="bg-white rounded-xl border border-gray-200 shadow-sm p-4">
                              <p className="text-sm text-text-primary whitespace-pre-wrap">{n.note}</p>
                              <p className="text-xs text-text-secondary mt-2">{n.dentistName} · {fmt(n.createdAt)}</p>
                            </div>
                          ))}
                        </div>
                      )
                    )}

                    {tab === 'billing' && (
                      <div className="space-y-4">
                        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                          {[
                            ['Total paid', npr(s.totalRevenue)],
                            ['Average spend', npr(s.avgSpend)],
                            ['Discounts', npr(s.totalDiscount)],
                            ['Outstanding', npr(unpaidTotal)],
                          ].map(([k, v]) => (
                            <div key={k} className="bg-white rounded-xl border border-gray-200 p-3">
                              <p className="text-xs text-text-tertiary">{k}</p>
                              <p className="font-heading font-heading-semibold text-text-primary">{v}</p>
                            </div>
                          ))}
                        </div>
                        <div className="bg-white rounded-xl border border-gray-200 divide-y divide-gray-100">
                          {history.map((b) => (
                            <div key={b.id} className="flex items-center justify-between gap-3 p-3 text-sm">
                              <div className="min-w-0">
                                <p className="text-text-primary truncate">{b.treatmentName}</p>
                                <p className="text-xs text-text-tertiary">{fmt(b.date)} · {b.bookingNumber}</p>
                              </div>
                              <div className="text-right shrink-0">
                                <p className="font-medium text-text-primary">{npr(b.finalAmount)}</p>
                                <p className={`text-xs ${b.paymentStatus === 'paid' ? 'text-success' : 'text-error'}`}>{b.paymentStatus === 'paid' ? 'Paid' : 'Unpaid'}</p>
                              </div>
                            </div>
                          ))}
                        </div>
                      </div>
                    )}
                  </section>
                </div>
              )}
            </div>
          </main>
          <AIAssistantPanel />
        </div>
      </div>
    </div>
  );
};

export default PatientChart;
