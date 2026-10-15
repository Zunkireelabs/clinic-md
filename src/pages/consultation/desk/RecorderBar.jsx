import React, { useState } from 'react';
import Icon from '../../../components/AppIcon';
import LevelMeter from './LevelMeter';
import { getConsultationFileUrl } from '../../../services/api';

const mmss = (s) => `${String(Math.floor((s || 0) / 60)).padStart(2, '0')}:${String(s % 60 || 0).padStart(2, '0')}`;

const Recording = ({ path, index }) => {
  const [url, setUrl] = useState(null);
  React.useEffect(() => {
    let off = false;
    getConsultationFileUrl('audio', path).then(({ url: u }) => { if (!off) setUrl(u); });
    return () => { off = true; };
  }, [path]);
  return (
    <div className="flex items-center gap-3 text-[12.5px]">
      <span className="text-[#8A8A90] w-24 flex-shrink-0">Recording {index + 1}</span>
      {url ? <audio controls src={url} className="h-8 flex-1 min-w-0" /> : <span className="text-[#8A8A90]">Loading…</span>}
    </div>
  );
};

// The compact recorder: ready (consent first), recording, and the "recordings so far" summary. Phone recordings show their own state.
const RecorderBar = ({
  firstName, consent, onConsent, locked, recorder, remote, remotePhoneLabel, phones, processing,
  audioPaths, durationSeconds, onStart, onStop, onRecordOnPhone, onStopRemote, onContinueOnPhone, errorText,
}) => {
  const [listen, setListen] = useState(false);
  const recording = recorder.isRecording;
  const remoteLive = remote && remote.state !== 'idle';
  const hasAudio = audioPaths.length > 0;
  const busy = processing !== null;

  if (recording) {
    return (
      <div className="sticky top-12 z-20 lg:static rounded-xl border border-[#F7C6C6] bg-[#FFF6F6] px-5 py-4 flex items-center gap-4 flex-wrap">
        <button type="button" onClick={onStop} aria-label="Stop recording" className="w-14 h-14 rounded-full bg-[#0E0D0C] grid place-items-center flex-shrink-0 hover:opacity-90">
          <span className="w-4 h-4 rounded-[3px] bg-white" />
        </button>
        <div className="min-w-0">
          <p className="text-[15px] font-medium flex items-center gap-2"><span className={`w-2.5 h-2.5 rounded-full bg-[#EF4444] shadow-[0_0_0_4px_rgba(239,68,68,.2)] ${recorder.isPaused ? '' : 'motion-safe:animate-pulse'}`} />{recorder.isPaused ? 'Paused' : 'Recording'} <span className="tabular-nums">{mmss(recorder.recordingTime)}</span></p>
          <p className="text-[12.5px] text-[#8A8A90] truncate">{recorder.deviceLabel || 'Computer microphone'} · stop when you’re done</p>
        </div>
        <div className="flex-1 min-w-[140px]"><LevelMeter stream={recorder.stream} paused={recorder.isPaused} /></div>
        <button type="button" onClick={recorder.isPaused ? recorder.resume : recorder.pause} className="h-8 px-3 rounded-md border border-border bg-white text-[13px] font-medium">{recorder.isPaused ? 'Resume' : 'Pause'}</button>
      </div>
    );
  }

  if (remoteLive) {
    return (
      <div className="sticky top-12 z-20 lg:static rounded-xl border border-[#F7C6C6] bg-[#FFF6F6] px-5 py-4 flex items-center gap-4 flex-wrap">
        <span className="w-14 h-14 rounded-full bg-white border border-border grid place-items-center flex-shrink-0"><Icon name="Smartphone" size={22} /></span>
        <div className="min-w-0 flex-1">
          <p className="text-[15px] font-medium">{remote.state === 'processing' ? `${remotePhoneLabel || 'Phone'} is transcribing…` : `Recording on ${remotePhoneLabel || 'the phone'}${remote.state === 'paused' ? ' (paused)' : '…'}`}{remote.state !== 'processing' && <span className="tabular-nums"> {mmss(remote.seconds || 0)}</span>}</p>
          <p className="text-[12.5px] text-[#8A8A90]">Keep this page open. The note drafts when the recording stops.</p>
        </div>
        {remote.state !== 'processing' && <button type="button" onClick={onStopRemote} className="h-8 px-3 rounded-md bg-[#0E0D0C] text-white text-[13px] font-medium">Stop</button>}
      </div>
    );
  }

  if (hasAudio || busy) {
    return (
      <div className="rounded-xl border border-border bg-white px-5 py-4">
        <div className="flex items-center gap-4 flex-wrap">
          <button type="button" onClick={onStart} disabled={busy || !consent || locked} aria-label="Record more" title={consent ? 'Record more' : `Confirm ${firstName} has agreed to be recorded`}
            className="w-14 h-14 rounded-full bg-primary text-white grid place-items-center flex-shrink-0 disabled:opacity-40 hover:opacity-95"><Icon name="Mic" size={22} /></button>
          <div className="min-w-0">
            <p className="text-[15px] font-medium">{audioPaths.length} recording{audioPaths.length === 1 ? '' : 's'}{durationSeconds ? ` · ${mmss(durationSeconds)}` : ''}</p>
            <p className="text-[12.5px] text-[#8A8A90]">{locked ? 'Press Edit note to add more' : consent ? 'Tap to record more' : `Tick that ${firstName} has agreed to record more`}</p>
          </div>
          <div className="flex-1 min-w-[120px] hidden sm:block opacity-60"><LevelMeter stream={null} color="#8A8A90" /></div>
          <button type="button" onClick={() => setListen((l) => !l)} aria-expanded={listen} className="h-8 px-3 rounded-md border border-border bg-white text-[13px] font-medium inline-flex items-center gap-1.5"><Icon name="Play" size={13} />{listen ? 'Hide' : 'Play'}</button>
        </div>
        {!busy && !locked && (
          <label className="mt-3 flex items-center gap-2 text-[13px] text-[#515152] cursor-pointer"><input type="checkbox" className="w-4 h-4 rounded-[4px] border-[#C9C9CF] text-[#0E0D0C] accent-[#0E0D0C] focus:ring-1 focus:ring-[#0E0D0C] focus:ring-offset-0" checked={consent} onChange={(e) => onConsent(e.target.checked)} />{firstName} has agreed to this visit being recorded</label>
        )}
        {listen && <div className="mt-3 space-y-2">{audioPaths.map((p, i) => <Recording key={p} path={p} index={i} />)}</div>}
        {errorText && <p role="alert" className="mt-3 text-[13px] text-[#B42318]">{errorText}</p>}
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-border bg-white px-5 py-4">
      <div className="flex items-start gap-4">
        <button type="button" onClick={onStart} disabled={!consent} aria-label="Start recording" title={consent ? 'Start recording' : `Confirm ${firstName} has agreed to be recorded`}
          className="w-14 h-14 rounded-full bg-primary text-white grid place-items-center flex-shrink-0 disabled:opacity-40 hover:opacity-95"><Icon name="Mic" size={22} /></button>
        <div className="min-w-0">
          <p className="text-[15px] font-semibold">Record the consultation</p>
          <p className="text-[12.5px] text-[#8A8A90]">Uses this computer’s mic · or <button type="button" onClick={onContinueOnPhone} className="text-text-primary font-medium underline">continue on phone</button></p>
          <label className="mt-2.5 flex items-center gap-2 text-[13px] text-[#515152] cursor-pointer"><input type="checkbox" className="w-4 h-4 rounded-[4px] border-[#C9C9CF] text-[#0E0D0C] accent-[#0E0D0C] focus:ring-1 focus:ring-[#0E0D0C] focus:ring-offset-0" checked={consent} onChange={(e) => onConsent(e.target.checked)} />{firstName} has agreed to this visit being recorded</label>
          {phones.length > 0 && (
            <button type="button" onClick={onRecordOnPhone} disabled={!consent} className="mt-2.5 h-8 px-3 rounded-md border border-border bg-white text-[13px] font-medium inline-flex items-center gap-1.5 disabled:opacity-50"><Icon name="Smartphone" size={14} />Record on {phones[0].label || 'phone'}</button>
          )}
        </div>
      </div>
      {errorText && <p role="alert" className="mt-3 text-[13px] text-[#B42318]">{errorText}</p>}
    </div>
  );
};

export default RecorderBar;
