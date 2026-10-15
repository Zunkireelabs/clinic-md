import React, { useState, useEffect, useRef, useCallback } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import Icon from '../../components/AppIcon';
import ConsultationPage from './index';
import ConsultationHistory from './components/ConsultationHistory';
import ConsultationDetail from './components/ConsultationDetail';
import useDoctorPhoneLink from '../../hooks/useDoctorPhoneLink';
import useWakeLock from '../../hooks/useWakeLock';
import usePushNotifications from '../../hooks/usePushNotifications';
import VerifyCode from './components/VerifyCode';
import DoctorHero, { ToothArt } from './components/DoctorHero';
import LockedHome from './components/LockedHome';
import usePhoneLock from '../../hooks/usePhoneLock';
import { isPhoneUnlocked } from '../../utils/phoneSession';
import { parseOpenTarget } from '../../utils/openTarget';
import useInstallPrompt from '../../hooks/useInstallPrompt';
import { useAuth } from '../../contexts/AuthContext';
import { deviceLabel } from '../../utils/remoteDevices';
import { fetchInProgressBookings } from '../../services/api';
import { decideOpenAction } from '../../utils/doctorPhonePick';

// "Doctor phone" page. Log in on the phone once and leave this page open: when
// a consultation is started on the computer (same login) it opens that patient
// here and, if asked, starts recording. The consultation is rendered inside
// this page (not navigated to) so the link to the computer stays connected.
const DoctorPhone = () => {
  const { orgSlug } = useParams();
  const [searchParams, setSearchParams] = useSearchParams();
  const { profile } = useAuth();
  const [closed, setClosed] = useState(false);
  const [flash, setFlash] = useState(null); // e.g. "Suraj Basnet marked Completed"
  const wake = useWakeLock(!closed);
  const push = usePushNotifications(profile);
  const installApp = useInstallPrompt();
  const phoneLock = usePhoneLock();
  const [installOs, setInstallOs] = useState(null); // 'ios' | 'android' tab in the Add to Home Screen card
  const [askingCode, setAskingCode] = useState(false); // the doctor chose to ask the computer for a code
  const activeShownRef = useRef(false); // a patient screen is open (and must stay mounted if the phone locks mid-recording)

  // Remember the clinic so the Home Screen icon can find its way back after signing out.
  useEffect(() => {
    if (orgSlug) { try { localStorage.setItem('clinicmd-phone-org', orgSlug); } catch { /* ignore */ } }
  }, [orgSlug]);

  // A QR code carries ?booking=<id> (open that patient); a notification adds
  //  (open and start recording).
  // A notification link also carries &verify=1: the phone then asks for the code
  // shown on the computer before opening the patient.
  const initialTarget = useRef(parseOpenTarget(searchParams)).current;
  const [pendingVerify, setPendingVerify] = useState(initialTarget?.verify && !isPhoneUnlocked() ? initialTarget : null);
  const [active, setActive] = useState(() => (
    initialTarget && (!initialTarget.verify || isPhoneUnlocked())
      ? { bookingId: initialTarget.bookingId, nonce: 0 }
      : null
  ));

  // Drop ?booking=… from the address once it has been read. Otherwise "Add to
  // Home Screen" from this page could bake one old patient into the icon.
  useEffect(() => {
    if (searchParams.get('booking') || searchParams.get('autostart') || searchParams.get('verify')) setSearchParams({}, { replace: true });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Tapping a notification while the app is open: the service worker tells this page
  // which patient to open (and whether to start recording).
  useEffect(() => {
    if (!('serviceWorker' in navigator)) return undefined;
    const onMessage = (event) => {
      const data = event.data;
      if (data?.type !== 'open-consultation' || !data.bookingId) return;
      suppressAutoRef.current = true;
      setClosed(false); // a notification tap reopens the app
      setTab('now');
      setDetail(null);
      if (data.verify && !isPhoneUnlocked()) {
        // Come from a notification: ask for the computer's code before opening anything.
        setActive(null);
        setPendingVerify({ bookingId: data.bookingId});
      } else {
        setActive({ bookingId: data.bookingId, nonce: Date.now() });
      }
    };
    navigator.serviceWorker.addEventListener('message', onMessage);
    return () => navigator.serviceWorker.removeEventListener('message', onMessage);
  }, []);

  useEffect(() => {
    if (!flash) return undefined;
    const t = setTimeout(() => setFlash(null), 6000);
    return () => clearTimeout(t);
  }, [flash]);

  // Patients In-Progress now. Opening this page (e.g. from the home screen
  // icon) joins the only one automatically, or shows a list to pick from.
  const [inProgress, setInProgress] = useState([]);
  const [listLoading, setListLoading] = useState(true);
  const [tab, setTab] = useState('now'); // 'now' | 'history'
  const [detail, setDetail] = useState(null); // a past consultation opened from History
  const suppressAutoRef = useRef(!!searchParams.get('booking'));
  const activeRef = useRef(active);
  activeRef.current = active;

  const refreshList = useCallback(async () => {
    const { data } = await fetchInProgressBookings();
    setInProgress(data);
    setListLoading(false);
    if (activeRef.current) return;
    const action = decideOpenAction({ bookings: data, suppressAuto: suppressAutoRef.current });
    if (action.type === 'auto') {
      suppressAutoRef.current = true;
      setActive({ bookingId: action.bookingId, nonce: Date.now() });
    }
  }, []);

  useEffect(() => {
    refreshList();
    const onVisible = () => { if (document.visibilityState === 'visible') refreshList(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
  }, [refreshList]);

  // While closed the app leaves the link to the computer (notifications still work).
  const { devices } = useDoctorPhoneLink(closed ? null : profile?.id, {
    kind: 'doctor-phone',
    label: deviceLabel(),
    bookingId: active?.bookingId || null,
    // Work started on the computer: open the patient (asking for the code only if the phone is locked).
    onOpen: (p) => {
      suppressAutoRef.current = true;
      setClosed(false);
      // Already signed in by QR (or code) and not away for long: go straight in, no code.
      if (isPhoneUnlocked()) { setPendingVerify(null); setActive({ bookingId: p.bookingId, nonce: Date.now() }); return; }
      setActive(null);
      setPendingVerify({ bookingId: p.bookingId });
    },
    onClose: (p) => setActive((a) => (a?.bookingId === p.bookingId ? null : a)),
  });
  const computers = devices.filter((d) => d.kind === 'computer');

  // Closing the whole app. A web page cannot quit itself on iPhone, so this releases the
  // screen lock, disconnects from the computer and shows a closed screen to swipe away.
  const closeApp = () => {
    setActive(null);
    setClosed(true);
    try { window.close(); } catch { /* not allowed for this window: the closed screen stays */ }
  };

  if (!active) activeShownRef.current = false;
  else if (!phoneLock.locked) activeShownRef.current = true;

  // Locked: every fresh open of the app asks for the code first. (A patient screen that
  // was already open stays mounted behind the lock, so a recording is not lost.)
  if (phoneLock.locked && !activeShownRef.current && !pendingVerify) {
    return askingCode
      ? <VerifyCode askComputer onVerified={() => { phoneLock.unlock(); setAskingCode(false); }} onCancel={() => setAskingCode(false)} />
      : <LockedHome onAsk={() => setAskingCode(true)} />;
  }

  if (pendingVerify) {
    return (
      <VerifyCode
        onVerified={() => {
          phoneLock.unlock();
          setActive({ bookingId: pendingVerify.bookingId, nonce: Date.now() });
          setPendingVerify(null);
        }}
        onCancel={() => { suppressAutoRef.current = true; setPendingVerify(null); }}
      />
    );
  }

  if (closed) {
    return (
      <div className="min-h-screen bg-background flex items-center justify-center p-6">
        <div className="w-full max-w-sm text-center space-y-5">
          <div className="mx-auto w-16 h-16 rounded-full bg-gray-100 flex items-center justify-center">
            <Icon name="Power" size={28} className="text-text-secondary" />
          </div>
          <div>
            <h1 className="font-heading font-heading-semibold text-xl text-text-primary">Doctor app closed</h1>
            <p className="text-sm text-text-secondary mt-1">
              It is no longer connected to the computer and the screen can lock. You'll still get notifications.
            </p>
          </div>
          <p className="text-xs text-text-tertiary px-2">
            To close it completely, swipe up from the bottom of the screen and flick this app away.
          </p>
          <button type="button" onClick={() => setClosed(false)}
                  className="w-full py-3 rounded-lg bg-primary text-white text-sm font-medium">
            Open again
          </button>
        </div>
      </div>
    );
  }

  if (active) {
    return (
      <>
      {phoneLock.locked && (
        <div className="fixed inset-0 z-50 bg-background overflow-auto">
          {askingCode
            ? <VerifyCode askComputer onVerified={() => { phoneLock.unlock(); setAskingCode(false); }} onCancel={() => setAskingCode(false)} />
            : <LockedHome onAsk={() => setAskingCode(true)} />}
        </div>
      )}
      <ConsultationPage
        key={`${active.bookingId}-${active.nonce}`}
        bookingIdProp={active.bookingId}
        forcePhoneView
        onDone={(info) => {
          suppressAutoRef.current = true;
          setActive(null);
          if (info?.completed && info.patientName) setFlash(`${info.patientName} marked Completed`);
          refreshList();
        }}
        onSwitch={() => { suppressAutoRef.current = true; setActive(null); refreshList(); }}
      />
      </>
    );
  }

  return (
    <div className="min-h-screen bg-background pb-28">
      <DoctorHero
        name={profile?.full_name}
        clinic={profile?.organizations?.name}
        computerConnected={computers.length > 0}
        screenOn={wake.active}
      />
      <div className="w-full max-w-sm mx-auto text-center space-y-5 px-5 -mt-6 relative">
        {flash && (
          <div className="p-3 bg-success/10 border border-success/30 rounded-md text-sm text-text-primary flex items-center justify-between gap-2 text-left">
            <span className="flex items-center gap-2"><Icon name="CheckCircle" size={16} className="text-success shrink-0" /> {flash}</span>
            <button type="button" onClick={() => setFlash(null)} aria-label="Dismiss"><Icon name="X" size={14} className="text-text-tertiary" /></button>
          </div>
        )}
        <div className="grid grid-cols-2 gap-1 p-1 bg-white rounded-2xl shadow-md border border-gray-100">
          {[['now', 'Record'], ['history', 'History']].map(([id, label]) => (
            <button key={id} type="button" onClick={() => { setTab(id); setDetail(null); }}
                    className={`py-2.5 rounded-xl text-sm font-medium transition ${tab === id ? 'bg-primary text-white shadow-sm' : 'text-text-secondary'}`}>
              {label}
            </button>
          ))}
        </div>

        {tab === 'history' ? (
          detail ? (
            <ConsultationDetail
              row={detail}
              orgName={profile?.organizations?.name}
              onBack={() => setDetail(null)}
              onContinue={(row) => { suppressAutoRef.current = true; setDetail(null); setTab('now'); setActive({ bookingId: row.booking_id, nonce: Date.now() }); }}
            />
          ) : (
            <ConsultationHistory onOpen={setDetail} />
          )
        ) : (
        <>
        <div className="text-left">
          <p className="text-xs uppercase tracking-wider text-text-tertiary mb-2">Patients in progress</p>
          {listLoading ? (
            <p className="text-sm text-text-tertiary">Looking for patients…</p>
          ) : inProgress.length === 0 ? (
            <div className="bg-white rounded-2xl border border-dashed border-gray-300 p-6 text-center">
              <ToothArt className="w-16 h-20 mx-auto text-primary" />
              <p className="mt-2 text-sm font-medium text-text-primary">No patient in progress</p>
              <p className="text-xs text-text-tertiary mt-1">Start a booking on the computer and the patient appears here.</p>
            </div>
          ) : (
            <div className="space-y-2">
              {inProgress.map((b) => (
                <button
                  key={b.id}
                  type="button"
                  onClick={() => { suppressAutoRef.current = true; setActive({ bookingId: b.id, nonce: Date.now() }); }}
                  className="w-full text-left bg-white rounded-2xl border border-gray-200 shadow-sm active:scale-[0.99] hover:border-primary p-4 flex items-center gap-3"
                >
                  <span className="w-11 h-11 rounded-full bg-primary text-white flex items-center justify-center shrink-0"><Icon name="Mic" size={20} /></span>
                  <span className="min-w-0">
                    <span className="block text-base font-medium text-text-primary truncate">{b.customer_name}</span>
                    <span className="block text-xs text-text-tertiary truncate">{b.treatment_name_snapshot || 'Treatment'} · tap to record</span>
                  </span>
                </button>
              ))}
            </div>
          )}
        </div>

        <details className="text-left group">
          <summary className="flex items-center gap-3 cursor-pointer list-none bg-white rounded-2xl border border-gray-200 shadow-sm px-4 py-3.5 active:bg-gray-50">
            <span className="w-10 h-10 rounded-xl bg-primary/10 text-primary flex items-center justify-center shrink-0"><Icon name="Settings" size={20} /></span>
            <span className="min-w-0 flex-1">
              <span className="block text-sm font-medium text-text-primary">Phone setup</span>
              <span className="block text-xs text-text-tertiary">Home Screen icon · Notifications</span>
            </span>
            {push.subscribed && <span className="px-2 py-0.5 rounded-full bg-success/10 text-success text-[11px] font-medium">Notifications on</span>}
            <Icon name="ChevronDown" size={18} className="text-text-tertiary group-open:rotate-180 transition-transform shrink-0" />
          </summary>
          <div className="mt-3 space-y-3">
            {/* 1. Home Screen icon */}
            <div className="bg-white rounded-2xl border border-gray-200 shadow-sm overflow-hidden text-left">
              <div className="flex items-center gap-3 p-4">
                <span className="w-11 h-11 rounded-xl bg-gradient-to-br from-primary to-[#0a4d63] text-white flex items-center justify-center shrink-0"><Icon name="SquarePlus" size={22} /></span>
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium text-text-primary">Add to Home Screen</p>
                  <p className="text-xs text-text-tertiary">One tap from your Home Screen starts recording</p>
                </div>
                {installApp.standalone && <span className="px-2 py-0.5 rounded-full bg-success/10 text-success text-[11px] font-medium flex items-center gap-1"><Icon name="Check" size={11} /> Added</span>}
              </div>
              {!installApp.standalone && (
                <div className="px-4 pb-4 pt-3 border-t border-gray-100 space-y-3">
                  {(() => {
                    const os = installOs || (installApp.isIos ? 'ios' : 'android');
                    const steps = os === 'ios'
                      ? [
                        ['Share', 'Open this page in Safari, then tap the Share button at the bottom', 'Share'],
                        ['Add', 'Scroll down and tap “Add to Home Screen”', 'SquarePlus'],
                        ['Done', 'Tap “Add” — the Doctor icon appears on your Home Screen', 'Check'],
                      ]
                      : [
                        ['Menu', 'Open this page in Chrome, then tap the ⋮ menu (top right)', 'MoreVertical'],
                        ['Add', 'Tap “Install app” or “Add to Home screen”', 'SquarePlus'],
                        ['Done', 'Tap “Install” — the Doctor icon appears on your Home Screen', 'Check'],
                      ];
                    return (
                      <>
                        <div className="grid grid-cols-2 gap-1 p-1 bg-gray-100 rounded-xl">
                          {[['ios', 'iPhone'], ['android', 'Android']].map(([id, label]) => (
                            <button key={id} type="button" onClick={() => setInstallOs(id)}
                                    className={`py-1.5 rounded-lg text-xs font-medium transition ${os === id ? 'bg-white text-primary shadow-sm' : 'text-text-secondary'}`}>
                              {label}
                            </button>
                          ))}
                        </div>
                        {os === 'android' && installApp.canPrompt && (
                          <button type="button" onClick={installApp.install}
                                  className="w-full h-11 rounded-xl bg-primary text-white text-sm font-medium shadow-sm shadow-primary/30 active:scale-[0.98] transition">
                            Install Doctor app
                          </button>
                        )}
                        <ol className="space-y-2.5">
                          {steps.map(([t, d, icon], i) => (
                            <li key={t} className="flex items-center gap-3">
                              <span className="w-9 h-9 rounded-xl bg-primary/10 text-primary flex items-center justify-center shrink-0 relative">
                                <Icon name={icon} size={17} />
                                <span className="absolute -top-1.5 -left-1.5 w-4 h-4 rounded-full bg-primary text-white text-[10px] font-semibold flex items-center justify-center">{i + 1}</span>
                              </span>
                              <span className="text-xs text-text-secondary leading-snug">{d}</span>
                            </li>
                          ))}
                        </ol>
                        <p className="text-[11px] text-text-tertiary bg-gray-50 rounded-lg px-3 py-2">
                          {os === 'ios'
                            ? "iPhone doesn't allow an install button, so use Safari's menu (not Private mode). If you don't see the option, scroll to the bottom of the share sheet."
                            : (installApp.canPrompt ? 'Tap the button above, or use the menu steps if nothing happens.' : 'If you don\'t see “Install app”, make sure you opened this page in Chrome, not inside another app.')}
                        </p>
                      </>
                    );
                  })()}
                </div>
              )}
            </div>

            {/* 2. Notifications */}
            <div className="bg-white rounded-2xl border border-gray-200 shadow-sm overflow-hidden text-left">
              <div className="flex items-center gap-3 p-4">
                <span className={`w-11 h-11 rounded-xl flex items-center justify-center shrink-0 ${push.subscribed ? 'bg-success/10 text-success' : 'bg-gradient-to-br from-primary to-[#0a4d63] text-white'}`}>
                  <Icon name={push.subscribed ? 'BellRing' : 'Bell'} size={22} />
                </span>
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium text-text-primary">Notifications</p>
                  <p className="text-xs text-text-tertiary">Get alerted when a consultation starts</p>
                </div>
                {push.subscribed && <span className="px-2 py-0.5 rounded-full bg-success/10 text-success text-[11px] font-medium flex items-center gap-1"><Icon name="Check" size={11} /> On</span>}
              </div>
              <div className="px-4 pb-4 pt-3 border-t border-gray-100 space-y-3">
                {push.status === 'needs-install' && (
                  <p className="text-xs text-text-secondary bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
                    On iPhone, notifications only work from the Home Screen icon. Add it above, open it from the icon, then turn notifications on.
                  </p>
                )}
                {push.status === 'unsupported' && <p className="text-xs text-text-secondary">This browser can't show notifications.</p>}
                {push.status === 'denied' && <p className="text-xs text-text-secondary">Notifications are blocked. Allow them for this site in your browser settings.</p>}
                {(push.status === 'default' || push.status === 'granted') && (
                  push.subscribed ? (
                    <div className="flex items-center justify-between gap-3">
                      <p className="text-xs text-text-secondary">You'll get a notification when a consultation starts. Tap it to open and record.</p>
                      <button type="button" onClick={push.disable} disabled={push.busy} className="text-xs text-primary font-medium shrink-0 px-3 py-1.5 rounded-lg border border-primary/30">Turn off</button>
                    </div>
                  ) : (
                    <button type="button" onClick={push.enable} disabled={push.busy || !push.configured}
                            className="w-full h-11 rounded-xl bg-primary text-white text-sm font-medium shadow-sm shadow-primary/30 active:scale-[0.98] transition disabled:opacity-60">
                      {push.busy ? 'Turning on…' : 'Turn on notifications'}
                    </button>
                  )
                )}
                {push.error && <p className="text-xs text-error">{push.error}</p>}
              </div>
            </div>
          </div>
        </details>

        <div className="text-left rounded-2xl bg-primary/5 border border-primary/15 p-4">
          <p className="text-sm font-medium text-text-primary flex items-center gap-2"><Icon name="Lightbulb" size={16} className="text-primary" /> How it works</p>
          <ul className="mt-2 space-y-1.5 text-xs text-text-secondary">
            <li className="flex gap-2"><Icon name="Mic" size={13} className="text-primary mt-0.5 shrink-0" /> Tap the Doctor icon any time to join the patient in progress.</li>
            <li className="flex gap-2"><Icon name="Monitor" size={13} className="text-primary mt-0.5 shrink-0" /> Start a consultation on the computer and it opens here by itself.</li>
            <li className="flex gap-2"><Icon name="ShieldCheck" size={13} className="text-primary mt-0.5 shrink-0" /> Your phone may ask once to allow the microphone.</li>
          </ul>
        </div>
        </>
        )}
      </div>

      {/* Always visible while on the Doctor home (not while reading a past consultation, which has its own Close). */}
      {!(tab === 'history' && detail) && (
        <div className="fixed bottom-0 inset-x-0 z-10 px-5 pt-6 pb-[max(1rem,env(safe-area-inset-bottom))] bg-gradient-to-t from-background via-background/95 to-transparent pointer-events-none">
          <div className="max-w-sm mx-auto pointer-events-auto">
            <button type="button" onClick={closeApp}
                    className="w-full h-12 rounded-2xl bg-white border border-gray-200 shadow-md text-sm font-medium text-text-primary flex items-center justify-center gap-2.5 active:scale-[0.98] transition">
              <span className="w-7 h-7 rounded-full bg-error/10 text-error flex items-center justify-center"><Icon name="Power" size={15} /></span>
              Close app
            </button>
          </div>
        </div>
      )}
    </div>
  );
};

export default DoctorPhone;
