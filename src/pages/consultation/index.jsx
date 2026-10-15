import React, { useState, useEffect, useCallback, useRef, useReducer, useMemo } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { QRCodeSVG } from 'qrcode.react';
import Icon from '../../components/AppIcon';
import Button from '../../components/ui/Button';
import AppShell from '../../components/ui/AppShell';
import { useShellHeader } from '../../hooks/useShellHeader';
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
import DeskHeader from './desk/DeskHeader';
import RecorderBar from './desk/RecorderBar';
import NoteCard from './desk/NoteCard';
import ConsultationRail from './desk/ConsultationRail';
import useLeaveGuard from './desk/useLeaveGuard';
import { flowReducer, initialFlow, deriveStage, showNoAiBanner, draftingSteps, draftInputsKey, draftIsStale } from '../../utils/consultationFlow';
import { markdownToNote, noteToMarkdown, normalizeNote, isNoteEmpty, sameNote, emptyNote } from '../../utils/consultationNote';
import { parseSummarySections } from '../../utils/summarySections';
import { resizeImageFile } from '../../utils/imageResize';
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
  analyzeConsultationImages,
  getPatientRecord,
  updateBookingStatus,
} from '../../services/api';
import { generateConsultationPdf, exportConsultationJson } from '../../utils/consultationReport';
import { EMPTY_FORM, formFromRow, columnsForChanges, allColumns, mergeRemote, changedKeys, mergeAfterSave } from '../../utils/consultationSync';
import {
  newQueueItem, enqueue, update as updateQueue, hasUnuploaded, failedItems, hasUploadFailure, isBusy as queueBusy,
  seedTranscribed, untranscribedPaths, readTranscribed, writeTranscribed,
} from '../../utils/recordingQueue';

const todayIso = () => new Date().toLocaleDateString('en-CA');

const hasContent = (f) =>
  [f.transcript, f.preliminarySummary, f.xrayAnalysis, f.photoAnalysis, f.additionalNotes, f.doctorNotes, f.finalSummary]
    .some((v) => v && v.trim());

const formatTimer = (s) => `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;

const Card = ({ title, icon, children, action }) => (
  <div className="bg-white rounded-2xl border border-gray-200/80 shadow-sm hover:shadow-md transition-shadow overflow-hidden">
    <div className="flex items-center justify-between px-5 py-3.5 border-b border-gray-100 bg-gradient-to-r from-primary/[0.05] to-transparent">
      <div className="flex items-center gap-3">
        <span className="w-9 h-9 rounded-xl bg-primary/10 text-primary flex items-center justify-center shrink-0">
          <Icon name={icon} size={18} />
        </span>
        <h2 className="font-heading font-heading-semibold text-base text-text-primary">{title}</h2>
      </div>
      {action}
    </div>
    <div className="p-5">{children}</div>
  </div>
);

const TextArea = ({ value, onChange, rows = 6, placeholder, disabled }) => (
  <textarea
    value={value}
    onChange={(e) => onChange(e.target.value)}
    rows={rows}
    disabled={disabled}
    placeholder={placeholder}
    className="w-full text-sm leading-relaxed rounded-xl border-gray-200 bg-gray-50/50 px-4 py-3 placeholder:text-gray-400 focus:bg-white focus:border-primary focus:ring-2 focus:ring-primary/20 transition"
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
  const orgSlug = urlOrgSlug || profile?.organizations?.slug;

  const { header: shellHeader, assistantOpen } = useShellHeader(orgSlug);
  const [booking, setBooking] = useState(null);

  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);

  const [form, setForm] = useState(EMPTY_FORM);
  const [consultationId, setConsultationId] = useState(null);
  const [dbStatus, setDbStatus] = useState(null);
  const [sessionDate, setSessionDate] = useState(todayIso());
  const [phase, setPhase] = useState('active'); // 'active' | 'review'
  const [finalProcessing, setProcessing] = useState(null); // 'final': the phone's "generate final summary" call
  const [queue, setQueue] = useState([]); // desktop: recordings not yet safely uploaded AND transcribed
  const queueRef = useRef(queue);
  queueRef.current = queue;
  const [transcribed, setTranscribed] = useState([]); // audio paths already transcribed (per path, persisted per consultation)
  const transcribedRef = useRef(transcribed);
  transcribedRef.current = transcribed;
  const savingRef = useRef(false);
  const [autoStopMsg, setAutoStopMsg] = useState(null);
  const stageRef = useRef('ready'); // the current stage, readable from async callbacks
  const [syncRetry, setSyncRetry] = useState(0);
  const syncFailsRef = useRef(0);
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
  const [savedAt, setSavedAt] = useState(null); // when the note was last saved to the chart (this session, or the row's updated_at)
  const [lastSyncAt, setLastSyncAt] = useState(null);

  // What the page is busy with: the phone's final-summary call, or any recording still going through upload → transcribe.
  const processing = finalProcessing ?? (queueBusy(queue) ? 'transcribing' : null);
  // Uploaded recordings that were never transcribed (a failed transcription, then a reload): offered for retry, per path.
  const orphanCount = untranscribedPaths(form.audioPaths, transcribed).filter((pth) => !queue.some((q) => q.audioPath === pth)).length;
  const acceptRecordingRef = useRef(null);
  const recorder = useAudioRecorder({
    onSegment: (r) => acceptRecordingRef.current?.(r), // a long recording hit the size cap and was split: each part is its own queued recording
    onAutoStop: (r) => acceptRecordingRef.current?.(r, { auto: true }), // microphone unplugged / call interruption: keep what was captured
  });
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
    setSavedAt(row.status === 'completed' && row.updated_at ? new Date(row.updated_at) : null);
    setTranscribed(readTranscribed(row.id) ?? seedTranscribed(next.audioPaths, next.transcript));
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
    createPhonePairing({ purpose: 'verify' }).then(({ shortCode, expiresAt, error }) => {
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
      // Recordings that arrive from the other device are transcribed by that device: don't transcribe them again here.
      const arrived = (row.audio_paths || []).filter((p) => !before.audioPaths.includes(p) && !queueRef.current.some((q) => q.audioPath === p));
      if (arrived.length) { const next = [...transcribedRef.current, ...arrived]; setTranscribed(next); writeTranscribed(row.id, next); }
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
        // "Not saved — will retry" is a real retry: back off 2s, 4s, 8s … up to 30s, then run this effect again.
        syncFailsRef.current += 1;
        const wait = Math.min(30000, 1000 * 2 ** syncFailsRef.current);
        setTimeout(() => setSyncRetry((n) => n + 1), wait);
        return;
      }
      syncFailsRef.current = 0;
      const next = { ...syncedRef.current };
      keys.forEach((k) => { next[k] = pushed[k]; });
      syncedRef.current = next;
      setLastSyncAt(new Date());
      setSyncState(changedKeys(formRef.current, next).length === 0 ? 'synced' : 'saving');
    }, 600);
    return () => clearTimeout(t);
  }, [form, loaded, consultationId, syncRetry]);

  // Back returns to wherever the doctor came from (dashboard, booking list or
  // booking page). Only when the page was opened directly (e.g. from the phone
  // QR code) is there nothing to go back to, so fall back to the dashboard.
  const goBack = () => {
    if (window.history.state?.idx > 0) navigate(-1);
    else navigate(`/${orgSlug}/dashboard`);
  };

  // Recording pipeline (upload → transcribe, queued and retryable) is shared by the computer and the phone: see runQueueItem below.

  const handleStart = async () => {
    setNotice(null);
    await recorder.start();
  };

  const handleStop = async () => {
    const result = await recorder.stop();
    if (result) acceptRecordingRef.current?.(result);
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

  // The phone's "final summary" uses the same structured pipeline as the desktop (mode 'note'): one note format everywhere.
  // Private notes (additional_notes) are never sent.
  const generateFinal = async () => {
    setError(null);
    setProcessing('final');
    const f = formRef.current;
    const { note: aiNote, error: aiError } = await summarizeConsultation({
      mode: 'note', transcript: f.transcript, xrayAnalysis: f.xrayAnalysis, photoAnalysis: f.photoAnalysis,
    });
    setProcessing(null);
    const drafted = aiNote ? normalizeNote(aiNote) : null;
    if (aiError || !drafted || isNoteEmpty(drafted)) {
      setError(aiError?.message || "The AI didn't return a note. Try again, or write it yourself.");
      return;
    }
    patchForm({ finalSummary: noteToMarkdown(drafted) });
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
    const sentForm = formRef.current; // what is being saved; anything typed after this is kept (see mergeAfterSave)
    savingRef.current = true;
    setSaving(true);
    setError(null);
    setNotice(null);
    const { data, error: saveError, noteError } = await saveConsultation({
      booking,
      consultationId,
      fields: { ...allColumns(form), session_date: sessionDate },
      status: 'completed',
    });
    savingRef.current = false;
    setSaving(false);
    if (saveError) {
      setError(`Could not save the consultation: ${saveError.message}`);
      return false;
    }
    const savedForm = formFromRow(data);
    syncedRef.current = savedForm;
    setForm(mergeAfterSave(sentForm, formRef.current, savedForm)); // never wipe edits typed while the request was in flight
    setLastSavedJson(JSON.stringify(allColumns(savedForm)));
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


  // ───────────────────────── Desktop consultation page (one page, six stages) ─────────────────────────
  const [flow, dispatchFlow] = useReducer(flowReducer, initialFlow);
  const [consent, setConsent] = useState(false); // UI only, per consultation. It is deliberately not stored (that needs a DB column).
  const [noteView, setNoteView] = useState('note');
  const [note, setNote] = useState(emptyNote);
  const noteRef = useRef(note);
  noteRef.current = note;
  const [record, setRecord] = useState(null); // getPatientRecord: rail + previous plan
  const [imageBusy, setImageBusy] = useState(null);
  const [imageError, setImageError] = useState(null);
  const [completing, setCompleting] = useState(false);
  const [toast, setToast] = useState(null); // { msg, link }
  const draftMdRef = useRef('');

  // The structured note lives in a local object (so typing a trailing space isn't trimmed away) and is stored as markdown in
  // final_summary. When the markdown changes from outside (a draft, the other device, a reload) the object follows.
  useEffect(() => {
    if (form.finalSummary !== noteToMarkdown(noteRef.current)) setNote(markdownToNote(form.finalSummary));
  }, [form.finalSummary]);
  const hasNote = !isNoteEmpty(note);
  const editNote = useCallback((key, value) => {
    const next = { ...noteRef.current, [key]: value };
    setNote(next);
    patchForm({ finalSummary: noteToMarkdown(next) });
  }, [patchForm]);

  useEffect(() => {
    if (!booking?.customer_id) return undefined;
    let off = false;
    getPatientRecord(booking.customer_id).then(({ data }) => { if (!off && data) setRecord(data); });
    return () => { off = true; };
  }, [booking?.customer_id]);

  // The previous consultation's plan: shown in the rail and given to the AI as context only.
  const lastPlan = useMemo(() => {
    const prev = (record?.consultations || []).find((c) => c.id !== consultationId && (c.final_summary || '').trim());
    if (!prev) return '';
    const plan = parseSummarySections(prev.final_summary).plan;
    return plan.split('\n').map((l) => l.replace(/^\s*[-*•]\s*/, '').trim()).filter(Boolean).join('; ');
  }, [record, consultationId]);

  const sourcesText = (f) => {
    const parts = ['the conversation'];
    if (f.xrayPaths.length && f.xrayAnalysis.trim()) parts.push(`${f.xrayPaths.length} X-ray${f.xrayPaths.length === 1 ? '' : 's'}`);
    if (f.photoPaths.length && f.photoAnalysis.trim()) parts.push(`${f.photoPaths.length} photo${f.photoPaths.length === 1 ? '' : 's'}`);
    return parts.length > 1 ? `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}` : parts[0];
  };

  // Draft the six-section note from the transcript + X-ray/photo analyses (+ the previous plan as context). Private notes are never sent.
  // A draft that arrives after the note was saved (or while Save is in flight) is DISCARDED: it must never overwrite a saved note.
  const runDraft = useCallback(async () => {
    dispatchFlow({ type: 'DRAFT_START' });
    const f = formRef.current;
    const { note: aiNote, error: aiError } = await summarizeConsultation({
      mode: 'note', transcript: f.transcript, xrayAnalysis: f.xrayAnalysis, photoAnalysis: f.photoAnalysis, previousPlan: lastPlan,
    });
    const drafted = aiNote ? normalizeNote(aiNote) : null;
    if (aiError || !drafted || isNoteEmpty(drafted)) {
      dispatchFlow({ type: 'FAILED', at: 'drafting', error: aiError || { code: 'AI_FAILED', message: "The AI didn't return a note. Your recording is saved; try again." } });
      return false;
    }
    if (savingRef.current || stageRef.current === 'saved') {
      dispatchFlow({ type: 'DRAFT_DISCARDED' });
      setToast({ msg: 'A new AI draft arrived after you saved, so it was not applied. Press Edit note, then Redraft, to use it.' });
      return false;
    }
    const md = noteToMarkdown(drafted);
    draftMdRef.current = md;
    setNote(drafted);
    patchForm({ finalSummary: md });
    dispatchFlow({ type: 'DRAFTED', at: new Date(), inputs: draftInputsKey(f), sources: { recordings: f.audioPaths.length, language: f.language, xrays: f.xrayAnalysis.trim() ? f.xrayPaths.length : 0, photos: f.photoAnalysis.trim() ? f.photoPaths.length : 0 } });
    return true;
  }, [lastPlan, patchForm]);

  const markTranscribed = useCallback((path) => {
    const next = [...new Set([...transcribedRef.current, path])];
    setTranscribed(next);
    transcribedRef.current = next;
    if (consultationId) writeTranscribed(consultationId, next);
  }, [consultationId]);

  // Recordings go through a QUEUE, one at a time and in order: upload → transcribe. Each stays queued until it is both uploaded and
  // transcribed, so a failure never overwrites another failure and nothing is lost. When the queue drains, the note is drafted
  // (or, if a draft already exists, "Update the draft" is offered by the staleness check).
  const chainRef = useRef(Promise.resolve());
  const runQueueItem = useCallback(async (itemId) => {
    const item = queueRef.current.find((q) => q.id === itemId);
    if (!item) return;
    setError(null);
    const patchItem = (patch) => { queueRef.current = updateQueue(queueRef.current, itemId, patch); setQueue(queueRef.current); };
    let audioPath = item.audioPath;
    if (!audioPath) {
      dispatchFlow({ type: 'UPLOAD_START' });
      patchItem({ status: 'uploading', error: null });
      const { path, error: upError } = await uploadConsultationFile(bookingId, item.blob, 'audio');
      if (upError) {
        patchItem({ status: 'failed-upload', error: upError.message });
        dispatchFlow({ type: 'UPLOAD_FAILED', error: { code: 'UPLOAD_FAILED', message: `Recording not uploaded yet: ${upError.message}` } });
        return;
      }
      audioPath = path;
      patchItem({ audioPath: path, status: 'transcribing' });
      setForm((f) => ({ ...f, audioPaths: f.audioPaths.includes(path) ? f.audioPaths : [...f.audioPaths, path], durationSeconds: f.durationSeconds + (item.durationSeconds || 0) }));
      dispatchFlow({ type: 'UPLOADED', seconds: item.durationSeconds });
    } else {
      patchItem({ status: 'transcribing', error: null });
      dispatchFlow({ type: 'TRANSCRIBE_START' });
      dispatchFlow({ type: 'UPLOADED', seconds: item.durationSeconds ?? formRef.current.durationSeconds });
    }
    const { text, language, error: tError } = await transcribeConsultationAudio(audioPath);
    if (tError) {
      patchItem({ status: 'failed-transcribe', error: tError.message });
      dispatchFlow({ type: 'FAILED', at: 'transcribing', error: tError });
      return;
    }
    markTranscribed(audioPath);
    dispatchFlow({ type: 'TRANSCRIBED', language });
    const transcript = [formRef.current.transcript, text].filter(Boolean).join('\n\n');
    formRef.current = { ...formRef.current, transcript, language: language || formRef.current.language };
    patchForm({ transcript, language: language || formRef.current.language });
    queueRef.current = queueRef.current.filter((q) => q.id !== itemId); // done: uploaded AND transcribed
    setQueue(queueRef.current);
    if (queueBusy(queueRef.current)) return; // more recordings are still queued behind this one
    if (phoneView) { dispatchFlow({ type: 'TRANSCRIPT_ONLY', language }); return; } // the phone only captures: the computer drafts the note
    if (!isNoteEmpty(noteRef.current)) { dispatchFlow({ type: 'TRANSCRIPT_ONLY', language }); return; }
    await runDraft();
  }, [bookingId, patchForm, runDraft, markTranscribed, phoneView]);

  const submitToQueue = useCallback((item) => {
    queueRef.current = enqueue(queueRef.current, item);
    setQueue(queueRef.current);
    chainRef.current = chainRef.current.then(() => runQueueItem(item.id)).catch(() => {});
  }, [runQueueItem]);

  // A finished recording (stopped, a size-cap segment, or an auto-stop): into the queue.
  acceptRecordingRef.current = (result, { auto = false } = {}) => {
    if (!result?.blob || result.blob.size === 0) return;
    if (auto) setAutoStopMsg('The recording stopped by itself (microphone unplugged or interrupted). What was captured has been kept and is being saved.');
    submitToQueue(newQueueItem(result));
  };

  const handleStopDesk = async () => {
    const result = await recorder.stop();
    if (result) acceptRecordingRef.current(result);
  };

  // "Try again": retry EVERY failed recording (including ones left from before a reload: any uploaded path never transcribed), else redraft.
  const retryDraft = useCallback(async () => {
    const failed = failedItems(queueRef.current);
    const orphans = untranscribedPaths(formRef.current.audioPaths, transcribedRef.current)
      .filter((pth) => !queueRef.current.some((q) => q.audioPath === pth));
    if (failed.length === 0 && orphans.length === 0) { if (!phoneView) await runDraft(); return; }
    orphans.forEach((pth) => submitToQueue(newQueueItem({ blob: null, mimeType: 'audio/webm', durationSeconds: null, audioPath: pth })));
    failed.forEach((q) => { chainRef.current = chainRef.current.then(() => runQueueItem(q.id)).catch(() => {}); });
  }, [runDraft, runQueueItem, submitToQueue, phoneView]);

  const redraft = () => {
    const edited = draftMdRef.current && noteToMarkdown(noteRef.current) !== draftMdRef.current;
    if (hasNote && (edited || !draftMdRef.current) && !window.confirm('Redrafting replaces the note, including your edits. Continue?')) return;
    runDraft();
  };

  // The phone finished recording on its own: its transcript arrives through sync. Draft from it, or offer to update the draft.
  const prevRemoteRef = useRef(null);
  useEffect(() => {
    const was = prevRemoteRef.current;
    prevRemoteRef.current = remote ? remote.state : null;
    if (phoneView || !was || remote) return;
    if (!formRef.current.transcript.trim() || flow.step !== 'idle') return;
    if (isNoteEmpty(noteRef.current)) runDraft();
  }, [remote, phoneView, flow.step, runDraft]);

  const addImages = useCallback(async (kind, files) => {
    const busyCb = kind === 'xray' ? onXrayBusy : onPhotoBusy;
    const pathsKey = kind === 'xray' ? 'xrayPaths' : 'photoPaths';
    const analysisKey = kind === 'xray' ? 'xrayAnalysis' : 'photoAnalysis';
    setImageError(null);
    setImageBusy('uploading'); busyCb('uploading');
    const uploaded = [];
    for (const file of files) {
      const { path, error: upError } = await uploadConsultationFile(bookingId, await resizeImageFile(file), 'image');
      if (upError) setImageError(`${file.name}: ${upError.message}`); else uploaded.push(path);
    }
    if (!uploaded.length) { setImageBusy(null); busyCb(null); return; }
    patchForm({ [pathsKey]: [...formRef.current[pathsKey], ...uploaded] });
    setImageBusy('analyzing'); busyCb('analyzing');
    const { analysis, error: aiError } = await analyzeConsultationImages(kind, uploaded);
    setImageBusy(null); busyCb(null);
    if (aiError) { setImageError(`${aiError.message} The images are attached.`); return; }
    const cur = formRef.current[analysisKey];
    patchForm({ [analysisKey]: cur ? `${cur}\n\n---\n\n${analysis}` : analysis });
  }, [bookingId, onXrayBusy, onPhotoBusy, patchForm]);

  const saveToChart = async () => {
    const ok = await handleSave();
    if (ok) { setSavedAt(new Date()); dispatchFlow({ type: 'SAVED' }); }
  };

  // Edit note: the row goes back to 'draft' so edits are drafts until Save (an abandoned edit never silently changes a saved note's status).
  const editSavedNote = async () => {
    if (consultationId) {
      const { error: draftError } = await updateConsultationColumns(consultationId, { status: 'draft' });
      if (draftError) { setError('Could not reopen the note for editing. Try again.'); return; }
      setDbStatus('draft');
    }
    dispatchFlow({ type: 'EDIT_NOTE' });
  };

  const completeVisit = async () => {
    setCompleting(true);
    const { error: stError } = await updateBookingStatus({ bookingId, newStatus: 'Completed' });
    if (stError) { setCompleting(false); setError(stError.message || 'Could not complete the visit.'); return; }
    const { data } = await fetchBookingById(bookingId);
    if (data) setBooking(data);
    setCompleting(false);
    setToast({ msg: `Visit completed. It can now be billed.`, link: true });
  };

  const stage = deriveStage(flow, { recording: recorder.isRecording || (!!remote && remote.state !== 'idle' && remote.state !== 'processing'), hasNote, saved: dbStatus === 'completed' });
  stageRef.current = stage;
  const bookingInProgress = booking?.status === 'In-Progress';
  // Leaving would lose audio while recording, or while any recording has not been uploaded yet.
  useLeaveGuard(recorder.isRecording || hasUnuploaded(queue), 'A recording has not been saved yet. If you leave now, it will be lost. Stop and let it upload first.');
  useEffect(() => { if (!toast) return undefined; const t = setTimeout(() => setToast(null), 8000); return () => clearTimeout(t); }, [toast]);

  const userName = profile?.full_name || 'you';
  const hhmm = (d) => (d ? d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }) : '');

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

            {autoStopMsg && (
              <div role="alert" className="p-3 bg-warning/10 border border-warning/30 rounded-md text-sm text-text-secondary flex items-start gap-2">
                <Icon name="AlertTriangle" size={16} className="text-warning mt-0.5 shrink-0" />
                <span className="flex-1">{autoStopMsg}</span>
                <button type="button" onClick={() => setAutoStopMsg(null)} aria-label="Dismiss"><Icon name="X" size={14} className="text-text-tertiary" /></button>
              </div>
            )}
            {(failedItems(queue).length > 0 || orphanCount > 0) && processing === null && (
              <div role="alert" className="p-3 bg-error/5 border border-error/20 rounded-md flex items-start gap-2">
                <Icon name="AlertCircle" size={16} className="text-error mt-0.5 shrink-0" />
                <div className="flex-1 text-sm text-text-secondary">
                  {hasUploadFailure(queue)
                    ? 'A recording has not been uploaded yet. Keep this page open.'
                    : failedItems(queue).length > 0
                      ? "A recording couldn't be transcribed. It is saved."
                      : `${orphanCount} recording${orphanCount === 1 ? '' : 's'} not transcribed yet.`}
                  <button type="button" className="ml-2 text-primary font-medium" onClick={retryDraft}>Retry</button>
                </div>
              </div>
            )}
            {error && (
              <div className="p-3 bg-error/5 border border-error/20 rounded-md flex items-start gap-2">
                <Icon name="AlertCircle" size={16} className="text-error mt-0.5 shrink-0" />
                <div className="flex-1 text-sm text-text-secondary">
                  {error}
                  {(failedItems(queue).length > 0 || orphanCount > 0) && (
                    <button type="button" className="ml-2 text-primary font-medium" disabled={busy} onClick={retryDraft}>Retry</button>
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
                <Card title="Private notes (staff only)" icon="StickyNote">
                  <TextArea value={form.additionalNotes} onChange={(v) => patchForm({ additionalNotes: v })} rows={4}
                            placeholder="Staff only. Not part of the clinical note or the AI draft." />
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

  const patientFirst = (booking?.customer_name || 'The patient').trim().split(/\s+/)[0];
  const fmtLongDate = new Date(`${sessionDate}T00:00:00`).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
  const timeRange = booking ? [booking.start_time, booking.end_time].filter(Boolean).map((t) => String(t).slice(0, 5)).join(' – ') : '';
  const metaLine = booking ? [booking.treatment?.name || booking.treatment_name_snapshot, booking.dentist?.name || booking.dentist_name_snapshot, `${fmtLongDate}${timeRange ? `, ${timeRange}` : ''}`, booking.booking_number].filter(Boolean).join('  ·  ') : '';
  const inClinic = booking?.status === 'In-Progress';

  const syncText = stage === 'saved' && savedAt ? `Saved to chart ${hhmm(savedAt)}`
    : syncState === 'error' ? 'Not saved — will retry'
    : syncState === 'saving' ? 'Saving…'
    : lastSyncAt ? `Saved ${hhmm(lastSyncAt)}` : (form.audioPaths.length || hasNote ? 'Saved' : '');
  const readOnlyRole = profile?.role === 'admin_viewer';
  const drafting = stage === 'drafting';
  const noAiBanner = stage === 'noai' && showNoAiBanner(flow, hasNote);
  const edited = !!draftMdRef.current && noteToMarkdown(note) !== draftMdRef.current;
  const badge = flow.aiDrafted && hasNote
    ? (stage === 'saved' ? `Drafted with AI · reviewed by ${userName}` : 'AI draft · check before saving')
    : null;
  const src = flow.draftSources;
  const footer = flow.aiDrafted && flow.draftedAt && src && (stage === 'review' || stage === 'saved')
    ? `Drafted ${hhmm(flow.draftedAt)} from ${src.recordings} recording${src.recordings === 1 ? '' : 's'}${src.language ? ` (${src.language}, auto-detected)` : ''}${src.xrays ? `, ${src.xrays} X-ray${src.xrays === 1 ? '' : 's'}` : ''}${src.photos ? ` and ${src.photos} photo${src.photos === 1 ? '' : 's'}` : ''}`
    : null;
  const findingsTags = [form.xrayAnalysis.trim() && form.xrayPaths.length && `${form.xrayPaths.length} X-ray${form.xrayPaths.length === 1 ? '' : 's'}`, form.photoAnalysis.trim() && form.photoPaths.length && `${form.photoPaths.length} photo${form.photoPaths.length === 1 ? '' : 's'}`].filter(Boolean);
  const recorderError = recorder.error;
  const showDraftNow = stage === 'ready' && (form.audioPaths.length > 0 || form.transcript.trim());
  const pdf = () => generateConsultationPdf({ ...reportData, additionalNotes: undefined }, profile?.organizations?.name);

  return (
    <AppShell
      variant="page"
      header={shellHeader}
      aside={<AIAssistantPanel />}
      asideOpen={assistantOpen}
      floating={
        <>
          {toast && (
            <div role="status" className="fixed bottom-6 left-1/2 -translate-x-1/2 z-modal-overlay px-4 py-2.5 rounded-lg bg-[#0E0D0C] text-white text-[13px] shadow-lg flex items-center gap-3">
              <Icon name="CheckCircle" size={16} className="text-[#6EE7B7]" />{toast.msg}
              {toast.link && <button type="button" onClick={() => navigate(`/${orgSlug}/dashboard?view=calendar`)} className="underline font-medium">Back to calendar</button>}
              <button type="button" onClick={() => setToast(null)} aria-label="Dismiss"><Icon name="X" size={14} className="text-white/70" /></button>
            </div>
          )}
          {showPhone && <PhoneHandoff orgSlug={orgSlug} bookingId={bookingId} onClose={closeHandoff} phoneCount={link.phones.length} phoneLabel={link.phones[0]?.label} />}
        </>
      }
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
        <div className="max-w-[1240px] pb-6 lg:pb-0">
          <DeskHeader
            patientName={booking.customer_name} inClinic={inClinic} meta={metaLine} onBack={goBack}
            syncText={syncText} syncKind={syncState} onContinuePhone={() => setShowPhone(true)}
            stage={stage} canSave={hasNote && !busy && flow.step === 'idle' && !queueBusy(queue) && !hasUnuploaded(queue)} saving={saving} onSave={saveToChart}
            onEdit={editSavedNote} canComplete={bookingInProgress} completing={completing} onComplete={completeVisit}
            readOnly={readOnlyRole}
            menuItems={[{ label: 'Download PDF report', onClick: pdf, disabled: !canReport }]}
          />

          {phoneCode && !link.phones.some((p) => p.bookingId === bookingId) && <div className="mt-4"><PhoneCodeBanner initial={phoneCode} via={phoneCode.via} /></div>}
          {link.phones.some((p) => p.bookingId && p.bookingId !== bookingId) && (
            <div className="mt-4 p-3 bg-[#FFFAF0] border border-[#F5D9A8] rounded-lg flex flex-wrap items-center justify-between gap-2 text-[13px]">
              <span className="flex items-center gap-2"><Icon name="AlertTriangle" size={15} className="text-[#B45309]" />Your phone is on a different patient, so recordings and photos won’t appear here.</span>
              <button type="button" onClick={() => link.openOnPhone(bookingId, { autoStart: false })} className="h-7 px-2.5 rounded-md border border-[#E8C98C] bg-white text-[12.5px] font-medium">Open this patient on the phone</button>
            </div>
          )}
          {booking.status !== 'In-Progress' && booking.status !== 'Completed' && (
            <div className="mt-4 p-3 bg-[#FFFAF0] border border-[#F5D9A8] rounded-lg text-[13px] flex items-center gap-2"><Icon name="AlertTriangle" size={15} className="text-[#B45309]" />This booking is {booking.status}. Consultations are normally started once the booking is In-Progress.</div>
          )}
          {stage === 'saved' && bookingInProgress && (
            <div role="status" className="mt-4 px-4 py-2.5 rounded-lg border border-[#BFE6D3] bg-[#F1FBF6] text-[13px] flex items-start sm:items-center gap-2"><Icon name="Check" size={15} className="text-[#1F9D6C] shrink-0" />
              <span><b className="font-medium text-[#0F5F40]">Note saved to {patientFirst}’s chart</b> by {userName} at {hhmm(savedAt)}. The visit is still in progress: complete it when {patientFirst} leaves, so it can be billed.</span></div>
          )}
          {error && (
            <div className="mt-4 p-3 bg-error/5 border border-error/20 rounded-lg flex items-start gap-2 text-[13px]">
              <Icon name="AlertCircle" size={15} className="text-error mt-0.5 shrink-0" />
              <div className="flex-1 text-text-secondary">{error}</div>
              <button onClick={() => setError(null)} aria-label="Dismiss"><Icon name="X" size={14} className="text-text-tertiary" /></button>
            </div>
          )}
          {autoStopMsg && (
            <div role="alert" className="mt-4 p-3 bg-[#FFFAF0] border border-[#F5D9A8] rounded-lg text-[13px] flex items-center gap-2"><Icon name="AlertTriangle" size={15} className="text-[#B45309] shrink-0" /><span className="flex-1">{autoStopMsg}</span><button type="button" onClick={() => setAutoStopMsg(null)} aria-label="Dismiss"><Icon name="X" size={14} className="text-[#8A8A90]" /></button></div>
          )}
          {received && <div className="mt-4 p-3 bg-[#F1FBF6] border border-[#BFE6D3] rounded-lg text-[13px] flex items-center gap-2"><Icon name="Download" size={15} className="text-[#1F9D6C]" />{received}</div>}

          <div className="mt-5 grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_320px] gap-5 items-start">
            <div className="space-y-4 min-w-0">
              {stage === 'drafting' ? (
                <section aria-label="Drafting progress" className="rounded-xl border border-border bg-white px-5 py-4 flex items-center gap-4">
                  <span className="w-14 h-14 rounded-full bg-[#F1F1F3] grid place-items-center flex-shrink-0"><Icon name="Mic" size={20} className="text-[#515152]" /></span>
                  <ul className="space-y-1.5 text-[13.5px]">
                    {draftingSteps(flow, { sources: sourcesText(form) }).map((st) => (
                      <li key={st.key} className="flex items-center gap-2.5">
                        {st.state === 'done' ? <span className="w-[18px] h-[18px] rounded-full bg-[#1F9D6C] grid place-items-center"><Icon name="Check" size={11} className="text-white" /></span>
                          : st.state === 'active' ? <span className="w-[18px] h-[18px] rounded-full border-2 border-primary border-t-transparent animate-spin" />
                          : <span className="w-[18px] h-[18px] rounded-full border border-[#D6D6DB]" />}
                        <span className={st.state === 'todo' ? 'text-[#8A8A90]' : ''}>{st.label}</span>
                      </li>
                    ))}
                  </ul>
                </section>
              ) : (
                <RecorderBar
                  firstName={patientFirst} consent={consent} onConsent={setConsent} recorder={recorder} remote={remote} remotePhoneLabel={remotePhone?.label}
                  locked={stage === 'saved'} phones={phones} processing={processing} audioPaths={form.audioPaths} durationSeconds={form.durationSeconds}
                  onStart={handleStart} onStop={handleStopDesk} onRecordOnPhone={() => sendCommand({ action: 'start', target: phones[0]?.deviceId })}
                  onStopRemote={() => sendCommand({ action: 'stop', target: remote?.from })} onContinueOnPhone={() => setShowPhone(true)} errorText={recorderError}
                />
              )}
              {recorder.isRecording && (
                <p className="text-[12.5px] text-[#8A8A90] -mt-2 flex items-center gap-1.5"><Icon name="Lock" size={12} />Keep this page open while recording. If you try to leave, you’ll be asked to stop first so nothing is lost.</p>
              )}
              {(flow.aiError || (orphanCount > 0 && flow.step === 'idle' && !queueBusy(queue))) && stage !== 'noai' && stage !== 'drafting' && !(stage === 'ready' && !flow.aiError) && (
                <div role="alert" className="rounded-lg border border-[#F5D9A8] bg-[#FFFAF0] px-4 py-2.5 text-[13px] flex items-center gap-2 flex-wrap">
                  <Icon name="AlertTriangle" size={15} className="text-[#B45309]" />
                  <span className="text-[#7A4A06]">{hasUploadFailure(queue) ? 'Recording not uploaded yet.' : flow.aiError ? (flow.aiError.message || 'The AI step failed.') : `${orphanCount} recording${orphanCount === 1 ? '' : 's'} not transcribed yet.`}</span>
                  <button type="button" onClick={retryDraft} disabled={flow.step !== 'idle'} className="underline font-medium text-[#7A4A06] disabled:opacity-60">{hasUploadFailure(queue) ? 'Retry' : flow.aiError ? 'Try again' : 'Transcribe'}</button>
                </div>
              )}
              <NoteCard
                stage={stage} note={note} onNoteChange={editNote} view={noteView} onView={setNoteView}
                transcript={form.transcript} onTranscript={(v) => patchForm({ transcript: v })} hasTranscript={!!form.transcript.trim()}
                badge={badge} drafting={drafting} noAiBanner={noAiBanner} noAiKind={hasUploadFailure(queue) ? 'upload' : 'ai'} onTryAgain={retryDraft} tryAgainBusy={flow.step !== 'idle'}
                readOnly={stage === 'saved' || readOnlyRole} findingsTags={findingsTags} footer={footer} onRedraft={flow.aiDrafted && stage === 'review' && !readOnlyRole ? redraft : null}
                updateDraftOffer={stage === 'review' && hasNote && draftIsStale(flow, draftInputsKey(form), { readOnly: readOnlyRole })} onUpdateDraft={redraft}
                onWriteMyself={() => dispatchFlow({ type: 'WRITE_MYSELF' })} earlierDoctorNotes={form.doctorNotes.trim() ? form.doctorNotes : ''}
                onDraftNow={showDraftNow ? retryDraft : null}
              />
            </div>
            <ConsultationRail
              booking={booking} record={record} lastPlan={lastPlan} xrayPaths={form.xrayPaths} photoPaths={form.photoPaths}
              imageBusy={imageBusy || remoteActivity.xray || remoteActivity.photo} imageError={imageError} onAddImages={addImages}
              privateNotes={form.additionalNotes} onPrivateNotes={(v) => patchForm({ additionalNotes: v })}
              onOpenChart={() => window.open(`/${orgSlug}/patients/${booking.customer_id}`, '_blank', 'noopener')}
              readOnly={readOnlyRole} phoneLinked={link.phones.length > 0}
            />
          </div>
        </div>
      )}
    </AppShell>
  );
};

export default ConsultationPage;
