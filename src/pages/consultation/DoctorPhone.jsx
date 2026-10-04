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
import LockedHome from './components/LockedHome';
import usePhoneLock from '../../hooks/usePhoneLock';
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
  const [pendingVerify, setPendingVerify] = useState(initialTarget?.verify ? initialTarget : null);
  const [active, setActive] = useState(() => (
    initialTarget && !initialTarget.verify
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
      if (data.verify) {
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
    // Work started on the computer: ask for the code it is showing before opening the patient.
    onOpen: (p) => { suppressAutoRef.current = true; setClosed(false); setActive(null); setPendingVerify({ bookingId: p.bookingId }); },
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
    <div className="min-h-screen bg-background p-6 pb-28">
      <div className="w-full max-w-sm mx-auto text-center space-y-5">
        {flash && (
          <div className="p-3 bg-success/10 border border-success/30 rounded-md text-sm text-text-primary flex items-center justify-between gap-2 text-left">
            <span className="flex items-center gap-2"><Icon name="CheckCircle" size={16} className="text-success shrink-0" /> {flash}</span>
            <button type="button" onClick={() => setFlash(null)} aria-label="Dismiss"><Icon name="X" size={14} className="text-text-tertiary" /></button>
          </div>
        )}
        <div className="grid grid-cols-2 gap-1 p-1 bg-gray-100 rounded-lg">
          {[['now', 'Record'], ['history', 'History']].map(([id, label]) => (
            <button key={id} type="button" onClick={() => { setTab(id); setDetail(null); }}
                    className={`py-2 rounded-md text-sm font-medium ${tab === id ? 'bg-white text-text-primary shadow-sm' : 'text-text-secondary'}`}>
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
        <div className="mx-auto w-16 h-16 rounded-full bg-primary/10 flex items-center justify-center">
          <Icon name="Smartphone" size={28} className="text-primary" />
        </div>
        <div>
          <h1 className="font-heading font-heading-semibold text-xl text-text-primary">Doctor phone</h1>
          <p className="text-sm text-text-secondary mt-1">
            Signed in as {profile?.full_name || 'staff'}{orgSlug ? ` · ${orgSlug}` : ''}
          </p>
        </div>

        <div className="bg-white rounded-lg border border-gray-200 p-4 text-left space-y-3 text-sm">
          <p className="flex items-center gap-2 text-text-primary">
            <span className="w-2 h-2 rounded-full bg-success animate-pulse" /> Ready — waiting for a consultation
          </p>
          <p className="flex items-center gap-2 text-text-secondary">
            <Icon name={computers.length ? 'Monitor' : 'MonitorOff'} size={14} />
            {computers.length ? 'Computer connected' : 'Computer not connected yet'}
          </p>
          <p className="flex items-center gap-2 text-text-secondary">
            <Icon name={wake.active ? 'Sun' : 'Moon'} size={14} />
            {wake.active ? 'Screen will stay on' : (wake.supported ? 'Screen may lock — keep it awake' : 'Keep the screen on and this page open')}
          </p>
        </div>

        {!installApp.standalone && (
          <div className="bg-white rounded-lg border border-gray-200 p-4 text-left space-y-3">
            <p className="text-sm font-medium text-text-primary flex items-center gap-2">
              <Icon name="SquarePlus" size={16} className="text-primary" /> Add to Home Screen
            </p>
            {installApp.canPrompt ? (
              <>
                <p className="text-xs text-text-secondary">Put the Doctor app on your Home Screen so one tap starts recording.</p>
                <button type="button" onClick={installApp.install}
                        className="w-full py-2 rounded-md bg-primary text-white text-sm font-medium">
                  Install Doctor app
                </button>
              </>
            ) : installApp.isIos ? (
              <>
                <p className="text-xs text-text-secondary">iPhone doesn't allow a button for this, so do it from Safari's menu:</p>
                <ol className="text-xs text-text-secondary space-y-2">
                  <li className="flex items-start gap-2"><span className="w-5 h-5 rounded-full bg-primary/10 text-primary text-[11px] font-medium flex items-center justify-center shrink-0">1</span><span>Tap the <strong>Share</strong> icon <Icon name="Share" size={13} className="inline -mt-0.5" /> at the bottom of Safari (or the <strong>···</strong> menu, then Share).</span></li>
                  <li className="flex items-start gap-2"><span className="w-5 h-5 rounded-full bg-primary/10 text-primary text-[11px] font-medium flex items-center justify-center shrink-0">2</span><span>Scroll down and tap <strong>Add to Home Screen</strong> <Icon name="SquarePlus" size={13} className="inline -mt-0.5" />.</span></li>
                  <li className="flex items-start gap-2"><span className="w-5 h-5 rounded-full bg-primary/10 text-primary text-[11px] font-medium flex items-center justify-center shrink-0">3</span><span>Tap <strong>Add</strong>. The Doctor icon appears on your Home Screen.</span></li>
                </ol>
                <p className="text-[11px] text-text-tertiary">Must be Safari, not a different browser or Private mode. If you don't see the option, scroll the share sheet to the bottom.</p>
              </>
            ) : (
              <p className="text-xs text-text-secondary">Open your browser's menu and choose <strong>Add to Home screen</strong> (or <strong>Install app</strong>).</p>
            )}
          </div>
        )}

        <div className="bg-white rounded-lg border border-gray-200 p-4 text-left space-y-2">
          <p className="text-sm font-medium text-text-primary flex items-center gap-2">
            <Icon name="Bell" size={16} className="text-primary" /> Notifications
          </p>
          {push.status === 'needs-install' && (
            <p className="text-xs text-text-secondary">
              On iPhone, notifications only work from the Home Screen icon. Add it using the card above, open it from the icon, then turn notifications on.
            </p>
          )}
          {push.status === 'unsupported' && <p className="text-xs text-text-secondary">This browser can't show notifications.</p>}
          {push.status === 'denied' && <p className="text-xs text-text-secondary">Notifications are blocked. Allow them for this site in your browser settings.</p>}
          {(push.status === 'default' || push.status === 'granted') && (
            push.subscribed ? (
              <div className="flex items-center justify-between gap-3">
                <p className="text-xs text-text-secondary flex items-center gap-1"><Icon name="Check" size={12} className="text-success" /> On — you'll get a notification when a consultation starts.</p>
                <button type="button" onClick={push.disable} disabled={push.busy} className="text-xs text-primary font-medium shrink-0">Turn off</button>
              </div>
            ) : (
              <>
                <p className="text-xs text-text-secondary">Get a notification on this phone when you start a consultation on the computer. Tap it to open and record.</p>
                <button type="button" onClick={push.enable} disabled={push.busy || !push.configured}
                        className="w-full py-2 rounded-md bg-primary text-white text-sm font-medium disabled:opacity-60">
                  {push.busy ? 'Turning on…' : 'Turn on notifications'}
                </button>
              </>
            )
          )}
          {push.error && <p className="text-xs text-error">{push.error}</p>}
        </div>

        <div className="text-left">
          <p className="text-xs uppercase tracking-wider text-text-tertiary mb-2">In progress now</p>
          {listLoading ? (
            <p className="text-sm text-text-tertiary">Looking for patients…</p>
          ) : inProgress.length === 0 ? (
            <p className="text-sm text-text-tertiary">No patient is in progress. Start a booking on the computer and it will appear here.</p>
          ) : (
            <div className="space-y-2">
              {inProgress.map((b) => (
                <button
                  key={b.id}
                  type="button"
                  onClick={() => { suppressAutoRef.current = true; setActive({ bookingId: b.id, nonce: Date.now() }); }}
                  className="w-full text-left bg-white rounded-lg border border-gray-200 hover:border-primary p-3 flex items-center gap-3"
                >
                  <Icon name="Mic" size={18} className="text-primary shrink-0" />
                  <span className="min-w-0">
                    <span className="block text-sm font-medium text-text-primary truncate">{b.customer_name}</span>
                    <span className="block text-xs text-text-tertiary truncate">{b.treatment_name_snapshot || 'Treatment'} · tap to record</span>
                  </span>
                </button>
              ))}
            </div>
          )}
        </div>

        <p className="text-xs text-text-tertiary px-2">
          You don't have to keep this page open: tap the ClinicMD Doctor icon any time and it joins the patient in progress and starts recording. If this page is already open, a consultation started on the computer opens here by itself. Your phone may ask once to allow the microphone.
        </p>
        </>
        )}
      </div>

      {/* Always visible while on the Doctor home (not while reading a past consultation, which has its own Close). */}
      {!(tab === 'history' && detail) && (
        <div className="fixed bottom-0 inset-x-0 z-10 p-4 pb-[max(1rem,env(safe-area-inset-bottom))] bg-background/95 backdrop-blur border-t border-gray-200">
          <div className="max-w-sm mx-auto">
            <button type="button" onClick={closeApp}
                    className="w-full py-3 rounded-lg border border-gray-300 bg-white text-text-primary text-sm font-medium flex items-center justify-center gap-2">
              <Icon name="Power" size={16} /> Close app
            </button>
          </div>
        </div>
      )}
    </div>
  );
};

export default DoctorPhone;
