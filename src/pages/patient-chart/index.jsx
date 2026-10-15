import React, { useState, useEffect, useCallback, useMemo } from 'react';
import { useLocation, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import Icon from '../../components/AppIcon';
import Button from '../../components/ui/Button';
import AppShell from '../../components/ui/AppShell';
import { useShellHeader } from '../../hooks/useShellHeader';
import { useCollectPayment } from '../../hooks/useCollectPayment';
import { AIAssistantPanel } from '../../components/ui/AIAssistant';
import { useAuth } from '../../contexts/AuthContext';
import { CONSULTATION_ENABLED } from '../../lib/featureFlags';
import { getPatientRecord, updateCustomerFields } from '../../services/api';
import { localISO } from '../../utils/patientDirectory';
import { buildActivity, latestClinicalSummary, careTeam, treatmentCounts, unpaidVisitCount, mediaGroups, mediaCount } from '../../utils/patientRecord';
import RecordHeader from './RecordHeader';
import SummaryStrip from './SummaryStrip';
import { SummaryCard, ActivityFeed, DetailsRail } from './OverviewTab';
import { VisitsTab, ClinicalNotesTab, MediaTab, BillingTab } from './RecordTabs';

// The full-page chart lives in the app shell. Kept as its own component so the embedded chart (shown inside the consultation page,
// which already has the shell) doesn't subscribe to notifications a second time.
const PatientChartShell = ({ orgSlug, children }) => {
  const { header, assistantOpen } = useShellHeader(orgSlug);
  return (
    <AppShell variant="page" header={header} aside={<AIAssistantPanel />} asideOpen={assistantOpen}>
      {children}
    </AppShell>
  );
};

const TAB_KEYS = ['overview', 'visits', 'notes', 'media', 'billing'];

const PatientChart = ({ embedded = false, customerId: customerIdProp }) => {
  const navigate = useNavigate();
  const location = useLocation();
  const { customerId: customerIdParam, orgSlug: urlOrgSlug } = useParams();
  const customerId = customerIdProp || customerIdParam;
  const { profile } = useAuth();
  const orgSlug = urlOrgSlug || profile?.organizations?.slug;
  const role = profile?.role;
  const readOnly = role === 'admin_viewer';
  const canEdit = !readOnly;

  // The tab lives in the URL on the full page; the embedded chart (inside the consultation page) keeps it locally.
  const [searchParams, setSearchParams] = useSearchParams();
  const [localTab, setLocalTab] = useState('overview');
  const urlTab = searchParams.get('tab');
  const tab = embedded ? localTab : (TAB_KEYS.includes(urlTab) ? urlTab : 'overview');
  const focusConsultation = embedded ? null : searchParams.get('consultation');
  const setTab = (t, extra = {}) => {
    if (embedded) { setLocalTab(t); return; }
    const next = new URLSearchParams(searchParams);
    if (t === 'overview') next.delete('tab'); else next.set('tab', t);
    next.delete('consultation');
    Object.entries(extra).forEach(([k, v]) => next.set(k, v));
    setSearchParams(next, { replace: true });
  };

  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [toast, setToast] = useState(null);
  const notify = (msg, type = 'success') => { setToast({ msg, type }); setTimeout(() => setToast(null), 3000); };

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setLoading(true);
    setError(null);
    const res = await getPatientRecord(customerId);
    if (res.error) setError(res.error.message || 'Could not load this patient.');
    else setData(res.data);
    setLoading(false);
  }, [customerId]);
  useEffect(() => { load(); }, [load]);

  const customer = data?.customer;
  const patient = data?.patient;
  const bookings = data?.bookings || [];
  const consultations = data?.consultations || [];
  const today = localISO(new Date());

  const derived = useMemo(() => {
    if (!data) return null;
    const treatmentNotes = (data.treatmentNotes || []).map((n) => ({ id: n.id, bookingId: n.booking_id, note: n.note, createdAt: n.created_at, dentistName: n.dentist?.name || 'Unknown' }));
    const completed = bookings.filter((b) => b.status === 'Completed').length;
    return {
      treatmentNotes,
      activity: buildActivity({ bookings, consultations, today }),
      summary: latestClinicalSummary(consultations),
      team: careTeam(bookings),
      treatments: treatmentCounts(bookings),
      unpaidVisits: unpaidVisitCount(bookings),
      media: mediaGroups(consultations),
      mediaN: mediaCount(consultations),
      stats: {
        avgSpend: completed ? Math.round((patient.lifetime / completed) * 100) / 100 : 0,
        totalDiscount: bookings.reduce((s, b) => s + Number(b.discount_amount || 0), 0),
      },
      visitRows: bookings.filter((b) => !(String(b.date).slice(0, 10) > today && b.status === 'Cancelled')),
    };
  }, [data, bookings, consultations, patient, today]);

  const { startCollect, modal: payModal, error: payError } = useCollectPayment({ branchId: customer?.branch_id, onPaid: () => load(true) });

  const listState = location.state;
  const goBack = () => navigate(listState?.from || `/${orgSlug}/dashboard?view=customers`);
  const goTo = (id) => navigate(`/${orgSlug}/patients/${id}`, { state: listState, replace: true });
  const openBooking = (id) => navigate(`/${orgSlug}/dashboard?view=calendar&booking=${id}`);
  const newBooking = () => navigate(`/${orgSlug}/dashboard?view=new-booking`, { state: { prefill: { fullName: customer.full_name, phone: customer.phone, email: customer.email, gender: customer.gender } } });
  const openActivity = (i) => {
    if (i.kind === 'visit') openBooking(i.bookingId);
    else if (i.kind === 'payment') setTab('billing');
    else setTab('notes', { consultation: i.consultationId });
  };

  const save = async (fields, okMsg) => {
    const { data: row, error: err } = await updateCustomerFields(customerId, fields);
    if (err) { notify(err.message || 'Could not save.', 'error'); return false; }
    setData((d) => ({ ...d, customer: { ...d.customer, date_of_birth: row.date_of_birth, notes: row.notes } }));
    notify(okMsg);
    return true;
  };

  const nowBooking = bookings.find((b) => b.status === 'In-Progress' && String(b.date).slice(0, 10) === today);
  const canStart = CONSULTATION_ENABLED && !readOnly && !!nowBooking;
  const startConsultation = () => navigate(`/${orgSlug}/bookings/${nowBooking.id}/consultation`);

  const tabs = derived && [
    { key: 'overview', label: 'Overview' },
    { key: 'visits', label: 'Visits', n: derived.visitRows.length },
    { key: 'notes', label: 'Clinical notes', n: consultations.length },
    { key: 'media', label: 'X-rays & photos', n: derived.mediaN },
    { key: 'billing', label: 'Billing' },
  ];

  const content = (
    <div className={embedded ? '' : 'max-w-[1240px]'}>
      {loading && (
        <div className="p-16 text-center">
          <div className="animate-spin w-8 h-8 border-2 border-primary border-t-transparent rounded-full mx-auto mb-3" />
          <p className="text-text-secondary">Loading patient record…</p>
        </div>
      )}
      {!loading && error && (
        <div className="p-10 text-center border border-border rounded-xl bg-white">
          <Icon name="AlertCircle" size={36} className="text-error mx-auto mb-3" />
          <p className="text-text-secondary mb-4">{error}</p>
          <Button variant="primary" onClick={() => load()}>Retry</Button>
        </div>
      )}
      {!loading && data && derived && (
        <>
          <RecordHeader
            embedded={embedded} customer={customer} patient={patient} ids={listState?.ids} customerId={customerId}
            onBack={goBack} onGoTo={goTo} readOnly={readOnly} canDuplicates={!readOnly && ['admin', 'manager'].includes(role)}
            onNewBooking={newBooking} onCollect={() => startCollect(customer.phone)}
            onDuplicates={() => navigate(`/${orgSlug}/dashboard?view=customers&segment=duplicates`)}
          />
          {payError && <p role="alert" className="text-[13px] text-[#B45309] mt-2">{payError}</p>}
          <SummaryStrip patient={patient} bookings={bookings} today={today} unpaidVisits={derived.unpaidVisits} />

          <div className="flex gap-6 border-b border-border mt-7 mb-5 overflow-x-auto overflow-y-hidden" role="tablist" aria-label="Patient record">
            {tabs.map((t) => (
              <button key={t.key} type="button" role="tab" aria-selected={tab === t.key} onClick={() => setTab(t.key)}
                className={`h-10 flex items-center gap-1.5 text-[13px] font-medium relative whitespace-nowrap ${tab === t.key ? 'text-text-primary' : 'text-[#515152] hover:text-text-primary'}`}>
                {t.label}{t.n != null && <span className="text-[#8A8A90] tabular-nums">{t.n}</span>}
                {tab === t.key && <span className="absolute left-0 right-0 -bottom-px h-0.5 bg-text-primary rounded" />}
              </button>
            ))}
          </div>

          {tab === 'overview' && (
            <div className="grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_300px] gap-6 items-start">
              <div className="space-y-5 min-w-0">
                <SummaryCard summary={derived.summary} canStart={canStart} onFull={() => setTab('notes', { consultation: derived.summary.consultationId })} onStart={startConsultation} />
                <ActivityFeed items={derived.activity} today={today} onOpen={openActivity} />
              </div>
              <DetailsRail customer={customer} careTeam={derived.team} treatments={derived.treatments} canEdit={canEdit}
                onSaveDob={(dob) => save({ dateOfBirth: dob }, 'Date of birth saved')} onSaveNotes={(n) => save({ notes: n }, 'Notes saved')} />
            </div>
          )}
          {tab === 'visits' && <VisitsTab bookings={derived.visitRows} consultations={consultations} notes={derived.treatmentNotes} customerName={customer.full_name} onOpenBooking={embedded ? null : openBooking} />}
          {tab === 'notes' && <ClinicalNotesTab consultations={consultations} focusId={focusConsultation} customerName={customer.full_name} />}
          {tab === 'media' && <MediaTab groups={derived.media} />}
          {tab === 'billing' && <BillingTab patient={patient} bookings={derived.visitRows} stats={derived.stats} />}
        </>
      )}
      {payModal}
      {toast && (
        <div role="status" className={`fixed bottom-6 left-1/2 -translate-x-1/2 z-modal px-4 py-2 rounded-lg text-[13px] text-white shadow-lg ${toast.type === 'error' ? 'bg-[#B42318]' : 'bg-[#0E0D0C]'}`}>{toast.msg}</div>
      )}
    </div>
  );

  if (embedded) return <div className="p-4 sm:p-6">{content}</div>;
  return <PatientChartShell orgSlug={orgSlug}>{content}</PatientChartShell>;
};

export default PatientChart;
