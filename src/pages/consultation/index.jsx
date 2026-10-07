import React, { useState, useEffect, useCallback, useRef } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { QRCodeSVG } from 'qrcode.react';
import Icon from '../../components/AppIcon';
import Button from '../../components/ui/Button';
import StaffSidebar from '../../components/ui/StaffSidebar';
import StaffTopBar from '../../components/ui/StaffTopBar';
import { AIAssistantPanel } from '../../components/ui/AIAssistant';
import ImageAnalysisCard from './components/ImageAnalysisCard';
import PhoneHandoff from './components/PhoneHandoff';
import PhoneCodeBanner from './components/PhoneCodeBanner';
import PatientEarlierVisits from './components/PatientEarlierVisits';
import PatientDetailsGrid from './components/PatientDetailsGrid';
import useLastVisit from '../../hooks/useLastVisit';
import { formatVisitDate } from '../../utils/visitDates';
import ConsultationDetail from './components/ConsultationDetail';
import useAudioRecorder from '../../hooks/useAudioRecorder';
import useConsultationRemote from '../../hooks/useConsultationRemote';
import useDoctorPhoneLink from '../../hooks/useDoctorPhoneLink';
import { recorderDevices } from '../../utils/remoteDevices';
import { useAuth } from '../../contexts/AuthContext';
import {
  fetchBookingById,
  getOrCreateConsultation,
  notifyDoctorPhone,
  createConsultationDraft,
  createPhonePairing,
  updateConsultationColumns,
  subscribeToConsultation,
  saveConsultation,
  uploadConsultationFile,
  getConsultationFileUrl,
  transcribeConsultationAudio,
  summarizeConsultation,
} from '../../services/api';
import { generateConsultationPdf, exportConsultationJson } from '../../utils/consultationReport';
import { EMPTY_FORM, formFromRow, columnsForChanges, allColumns, mergeRemote, changedKeys } from '../../utils/consultationSync';

const todayIso = () => new Date().toLocaleDateString('en-CA');

const hasContent = (f) =>
  [f.transcript, f.preliminarySummary, f.xrayAnalysis, f.photoAnalysis, f.additionalNotes, f.doctorNotes, f.finalSummary]
    .some((v) => v && v.trim());

const formatTimer = (s) => `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;

const Card = ({ title, icon, children, action }) => (
  <div className="bg-white rounded-xl border border-gray-200 shadow-sm p-5">
    <div className="flex items-center justify-between mb-4">
      <div className="flex items-center gap-2">
        <Icon name={icon} size={18} className="text-primary" />
        <h2 className="font-heading font-heading-semibold text-base text-text-primary">{title}</h2>
      </div>
      {action}
    </div>
    {children}
  </div>
);

const TextArea = ({ value, onChange, rows = 6, placeholder, disabled }) => (
  <textarea
    value={value}
    onChange={(e) => onChange(e.target.value)}
    rows={rows}
    disabled={disabled}
    placeholder={placeholder}
    className="w-full text-sm rounded-md border-gray-200 focus:border-primary focus:ring-primary"
  />
);

const SavedRecording = ({ path, index }) => {
  const [url, setUrl] = useState(null);
  useEffect(() => {
    let cancelled = false;
    getConsultationFileUrl('audio', path).then(({ url: u }) => { if (!cancelled) setUrl(u); });
    return () => { cancelled = true; };
  }, [path]);
  return (
    <div className="flex items-center gap-3">
      <span className="text-xs text-text-tertiary w-20 shrink-0">Recording {index + 1}</span>
      {url ? <audio controls src={url} className="h-9 flex-1" /> : <span className="text-xs text-text-tertiary">Loading…</span>}
    </div>
  );
};

// Props are used when this page is shown inside the Doctor phone page.
const ConsultationPage = ({ bookingIdProp, forcePhoneView = false, onDone, onSwitch } = {}) => {
  const navigate = useNavigate();
  const { bookingId: paramBookingId, orgSlug: urlOrgSlug } = useParams();
  const bookingId = bookingIdProp || paramBookingId;
  const [searchParams] = useSearchParams();
  // ?view=phone (the QR code link) shows a compact capture screen: record + photos only.
  const phoneView = forcePhoneView || searchParams.get('view') === 'phone';
  const { profile } = useAuth();
  const userRole = profile?.role || 'staff';
  const orgSlug = urlOrgSlug || profile?.organizations?.slug;

  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [booking, setBooking] = useState(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);

  const [form, setForm] = useState(EMPTY_FORM);
  const [consultationId, setConsultationId] = useState(null);
  const [dbStatus, setDbStatus] = useState(null);
  const [sessionDate, setSessionDate] = useState(todayIso());
  const [phase, setPhase] = useState('active'); // 'active' | 'review'
  const [processing, setProcessing] = useState(null); // 'transcribing' | 'summarizing' | 'final'
  const [failedRecording, setFailedRecording] = useState(null);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(null);
  const lastVisit = useLastVisit(booking?.customer_id, booking?.id);
  const [attendedBy, setAttendedBy] = useState([]); // doctors who attended this patient (kept by the database)
  const [phoneDetail, setPhoneDetail] = useState(null); // an earlier visit opened on the phone
  const [lastSavedJson, setLastSavedJson] = useState(null); // form as of the last Save; null = never saved
  const [saving, setSaving] = useState(false);
  const [syncState, setSyncState] = useState('synced'); // 'synced' | 'saving' | 'error'
  const [showPhone, setShowPhone] = useState(false);
  const [loaded, setLoaded] = useState(false);

  const recorder = useAudioRecorder();
  const formRef = useRef(form);
  formRef.current = form;
  // The form as of the last time it matched the database row. Anything that
  // differs from it is an unsaved local edit (or, for merges, tells us which
  // fields the other device may overwrite).
  const syncedRef = useRef(EMPTY_FORM);

  const patchForm = useCallback((patch) => setForm((f) => ({ ...f, ...patch })), []);

  // Remote recording: the computer can start/stop a phone that has this same
  // consultation open, and shows what the phone is doing.
  const [remoteActivity, setRemoteActivity] = useState({ xray: null, photo: null }); // what the other device is uploading/analysing
  const [localBusy, setLocalBusy] = useState({ xray: null, photo: null });
  const [received, setReceived] = useState(null); // short "new item from phone" message
  const onXrayBusy = useCallback((phase) => setLocalBusy((b) => (b.xray === phase ? b : { ...b, xray: phase })), []);
  const onPhotoBusy = useCallback((phase) => setLocalBusy((b) => (b.photo === phase ? b : { ...b, photo: phase })), []);
  const closeHandoff = useCallback(() => setShowPhone(false), []);
  const [remote, setRemote] = useState(null); // { from, state: 'recording'|'paused'|'processing'|'idle', seconds }
  const [pendingRemoteStart, setPendingRemoteStart] = useState(false);
  const commandRef = useRef(null);
  const { deviceId, devices, sendCommand, sendState, sendActivity } = useConsultationRemote(consultationId, {
    onCommand: (cmd) => commandRef.current?.(cmd),
    // Only the device that is recording clears its own status; an idle message
    // from some other device (e.g. a second computer) must not hide it.
    onActivity: (a) => setRemoteActivity({ xray: a.xray || null, photo: a.photo || null }),
    onState: (st) => setRemote((prev) => (st.state === 'idle' ? (prev?.from === st.from ? null : prev) : st)),
  });
  const phones = recorderDevices(devices, deviceId);
  const remotePhone = remote ? devices.find((d) => d.deviceId === remote.from) : null;
  // Doctor phone linked to this login: opens this patient on the phone (and
  // starts recording there) when this page opens on the computer.
  const link = useDoctorPhoneLink(phoneView ? null : profile?.id, { kind: 'computer', label: 'computer' });
  const loadedAtRef = useRef(null);
  const phoneCalledRef = useRef(false);
  // If the phone drops out (closed the tab, lost signal) stop showing it as recording.
  useEffect(() => {
    if (remote && !devices.some((d) => d.deviceId === remote.from)) setRemote(null);
  }, [devices, remote]);

  const adoptRow = useCallback((row) => {
    const next = formFromRow(row);
    syncedRef.current = next;
    setForm(next);
    setConsultationId(row.id);
    setDbStatus(row.status);
    setSessionDate(row.session_date);
    setAttendedBy(row.attended_by_names || []);
    setLastSavedJson(row.status === 'completed' ? JSON.stringify(allColumns(next)) : null);
  }, []);

  // Load the booking and open (or create) its consultation draft. Phone and
  // desktop both land on the same row.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: bookingError } = await fetchBookingById(bookingId);
      if (cancelled) return;
      if (bookingError) {
        setLoadError(bookingError.message || 'Failed to load booking.');
        setLoading(false);
        return;
      }
      setBooking(data);

      const { data: row, error: rowError } = await getOrCreateConsultation(data);
      if (cancelled) return;
      if (rowError || !row) {
        setLoadError(rowError?.message || 'Could not open the consultation.');
        setLoading(false);
        return;
      }
      adoptRow(row);
      setLoaded(true);
      setLoading(false);
    })();
    return () => { cancelled = true; };
  }, [bookingId, adoptRow]);

  useEffect(() => { if (loaded && loadedAtRef.current == null) loadedAtRef.current = Date.now(); }, [loaded]);

  // Work has started (this consultation was opened on the computer). The doctor's phone
  // gets the code at this moment, and only now: a code shown on the computer that the
  // phone must type before it opens the patient. If the Doctor app is already open on the
  // phone it is told directly; otherwise a notification is sent (below).
  const [phoneCode, setPhoneCode] = useState(null); // { shortCode, expiresAt, via: 'app' | 'notification' }
  useEffect(() => {
    if (phoneView || !loaded || phoneCalledRef.current || link.phones.length === 0) return;
    phoneCalledRef.current = true;
    link.openOnPhone(bookingId);
    createPhonePairing().then(({ shortCode, expiresAt, error }) => {
      if (!error) setPhoneCode({ shortCode, expiresAt, via: 'app' });
    });
  }, [phoneView, loaded, link, bookingId]);

  // No doctor phone connected a few seconds after opening? Send it a push
  // notification (if this user turned notifications on) so the doctor can tap to record.
  const pushTriedRef = useRef(false);
  useEffect(() => {
    if (phoneView || !loaded || pushTriedRef.current) return undefined;
    const t = setTimeout(async () => {
      if (pushTriedRef.current || phoneCalledRef.current) return;
      pushTriedRef.current = true;
      const { sent, shortCode, expiresAt } = await notifyDoctorPhone(bookingId);
      if (sent > 0) setPhoneCode(shortCode ? { shortCode, expiresAt, via: 'notification' } : null);
    }, 3000);
    return () => clearTimeout(t);
  }, [phoneView, loaded, bookingId, link.phones.length]);


  // Changes made on the other device arrive here.
  useEffect(() => {
    if (!consultationId) return undefined;
    return subscribeToConsultation(consultationId, (row) => {
      const before = formRef.current;
      const merged = mergeRemote(before, syncedRef.current, row);
      syncedRef.current = merged.synced;
      setForm(merged.form);
      setDbStatus(row.status);
      setAttendedBy(row.attended_by_names || []);
      // Tell the doctor when something arrives from the other device.
      if ((row.xray_image_paths || []).length > before.xrayPaths.length) setReceived('X-ray photo received from the phone');
      else if ((row.photo_image_paths || []).length > before.photoPaths.length) setReceived('Clinical photo received from the phone');
      else if ((row.audio_paths || []).length > before.audioPaths.length) setReceived('Recording received from the phone');
    });
  }, [consultationId]);

  useEffect(() => {
    if (!notice) return undefined;
    const t = setTimeout(() => setNotice(null), 12000);
    return () => clearTimeout(t);
  }, [notice]);

  useEffect(() => {
    if (!received) return undefined;
    const t = setTimeout(() => setReceived(null), 4500);
    return () => clearTimeout(t);
  }, [received]);

  // Push local edits to the database shortly after typing/recording stops.
  useEffect(() => {
    if (!loaded || !consultationId) return undefined;
    if (changedKeys(form, syncedRef.current).length === 0) return undefined;
    setSyncState('saving');
    const t = setTimeout(async () => {
      const pushed = formRef.current;
      const columns = columnsForChanges(pushed, syncedRef.current);
      const keys = changedKeys(pushed, syncedRef.current);
      const { error: pushError } = await updateConsultationColumns(consultationId, columns);
      if (pushError) {
        setSyncState('error');
        return;
      }
      const next = { ...syncedRef.current };
      keys.forEach((k) => { next[k] = pushed[k]; });
      syncedRef.current = next;
      setSyncState(changedKeys(formRef.current, next).length === 0 ? 'synced' : 'saving');
    }, 600);
    return () => clearTimeout(t);
  }, [form, loaded, consultationId]);

  // Back returns to wherever the doctor came from (dashboard, booking list or
  // booking page). Only when the page was opened directly (e.g. from the phone
  // QR code) is there nothing to go back to, so fall back to the dashboard.
  const goBack = () => {
    if (window.history.state?.idx > 0) navigate(-1);
    else navigate(`/${orgSlug}/dashboard`);
  };

  const generatePreliminary = useCallback(async (transcript) => {
    setProcessing('summarizing');
    const { summary, error: aiError } = await summarizeConsultation({ mode: 'preliminary', transcript });
    setProcessing(null);
    if (aiError) {
      setError(aiError.message);
      return;
    }
    patchForm({ preliminarySummary: summary });
  }, [patchForm]);

  // Upload → transcribe → summarise. The recording is kept even if a later
  // step fails, and `failedRecording` lets the doctor retry without re-recording.
  const processRecording = useCallback(async ({ blob, mimeType, durationSeconds, audioPath: existingPath }) => {
    setError(null);
    setProcessing('transcribing');
    let audioPath = existingPath;

    if (!audioPath) {
      const { path, error: upError } = await uploadConsultationFile(bookingId, blob, 'audio');
      if (upError) {
        setFailedRecording({ blob, mimeType, durationSeconds });
        setError(`Could not save the recording: ${upError.message}`);
        setProcessing(null);
        return;
      }
      audioPath = path;
      setForm((f) => ({ ...f, audioPaths: [...f.audioPaths, path], durationSeconds: f.durationSeconds + durationSeconds }));
    }

    const { text, language, error: tError } = await transcribeConsultationAudio(audioPath);
    if (tError) {
      setFailedRecording({ blob, mimeType, durationSeconds, audioPath });
      setError(tError.message);
      setProcessing(null);
      return;
    }

    setFailedRecording(null);
    const transcript = [formRef.current.transcript, text].filter(Boolean).join('\n\n');
    patchForm({ transcript, language: language || formRef.current.language });
    if (transcript.trim()) await generatePreliminary(transcript);
    else setProcessing(null);
  }, [bookingId, generatePreliminary, patchForm]);

  const handleStart = async () => {
    setNotice(null);
    await recorder.start();
  };

  const handleStop = async () => {
    const result = await recorder.stop();
    if (result) processRecording(result);
  };

  // Commands from the other device (computer -> phone).
  commandRef.current = async (cmd) => {
    if (cmd.target && cmd.target !== deviceId) return;
    if (cmd.action === 'start' && !recorder.isRecording && processing === null) {
      const started = await recorder.start();
      // Some phones refuse to open the microphone without a tap on the page.
      setPendingRemoteStart(!started);
    }
    if (cmd.action === 'stop' && recorder.isRecording) handleStop();
  };

  useEffect(() => {
    sendActivity({ xray: localBusy.xray, photo: localBusy.photo });
  }, [localBusy, sendActivity]);

  const myState = recorder.isRecording ? (recorder.isPaused ? 'paused' : 'recording') : (processing ? 'processing' : 'idle');
  useEffect(() => {
    sendState({ state: myState, seconds: recorder.recordingTime });
  }, [myState, recorder.recordingTime, sendState]);

  useEffect(() => {
    if (recorder.isRecording) setPendingRemoteStart(false);
  }, [recorder.isRecording]);

  const generateFinal = async () => {
    setError(null);
    setProcessing('final');
    const f = formRef.current;
    const { summary, error: aiError } = await summarizeConsultation({
      mode: 'final',
      transcript: f.transcript,
      preliminarySummary: f.preliminarySummary,
      xrayAnalysis: f.xrayAnalysis,
      photoAnalysis: f.photoAnalysis,
      additionalNotes: f.additionalNotes,
      doctorNotes: f.doctorNotes,
    });
    setProcessing(null);
    if (aiError) {
      setError(aiError.message);
      return;
    }
    patchForm({ finalSummary: summary });
  };

  const reportData = {
    patientName: booking?.customer_name,
    bookingNumber: booking?.booking_number,
    treatment: booking?.treatment?.name || booking?.treatment_name_snapshot,
    dentist: booking?.dentist?.name || booking?.dentist_name_snapshot,
    attendedBy: attendedBy.join(', '),
    sessionDate,
    language: form.language,
    recordingDurationSeconds: form.durationSeconds,
    transcript: form.transcript,
    preliminarySummary: form.preliminarySummary,
    xrayAnalysis: form.xrayAnalysis,
    photoAnalysis: form.photoAnalysis,
    additionalNotes: form.additionalNotes,
    doctorNotes: form.doctorNotes,
    finalSummary: form.finalSummary,
  };

  const handleSave = async () => {
    setSaving(true);
    setError(null);
    setNotice(null);
    const { data, error: saveError, noteError } = await saveConsultation({
      booking,
      consultationId,
      fields: { ...allColumns(form), session_date: sessionDate },
      status: 'completed',
      previousStatus: dbStatus,
    });
    setSaving(false);
    if (saveError) {
      setError(`Could not save the consultation: ${saveError.message}`);
      return false;
    }
    syncedRef.current = formFromRow(data);
    setForm(formFromRow(data));
    setLastSavedJson(JSON.stringify(allColumns(formFromRow(data))));
    setConsultationId(data.id);
    setDbStatus(data.status);
    setAttendedBy(data.attended_by_names || []);
    setSyncState('synced');
    setNotice(noteError
      ? 'Consultation saved, but the summary could not be added to the treatment notes.'
      : 'Consultation saved.');
    link.closeOnPhone(bookingId);
    return true;
  };

  const handleClear = async () => {
    if (!window.confirm('Clear everything and start a new consultation? Anything not saved will be lost.')) return;
    setPhase('active');
    setFailedRecording(null);
    setError(null);
    setNotice(null);
    if (dbStatus === 'completed') {
      // Keep the saved consultation as it is and start a fresh draft beside it.
      const { data: row, error: newError } = await createConsultationDraft(booking);
      if (newError || !row) {
        setError(`Could not start a new consultation: ${newError?.message || 'unknown error'}`);
        return;
      }
      adoptRow(row);
    } else {
      // Empty the shared draft; autosave pushes the cleared fields to the other device too.
      setForm(EMPTY_FORM);
    }
  };

  const remoteBusy = !!remote;
  // Saved and nothing changed since: show "Saved" instead of looking like nothing happened.
  const isSavedClean = dbStatus === 'completed' && lastSavedJson !== null && lastSavedJson === JSON.stringify(allColumns(form));
  // Say why Save is greyed out instead of leaving it silently dead.
  const saveBlockedReason = recorder.isRecording || remote
    ? 'Stop the recording to save.'
    : processing ? 'Wait for processing to finish.'
    : (!hasContent(form) ? 'Nothing to save yet.' : null);
  const busy = processing !== null || recorder.isRecording || saving || remoteBusy;
  const canReport = !!booking && hasContent(form);

  const statusChip = (() => {
    if (recorder.isRecording) return { label: recorder.isPaused ? 'Paused' : 'Recording', cls: 'bg-error/10 text-error', pulse: !recorder.isPaused };
    if (processing) return { label: 'Processing…', cls: 'bg-warning/10 text-warning', pulse: true };
    if (dbStatus === 'completed') return { label: 'Saved', cls: 'bg-success/10 text-success' };
    return { label: 'In progress', cls: 'bg-primary/10 text-primary' };
  })();

  const longDate = new Date(`${sessionDate}T00:00:00`).toLocaleDateString('en-GB', {
    weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
  });

  // Phone "Done": finish the consultation (saved as Completed, so it shows as Completed in
  // History) and go back to the Doctor home. Nothing captured yet -> just go back.
  const donePhoneView = async () => {
    if (hasContent(form)) {
      const saved = await handleSave();
      if (!saved) return; // the error is shown on this screen; stay here
    }
    onDone?.({ completed: hasContent(form), patientName: booking?.customer_name });
  };

  // Phone: leave this patient and go back to the Doctor home. A recording in progress is saved first.
  const closePhoneView = async () => {
    if (recorder.isRecording) {
      if (!window.confirm('Stop recording and close? The recording is saved.')) return;
      await handleStop();
    }
    onDone?.();
  };

  if (phoneView) {
    return (
      <div className="h-[100dvh] flex flex-col bg-gradient-to-b from-primary/15 via-background to-background overflow-hidden">
        <div className="flex-1 min-h-0 overflow-y-auto overscroll-contain pb-6">
        {loading && (
          <div className="p-12 text-center">
            <div className="animate-spin w-8 h-8 border-2 border-primary border-t-transparent rounded-full mx-auto mb-3" />
            <p className="font-body text-text-secondary">Connecting…</p>
          </div>
        )}
        {!loading && loadError && (
          <div className="p-8 text-center">
            <Icon name="AlertCircle" size={40} className="text-error mx-auto mb-3" />
            <p className="font-body text-text-secondary">{loadError}</p>
          </div>
        )}
        {!loading && !loadError && booking && (
          <div className="max-w-md mx-auto p-4 space-y-4">
            <div className="bg-white rounded-2xl border border-gray-200 shadow-sm p-4">
              <div className="flex items-center gap-3">
                <div className="w-12 h-12 rounded-full bg-primary/10 text-primary flex items-center justify-center text-lg font-heading font-heading-semibold shrink-0">
                  {(booking.customer_name || '?').trim().charAt(0).toUpperCase()}
                </div>
                <div className="min-w-0 flex-1">
                  <p className="font-heading font-heading-semibold text-lg text-text-primary leading-tight truncate">{booking.customer_name}</p>
                  <p className="text-xs text-text-tertiary truncate">{booking.booking_number} · {longDate}</p>
                </div>
                {onDone && (
                  <button type="button" onClick={closePhoneView} aria-label="Close" className="p-2 -mr-1 rounded-full hover:bg-gray-100 shrink-0">
                    <Icon name="X" size={20} className="text-text-secondary" />
                  </button>
                )}
              </div>
              <div className="flex flex-wrap gap-1.5 mt-3">
                <span className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium ${statusChip.cls}`}>
                  <span className={`w-1.5 h-1.5 rounded-full bg-current ${statusChip.pulse ? 'animate-pulse' : ''}`} />
                  {statusChip.label}
                </span>
                <span className="px-2.5 py-1 rounded-full text-xs bg-gray-100 text-text-secondary">{booking.treatment?.name || booking.treatment_name_snapshot || 'Treatment'}</span>
                <span className="px-2.5 py-1 rounded-full text-xs bg-gray-100 text-text-secondary">{booking.dentist?.name || booking.dentist_name_snapshot || 'Unassigned'}</span>
              </div>
              <details className="mt-3 group">
                <summary className="text-xs text-primary font-medium cursor-pointer list-none flex items-center gap-1">
                  <Icon name="ChevronDown" size={14} className="group-open:rotate-180 transition-transform" /> Patient details
                </summary>
                <div className="mt-3 pt-3 border-t border-gray-100">
                  <PatientDetailsGrid
                    patient={booking.customer_name}
                    booking={booking.booking_number}
                    treatment={booking.treatment?.name || booking.treatment_name_snapshot}
                    dentist={booking.dentist?.name || booking.dentist_name_snapshot}
                    attendedBy={attendedBy.join(', ')}
                    visitDate={formatVisitDate(sessionDate)}
                    lastVisit={lastVisit}
                  />
                </div>
              </details>
              <p className="mt-3 text-[11px] text-text-tertiary flex items-center gap-1">
                {syncState === 'saving' && <><span className="animate-spin w-3 h-3 border border-primary border-t-transparent rounded-full" /> Sending to the computer…</>}
                {syncState === 'synced' && <><span className="w-1.5 h-1.5 rounded-full bg-success" /> Connected to the computer</>}
                {syncState === 'error' && <span className="text-error flex items-center gap-1"><Icon name="CloudOff" size={12} /> Connection problem — will retry</span>}
              </p>
            </div>

            {error && (
              <div className="p-3 bg-error/5 border border-error/20 rounded-md flex items-start gap-2">
                <Icon name="AlertCircle" size={16} className="text-error mt-0.5 shrink-0" />
                <div className="flex-1 text-sm text-text-secondary">
                  {error}
                  {failedRecording && (
                    <button type="button" className="ml-2 text-primary font-medium" disabled={busy} onClick={() => processRecording(failedRecording)}>Retry</button>
                  )}
                </div>
                <button onClick={() => setError(null)} aria-label="Dismiss"><Icon name="X" size={14} className="text-text-tertiary" /></button>
              </div>
            )}

            {phase === 'active' && (
            <>
            <Card title="Voice Recording" icon="Mic">
              {pendingRemoteStart && !recorder.isRecording && (
                <div className="mb-4 p-4 bg-primary/10 border border-primary/30 rounded-lg text-center">
                  <p className="text-sm text-text-primary mb-3">Ready to record. Tap the button to start with this phone's microphone.</p>
                  <Button variant="primary" size="lg" fullWidth iconName="Mic" iconPosition="left" onClick={handleStart}>Tap to start recording</Button>
                </div>
              )}

              {!recorder.isRecording ? (
                <div className="flex flex-col items-center gap-2 py-2">
                  <button type="button" disabled={processing !== null} onClick={handleStart} aria-label="Start recording"
                          className="w-24 h-24 rounded-full bg-primary text-white flex items-center justify-center shadow-lg shadow-primary/30 active:scale-95 transition disabled:opacity-50">
                    <Icon name="Mic" size={40} />
                  </button>
                  <p className="text-sm text-text-secondary">{form.audioPaths.length ? 'Tap to record more' : 'Tap to start recording'}</p>
                </div>
              ) : (
                <div className="space-y-4">
                  <div className="text-center">
                    <p className="font-mono text-4xl text-text-primary tabular-nums">{formatTimer(recorder.recordingTime)}</p>
                    <p className="text-sm text-error mt-1 flex items-center justify-center gap-1.5">
                      <span className={`w-2 h-2 rounded-full bg-error ${recorder.isPaused ? '' : 'animate-pulse'}`} />
                      {recorder.isPaused ? 'Paused' : 'Recording'}
                    </p>
                  </div>
                  <div className="grid grid-cols-2 gap-3">
                    <Button variant="outline" size="lg" iconName={recorder.isPaused ? 'Play' : 'Pause'} iconPosition="left"
                            onClick={recorder.isPaused ? recorder.resume : recorder.pause}>
                      {recorder.isPaused ? 'Resume' : 'Pause'}
                    </Button>
                    <Button variant="danger" size="lg" iconName="Square" iconPosition="left" onClick={handleStop}>Stop</Button>
                  </div>
                </div>
              )}

              {processing === 'transcribing' && <p className="mt-4 text-sm text-text-secondary flex items-center gap-2"><span className="animate-spin w-4 h-4 border-2 border-primary border-t-transparent rounded-full" />Converting speech to text…</p>}
              {processing === 'summarizing' && <p className="mt-4 text-sm text-text-secondary flex items-center gap-2"><span className="animate-spin w-4 h-4 border-2 border-primary border-t-transparent rounded-full" />Generating summary…</p>}
              {recorder.error && <p className="mt-3 text-sm text-error">{recorder.error}</p>}
              {form.audioPaths.length > 0 && !recorder.isRecording && (
                <div className="mt-4 space-y-2">
                  <p className="text-xs text-text-tertiary">Recordings for this patient (tap play to listen)</p>
                  {form.audioPaths.map((p, i) => <SavedRecording key={p} path={p} index={i} />)}
                </div>
              )}
            </Card>

            {(form.transcript.trim() || form.preliminarySummary.trim()) && (
              <Card title="Recorded so far" icon="FileText">
                <div className="space-y-3 max-h-64 overflow-auto text-sm text-text-primary whitespace-pre-wrap break-words">
                  {form.preliminarySummary.trim() && <div><p className="text-xs uppercase tracking-wider text-text-tertiary mb-1">Summary</p>{form.preliminarySummary}</div>}
                  {form.transcript.trim() && <div><p className="text-xs uppercase tracking-wider text-text-tertiary mb-1">Transcript</p>{form.transcript}</div>}
                </div>
              </Card>
            )}

            <ImageAnalysisCard
              compact title="X-ray" icon="ScanLine" kind="xray" bookingId={bookingId} onBusyChange={onXrayBusy}
              imagePaths={form.xrayPaths} analysis={form.xrayAnalysis}
              onChange={({ imagePaths, analysis }) => patchForm({ xrayPaths: imagePaths, xrayAnalysis: analysis })}
              onAnalysisEdit={(v) => patchForm({ xrayAnalysis: v })}
              disabled={recorder.isRecording}
            />
            <ImageAnalysisCard
              compact title="Clinical Photo" icon="Camera" kind="photo" bookingId={bookingId} onBusyChange={onPhotoBusy}
              imagePaths={form.photoPaths} analysis={form.photoAnalysis}
              onChange={({ imagePaths, analysis }) => patchForm({ photoPaths: imagePaths, photoAnalysis: analysis })}
              onAnalysisEdit={(v) => patchForm({ photoAnalysis: v })}
              disabled={recorder.isRecording}
            />


            <PatientEarlierVisits customerId={booking.customer_id} excludeId={consultationId} onOpen={setPhoneDetail} />

            <p className="text-center text-xs text-text-tertiary px-4">
              Recordings and photos are saved automatically. When you are done capturing, tap Finish consultation to add notes and the final summary.
            </p>
            </>
            )}
            {phase === 'review' && (
              <>
                <Card title="Doctor's Notes" icon="Stethoscope">
                  <TextArea value={form.doctorNotes} onChange={(v) => patchForm({ doctorNotes: v })} rows={6}
                            placeholder="Assessment, diagnosis and treatment plan." />
                </Card>
                <Card title="Additional Notes" icon="StickyNote">
                  <TextArea value={form.additionalNotes} onChange={(v) => patchForm({ additionalNotes: v })} rows={4}
                            placeholder="Anything else to record." />
                </Card>
                <Card
                  title="Final Summary"
                  icon="ClipboardCheck"
                  action={
                    <Button variant="outline" size="xs" iconName="Sparkles" iconPosition="left" disabled={busy} loading={processing === 'final'} onClick={generateFinal}>
                      {form.finalSummary ? 'Regenerate' : 'Generate'}
                    </Button>
                  }
                >
                  <TextArea value={form.finalSummary} onChange={(v) => patchForm({ finalSummary: v })} rows={form.finalSummary ? 12 : 4}
                            placeholder="Combines the recording, X-rays, photos and your notes. You can also write it yourself." />
                </Card>
                <p className="text-center text-xs text-text-tertiary px-4">
                  Tap Done to save the consultation as Completed.
                </p>
              </>
            )}

          </div>
        )}

        </div>

        {/* An earlier visit opened from "Earlier visits": read-only, on top of the patient screen. */}
        {phoneDetail && (
          <div className="fixed inset-0 z-40 bg-background overflow-auto">
            <div className="max-w-md mx-auto p-4">
              <ConsultationDetail row={phoneDetail} orgName={profile?.organizations?.name} onBack={() => setPhoneDetail(null)} />
            </div>
          </div>
        )}

        {/* Always visible at the bottom. Finish -> notes -> Done; Switch patient / Close just leave. */}
        {!loading && !loadError && booking && onDone && (
          <div className="shrink-0 px-4 pt-2 pb-[max(0.75rem,env(safe-area-inset-bottom))] bg-background/95 border-t border-gray-100">
            <div className="max-w-md mx-auto flex flex-col items-center gap-3">
              {/* Primary action: a compact floating pill, clear of the bar below */}
              <div className="pointer-events-auto self-end flex flex-col items-end gap-1.5">
                {(recorder.isRecording || processing !== null) && (
                  <p className="text-xs text-text-secondary bg-white/90 rounded-full px-3 py-1 shadow-sm">
                    {recorder.isRecording ? 'Stop the recording to finish' : 'Wait for processing to finish'}
                  </p>
                )}
                {phase === 'active' ? (
                  <button type="button" disabled={recorder.isRecording || processing !== null}
                          onClick={() => setPhase('review')}
                          className="inline-flex items-center gap-2 h-11 pl-5 pr-4 rounded-full bg-primary text-white text-sm font-medium shadow-lg shadow-primary/30 active:scale-95 transition disabled:opacity-50 disabled:shadow-none">
                    Finish consultation <Icon name="ArrowRight" size={16} />
                  </button>
                ) : (
                  <div className="inline-flex items-center gap-2">
                    <button type="button" aria-label="Back to capture" disabled={saving || processing !== null} onClick={() => setPhase('active')}
                            className="w-11 h-11 rounded-full bg-white border border-gray-200 shadow-md flex items-center justify-center text-text-secondary active:scale-95 transition disabled:opacity-50">
                      <Icon name="ArrowLeft" size={18} />
                    </button>
                    <button type="button" disabled={recorder.isRecording || processing !== null || saving} onClick={donePhoneView}
                            className="inline-flex items-center gap-2 h-11 pl-5 pr-5 rounded-full bg-success text-white text-sm font-medium shadow-lg shadow-success/30 active:scale-95 transition disabled:opacity-50 disabled:shadow-none">
                      {saving ? <span className="animate-spin w-4 h-4 border-2 border-white border-t-transparent rounded-full" /> : <Icon name="Check" size={16} />}
                      Done
                    </button>
                  </div>
                )}
              </div>

              {/* Leave: back to the patient list (this also covers switching patient) */}
              <button type="button" onClick={closePhoneView}
                      className="pointer-events-auto w-full flex items-center justify-center gap-1.5 py-2.5 rounded-2xl bg-white/95 border border-gray-200 shadow-sm text-sm text-text-secondary active:bg-gray-50">
                <Icon name="X" size={15} /> Close
              </button>
            </div>
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-surface-sidebar">
      <StaffSidebar userRole={userRole} onCollapseChange={setSidebarCollapsed} />

      <div className={`${sidebarCollapsed ? 'lg:ml-16' : 'lg:ml-60'} pb-20 lg:pb-0 transition-all duration-200`}>
        <StaffTopBar orgSlug={orgSlug} />
        <div className="relative z-0 flex gap-2 sm:gap-3 min-h-[calc(100vh-52px)]">
        <main
          className="flex-1 min-w-0 bg-surface-dim"
          style={{ borderRadius: '16px 0 0 0', borderLeft: '1px solid #e5e7eb', borderTop: '1px solid #e5e7eb' }}
        >
        {loading && (
          <div className="p-12 text-center">
            <div className="animate-spin w-8 h-8 border-2 border-primary border-t-transparent rounded-full mx-auto mb-3" />
            <p className="font-body text-text-secondary">Loading consultation…</p>
          </div>
        )}

        {!loading && loadError && (
          <div className="p-12 text-center">
            <Icon name="AlertCircle" size={48} className="text-error mx-auto mb-4" />
            <p className="font-body text-text-secondary mb-4">{loadError}</p>
            <Button variant="primary" onClick={() => navigate(`/${orgSlug}/dashboard`)}>Back to dashboard</Button>
          </div>
        )}

        {!loading && !loadError && booking && (
          <div className="max-w-5xl mx-auto p-4 lg:p-6 space-y-4">
            {/* Header */}
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="flex items-center gap-3 min-w-0">
                <button onClick={goBack} aria-label="Go back" className="p-2 rounded-lg bg-white border border-gray-200 hover:bg-gray-50 shrink-0">
                  <Icon name="ArrowLeft" size={18} className="text-text-secondary" />
                </button>
                <div className="min-w-0">
                  <h1 className="font-heading font-heading-semibold text-xl text-text-primary leading-tight">Consultation</h1>
                  <p className="font-caption text-sm text-text-secondary flex items-center gap-1.5 truncate">
                    <Icon name="Calendar" size={14} /> {longDate}
                  </p>
                </div>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-xs text-text-tertiary flex items-center gap-1">
                  {syncState === 'saving' && <><span className="animate-spin w-3 h-3 border border-primary border-t-transparent rounded-full" /> Syncing…</>}
                  {syncState === 'synced' && <><Icon name="Cloud" size={12} /> Synced</>}
                  {syncState === 'error' && <span className="text-error flex items-center gap-1"><Icon name="CloudOff" size={12} /> Not synced — will retry on next change</span>}
                </span>
                <Button variant="outline" size="xs" iconName="Smartphone" iconPosition="left" onClick={() => setShowPhone(true)}>
                  Continue on phone
                </Button>
                <span className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium ${statusChip.cls}`}>
                  <span className={`w-1.5 h-1.5 rounded-full bg-current ${statusChip.pulse ? 'animate-pulse' : ''}`} />
                  {statusChip.label}
                </span>
              </div>
            </div>

            {/* Steps */}
            <div className="flex items-center gap-2 text-sm">
              {[{ key: 'active', label: 'Capture', n: 1 }, { key: 'review', label: 'Review & finish', n: 2 }].map((st, idx) => {
                const current = phase === st.key;
                return (
                  <React.Fragment key={st.key}>
                    {idx > 0 && <span className="h-px w-8 bg-gray-300" />}
                    <button type="button" disabled={busy || current} onClick={() => setPhase(st.key)}
                            className={`flex items-center gap-2 px-3 py-1.5 rounded-full border transition ${current ? 'bg-primary text-white border-primary' : 'bg-white text-text-secondary border-gray-200 hover:bg-gray-50'}`}>
                      <span className={`w-5 h-5 rounded-full text-xs flex items-center justify-center ${current ? 'bg-white/20' : 'bg-gray-100'}`}>{st.n}</span>
                      {st.label}
                    </button>
                  </React.Fragment>
                );
              })}
            </div>

            {phoneCode && !link.phones.some((p) => p.bookingId === bookingId) && (
              <PhoneCodeBanner initial={phoneCode} via={phoneCode.via} />
            )}

            {link.phones.some((p) => p.bookingId && p.bookingId !== bookingId) && (
              <div className="p-3 bg-warning/10 border border-warning/30 rounded-md flex flex-wrap items-center justify-between gap-2 text-sm">
                <span className="flex items-center gap-2 text-text-primary">
                  <Icon name="AlertTriangle" size={16} className="text-warning shrink-0" />
                  Your phone is on a different patient, so recordings and photos won't appear here.
                </span>
                <Button variant="primary" size="xs" iconName="Smartphone" iconPosition="left"
                        onClick={() => link.openOnPhone(bookingId, { autoStart: false })}>
                  Open this patient on the phone
                </Button>
              </div>
            )}

            {link.phones.length > 0 && (
              <div className="p-3 bg-primary/5 border border-primary/20 rounded-md flex flex-wrap items-center justify-between gap-2 text-sm">
                <span className="flex items-center gap-2 text-text-primary">
                  <Icon name="Smartphone" size={16} className="text-primary" />
                  Doctor phone connected ({link.phones[0].label})
                </span>
              </div>
            )}

            {booking.status !== 'In-Progress' && booking.status !== 'Completed' && (
              <div className="p-3 bg-warning/10 border border-warning/30 rounded-md text-sm text-text-secondary flex items-center gap-2">
                <Icon name="AlertTriangle" size={16} className="text-warning shrink-0" />
                This booking is {booking.status}. Consultations are normally started once the booking is In-Progress.
              </div>
            )}

            {/* Patient (prefilled from the booking) */}
            <Card title="Patient Details" icon="User">
              <div className="flex flex-col lg:flex-row lg:items-center gap-4 lg:gap-8">
                <div className="flex items-center gap-3 lg:min-w-[220px]">
                  <div className="w-12 h-12 rounded-full bg-primary/10 text-primary flex items-center justify-center font-heading font-heading-semibold text-lg shrink-0">
                    {(booking.customer_name || '?').trim().charAt(0).toUpperCase()}
                  </div>
                  <div className="min-w-0">
                    <p className="font-heading font-heading-semibold text-text-primary truncate">{booking.customer_name}</p>
                    <p className="text-xs text-text-tertiary">{booking.booking_number || '—'}</p>
                  </div>
                </div>
                <dl className="flex-1 grid grid-cols-2 md:grid-cols-5 gap-3 text-sm">
                  {[
                    ['Treatment', booking.treatment?.name || booking.treatment_name_snapshot || '—'],
                    ['Dentist', booking.dentist?.name || booking.dentist_name_snapshot || 'Unassigned'],
                    ['Visit date', formatVisitDate(sessionDate)],
                    ['Last visit', lastVisit || '…'],
                    ['Attended by', attendedBy.length ? attendedBy.join(', ') : 'No one yet'],
                  ].map(([k, v]) => (
                    <div key={k} className="rounded-lg bg-surface-dim/60 border border-gray-100 px-3 py-2 min-w-0">
                      <dt className="text-text-tertiary text-xs mb-0.5">{k}</dt>
                      <dd className="font-medium text-text-primary truncate" title={String(v)}>{v}</dd>
                    </div>
                  ))}
                </dl>
              </div>
            </Card>

            {error && (
              <div className="p-3 bg-error/5 border border-error/20 rounded-md flex items-start gap-2">
                <Icon name="AlertCircle" size={16} className="text-error mt-0.5 shrink-0" />
                <div className="flex-1 text-sm text-text-secondary">
                  {error}
                  {failedRecording && (
                    <button type="button" className="ml-2 text-primary font-medium hover:underline" disabled={busy}
                            onClick={() => processRecording(failedRecording)}>
                      Retry
                    </button>
                  )}
                </div>
                <button onClick={() => setError(null)} aria-label="Dismiss"><Icon name="X" size={14} className="text-text-tertiary" /></button>
              </div>
            )}
            {received && (
              <div className="p-3 bg-success/10 border border-success/30 rounded-md text-sm text-text-primary flex items-center gap-2">
                <Icon name="Download" size={16} className="text-success shrink-0" /> {received}
              </div>
            )}
            {phase === 'active' && (
              <>
                {/* Recording */}
                <Card title="Voice Recording" icon="Mic">
                  {pendingRemoteStart && !recorder.isRecording && (
                    <div className="mb-4 p-4 bg-primary/10 border border-primary/30 rounded-lg text-center">
                      <p className="text-sm text-text-primary mb-3">Ready to record. Tap the button to start with this phone's microphone.</p>
                      <Button variant="primary" size="lg" fullWidth iconName="Mic" iconPosition="left" onClick={handleStart}>Tap to start recording</Button>
                    </div>
                  )}

                  <div className="flex flex-wrap items-center gap-4">
                    {remote ? (
                      <>
                        <span className="inline-flex items-center gap-2 text-sm text-text-primary">
                          <Icon name="Smartphone" size={16} className="text-primary" />
                          {remote.state === 'processing'
                            ? `${remotePhone?.label || 'Phone'} is converting speech to text…`
                            : `Recording on ${remotePhone?.label || 'phone'}${remote.state === 'paused' ? ' (paused)' : ''}`}
                        </span>
                        {remote.state !== 'processing' && (
                          <>
                            <span className="font-mono text-lg text-text-primary tabular-nums">{formatTimer(remote.seconds || 0)}</span>
                            <Button variant="danger" iconName="Square" iconPosition="left" onClick={() => sendCommand({ action: 'stop', target: remote.from })}>
                              Stop
                            </Button>
                          </>
                        )}
                      </>
                    ) : !recorder.isRecording ? (
                      <>
                        {phones.length > 0 && (
                          <Button variant="primary" iconName="Smartphone" iconPosition="left" disabled={processing !== null}
                                  onClick={() => sendCommand({ action: 'start', target: phones[0].deviceId })}>
                            Record on {phones[0].label || 'phone'}
                          </Button>
                        )}
                        <Button variant={phones.length > 0 ? 'outline' : 'primary'} iconName="Mic" iconPosition="left" disabled={processing !== null} onClick={handleStart}>
                          {phones.length > 0 ? 'Record on this device' : (form.audioPaths.length ? 'Record more' : 'Start recording')}
                        </Button>
                      </>
                    ) : (
                      <>
                        <span className="font-mono text-lg text-text-primary tabular-nums">{formatTimer(recorder.recordingTime)}</span>
                        <Button variant="outline" iconName={recorder.isPaused ? 'Play' : 'Pause'} iconPosition="left"
                                onClick={recorder.isPaused ? recorder.resume : recorder.pause}>
                          {recorder.isPaused ? 'Resume' : 'Pause'}
                        </Button>
                        <Button variant="danger" iconName="Square" iconPosition="left" onClick={handleStop}>Stop</Button>
                      </>
                    )}
                    {processing === 'transcribing' && <span className="text-sm text-text-secondary flex items-center gap-2"><span className="animate-spin w-4 h-4 border-2 border-primary border-t-transparent rounded-full" />Converting speech to text…</span>}
                    {processing === 'summarizing' && <span className="text-sm text-text-secondary flex items-center gap-2"><span className="animate-spin w-4 h-4 border-2 border-primary border-t-transparent rounded-full" />Generating summary…</span>}
                  </div>
                  {phones.length === 0 && !remote && (
                    <p className="mt-3 text-xs text-text-tertiary flex items-center gap-1.5">
                      <Icon name="Smartphone" size={12} /> Prefer your phone's mic? Tap <strong>Continue on phone</strong> at the top.
                    </p>
                  )}
                  {recorder.error && <p className="mt-3 text-sm text-error">{recorder.error}</p>}
                  {form.audioPaths.length > 0 && (
                    <div className="mt-4 space-y-2">
                      {form.audioPaths.map((p, i) => <SavedRecording key={p} path={p} index={i} />)}
                    </div>
                  )}
                </Card>

                <Card title="Transcript" icon="FileText">
                  <TextArea value={form.transcript} onChange={(v) => patchForm({ transcript: v })} rows={form.transcript ? 8 : 4}
                            placeholder="The transcript appears here after you stop recording. You can also type or edit it." />
                </Card>

                <Card
                  title="Consultation Summary"
                  icon="Sparkles"
                  action={form.transcript.trim() && processing === null ? (
                    <Button variant="outline" size="xs" iconName="RefreshCw" iconPosition="left" onClick={() => generatePreliminary(form.transcript)}>
                      {form.preliminarySummary ? 'Regenerate' : 'Generate'}
                    </Button>
                  ) : null}
                >
                  <TextArea value={form.preliminarySummary} onChange={(v) => patchForm({ preliminarySummary: v })} rows={form.preliminarySummary ? 10 : 4}
                            placeholder="An AI summary of the recording appears here. You can also write or edit it." />
                </Card>

                <ImageAnalysisCard
                  title="X-ray Analysis" icon="ScanLine" kind="xray" bookingId={bookingId} onBusyChange={onXrayBusy} externalBusy={remoteActivity.xray}
                  imagePaths={form.xrayPaths} analysis={form.xrayAnalysis}
                  onChange={({ imagePaths, analysis }) => patchForm({ xrayPaths: imagePaths, xrayAnalysis: analysis })}
                  onAnalysisEdit={(v) => patchForm({ xrayAnalysis: v })}
                  disabled={recorder.isRecording}
                />
                <ImageAnalysisCard
                  title="Clinical Photo Analysis" icon="Camera" kind="photo" bookingId={bookingId} onBusyChange={onPhotoBusy} externalBusy={remoteActivity.photo}
                  imagePaths={form.photoPaths} analysis={form.photoAnalysis}
                  onChange={({ imagePaths, analysis }) => patchForm({ photoPaths: imagePaths, photoAnalysis: analysis })}
                  onAnalysisEdit={(v) => patchForm({ photoAnalysis: v })}
                  disabled={recorder.isRecording}
                />

                <div className="flex justify-end">
                  <Button variant="primary" iconName="ArrowRight" iconPosition="right" disabled={busy}
                          onClick={() => { setPhase('review'); window.scrollTo({ top: 0, behavior: 'smooth' }); }}>
                    Finish Consultation
                  </Button>
                </div>
              </>
            )}

            {phase === 'review' && (
              <>
                <Card title="Doctor's Notes" icon="Stethoscope">
                  <TextArea value={form.doctorNotes} onChange={(v) => patchForm({ doctorNotes: v })} rows={6}
                            placeholder="Assessment, diagnosis and treatment plan." />
                </Card>
                <Card title="Additional Notes" icon="StickyNote">
                  <TextArea value={form.additionalNotes} onChange={(v) => patchForm({ additionalNotes: v })} rows={4}
                            placeholder="Anything else to record." />
                </Card>
                <Card
                  title="Final Summary"
                  icon="ClipboardCheck"
                  action={
                    <Button variant="outline" size="xs" iconName="Sparkles" iconPosition="left" disabled={busy} loading={processing === 'final'} onClick={generateFinal}>
                      {form.finalSummary ? 'Regenerate' : 'Generate final summary'}
                    </Button>
                  }
                >
                  <TextArea value={form.finalSummary} onChange={(v) => patchForm({ finalSummary: v })} rows={form.finalSummary ? 12 : 4}
                            placeholder="Combines the recording, X-rays, photos and your notes. You can also write it yourself." />
                </Card>
                <div>
                  <Button variant="outline" iconName="ArrowLeft" iconPosition="left" disabled={busy} onClick={() => setPhase('active')}>
                    Back to consultation
                  </Button>
                </div>
              </>
            )}

            {/* Actions */}
            <div className="sticky bottom-16 lg:bottom-0 z-10 -mx-4 lg:mx-0 px-4 lg:px-4 py-3 bg-white/95 backdrop-blur border-t lg:border border-gray-200 lg:rounded-xl lg:shadow-sm">
              <div className="flex flex-wrap items-center gap-2">
                <Button variant={isSavedClean ? 'success' : 'primary'} iconName={isSavedClean ? 'Check' : 'Save'} iconPosition="left" loading={saving} disabled={busy || !hasContent(form)} onClick={handleSave}>
                  {isSavedClean ? 'Saved' : (dbStatus === 'completed' ? 'Save changes' : 'Save Consultation')}
                </Button>
                {saveBlockedReason && (
                  <span className="text-xs text-text-tertiary">{saveBlockedReason}</span>
                )}
                <div className="flex flex-wrap items-center gap-2 ml-auto">
                  <Button variant="outline" size="sm" iconName="FileText" iconPosition="left" disabled={!canReport}
                          className="border-purple-200 text-purple-600 hover:bg-purple-50 hover:text-purple-700"
                          onClick={() => generateConsultationPdf(reportData, profile?.organizations?.name)}>
                    PDF Report
                  </Button>
                  <Button variant="outline" size="sm" iconName="Download" iconPosition="left" disabled={!canReport}
                          className="border-sky-200 text-sky-700 hover:bg-sky-50 hover:text-sky-800"
                          onClick={() => exportConsultationJson(reportData)}>
                    Export
                  </Button>
                  <Button variant="ghost" size="sm" iconName="RotateCcw" iconPosition="left" disabled={busy} onClick={handleClear}>
                    Clear &amp; New
                  </Button>
                </div>
              </div>
            </div>
          </div>
        )}
        </main>
        <AIAssistantPanel />
        </div>
      </div>

      {notice && (
        <div className="fixed top-4 left-1/2 -translate-x-1/2 z-modal-overlay w-[calc(100%-2rem)] max-w-md">
          <div className="p-4 bg-white border border-success/40 rounded-lg shadow-lg flex items-start gap-3">
            <Icon name="CheckCircle" size={20} className="text-success shrink-0 mt-0.5" />
            <div className="flex-1 text-sm">
              <p className="font-medium text-text-primary">{notice}</p>
              {dbStatus === 'completed' && (
                <p className="text-text-secondary mt-1">
                  It's stored on {booking?.customer_name}'s record. The booking is still In-Progress: mark it Completed from the dashboard when the visit is over.
                </p>
              )}
              <button type="button" onClick={() => navigate(`/${orgSlug}/dashboard`)} className="mt-2 text-primary font-medium">
                Back to dashboard
              </button>
            </div>
            <button type="button" onClick={() => setNotice(null)} aria-label="Dismiss"><Icon name="X" size={16} className="text-text-tertiary" /></button>
          </div>
        </div>
      )}

      {showPhone && <PhoneHandoff orgSlug={orgSlug} bookingId={bookingId} onClose={closeHandoff} phoneCount={link.phones.length} phoneLabel={link.phones[0]?.label} />}
    </div>
  );
};

export default ConsultationPage;
