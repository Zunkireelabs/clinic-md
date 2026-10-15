import React, { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import NoteText from '../../../components/ui/NoteText';
import Icon from '../../../components/AppIcon';
import { NOTE_SECTIONS } from '../../../utils/consultationNote';

// Grows with its content. Re-measured on first layout, whenever the value is set (typing or a draft arriving) and whenever the
// available width changes (responsive wrap, rail moving under the note), so text is never clipped.
const AutoTextarea = ({ value, onChange, placeholder, readOnly, label, onBlur, autoFocus }) => {
  const ref = useRef(null);
  const fit = useCallback(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${el.scrollHeight}px`;
  }, []);
  useLayoutEffect(() => { fit(); }, [value, fit]);
  useEffect(() => {
    const el = ref.current;
    if (!el) return undefined;
    let width = el.clientWidth;
    const ro = new ResizeObserver(() => { if (el.clientWidth !== width) { width = el.clientWidth; fit(); } });
    ro.observe(el);
    document.fonts?.ready?.then(fit);
    return () => ro.disconnect();
  }, [fit]);
  useEffect(() => { if (autoFocus) { ref.current?.focus(); const l = ref.current?.value.length || 0; ref.current?.setSelectionRange?.(l, l); } }, [autoFocus]);
  return (
    <textarea
      ref={ref} rows={1} value={value} readOnly={readOnly} placeholder={placeholder} aria-label={label} onBlur={onBlur}
      onChange={(e) => onChange(e.target.value)}
      className={`w-full resize-none overflow-hidden bg-transparent text-[13.5px] leading-[1.6] rounded-md px-2 py-1 -mx-2 -my-1 placeholder:text-[#B4B4BA] border border-transparent ${readOnly ? 'cursor-default focus:outline-none' : 'hover:bg-[#FAFAFB] focus:outline-none focus:border-primary focus:bg-white focus:shadow-[0_0_0_3px_rgba(123,47,247,.10)]'}`}
    />
  );
};

// One section: rendered as text (bullets as a real list) until it is focused for editing; empty sections stay a textarea so the
// placeholder is visible and clickable. Read-only (saved) never shows a textarea.
const SectionBody = ({ label, value, onChange, placeholder, readOnly }) => {
  const [editing, setEditing] = useState(false);
  if (value.trim() && (readOnly || !editing)) {
    return (
      <div
        role={readOnly ? undefined : 'button'} tabIndex={readOnly ? undefined : 0} aria-label={readOnly ? undefined : `Edit ${label}`}
        onClick={readOnly ? undefined : () => setEditing(true)} onFocus={readOnly ? undefined : () => setEditing(true)}
        className={`text-[13.5px] leading-[1.6] rounded-md px-2 py-1 -mx-2 -my-1 border border-transparent ${readOnly ? '' : 'cursor-text hover:bg-[#FAFAFB]'}`}
      >
        <NoteText text={value} />
      </div>
    );
  }
  return <AutoTextarea value={value} onChange={onChange} placeholder={placeholder} readOnly={readOnly} label={label} autoFocus={editing} onBlur={() => setEditing(false)} />;
};

const Chip = ({ children }) => <span className="h-5 px-2 rounded-full border border-border bg-[#FAFAFB] text-[11.5px] text-[#515152] inline-flex items-center">{children}</span>;

const Skeleton = () => (
  <div className="space-y-2 py-1" aria-hidden="true">
    <div className="h-2.5 rounded bg-[#F1F1F3] animate-pulse w-[88%]" />
    <div className="h-2.5 rounded bg-[#F1F1F3] animate-pulse w-[52%]" />
  </div>
);

// The clinical note: six editable sections (or skeletons while drafting, or read-only once saved), plus the Transcript view.
const NoteCard = ({
  stage, note, onNoteChange, view, onView, transcript, onTranscript, badge, drafting,
  noAiBanner, noAiKind, onTryAgain, tryAgainBusy, readOnly, findingsTags, footer, onRedraft,
  updateDraftOffer, onUpdateDraft, onWriteMyself, hasTranscript, earlierDoctorNotes, onDraftNow,
}) => {
  const noteEmpty = NOTE_SECTIONS.every((x) => !String(note[x.key] || '').trim());
  const showEmptyHero = stage === 'ready' || (stage === 'recording' && noteEmpty);
  return (
    <section aria-label="Clinical note" className="rounded-xl border border-border bg-white overflow-hidden">
      <div className="flex items-center justify-between gap-x-3 gap-y-2 px-5 py-3 min-h-14 border-b border-[#F1F1F3] flex-wrap">
        <div className="flex items-center gap-3 min-w-0 flex-wrap">
          <h2 className="text-[14px] font-semibold whitespace-nowrap">Clinical note</h2>
          {drafting && <span className="h-6 px-2.5 rounded-full bg-[#F3EEFF] text-[#5B21B6] text-[12px] font-medium inline-flex items-center gap-1.5"><Icon name="Sparkles" size={12} />Drafting…</span>}
          {!drafting && badge && <span className="h-6 px-2.5 rounded-full bg-[#F3EEFF] text-[#5B21B6] text-[12px] font-medium inline-flex items-center gap-1.5"><Icon name="Sparkles" size={12} />{badge}</span>}
        </div>
        <div className="inline-flex rounded-md border border-border p-0.5 text-[12.5px] flex-shrink-0" role="tablist" aria-label="Note or transcript">
          {[['note', 'Note'], ['transcript', 'Transcript']].map(([k, l]) => (
            <button key={k} type="button" role="tab" aria-selected={view === k} onClick={() => onView(k)} className={`px-2.5 h-6 rounded ${view === k ? 'bg-white shadow-[0_0_0_1px_#E9E9EC] text-text-primary font-medium' : 'text-[#8A8A90]'}`}>{l}</button>
          ))}
        </div>
      </div>

      {view === 'transcript' ? (
        <div className="p-5">
          {hasTranscript || stage !== 'ready' ? (
            <textarea aria-label="Transcript" value={transcript} onChange={(e) => onTranscript(e.target.value)} rows={12} readOnly={readOnly}
              placeholder="The transcript appears here after a recording is transcribed. You can also type it."
              className="w-full text-[13.5px] leading-[1.6] rounded-lg border border-border px-3 py-2 placeholder:text-[#B4B4BA] focus:outline-none focus:border-primary focus:shadow-[0_0_0_3px_rgba(123,47,247,.10)]" />
          ) : <p className="text-[13px] text-[#8A8A90] py-8 text-center">No transcript yet. Record the consultation and it appears here.</p>}
        </div>
      ) : (
        <>
          {noAiBanner && (
            <div role="alert" className="px-5 py-3 bg-[#FAFAFB] border-b border-[#F1F1F3] text-[13px] flex items-center gap-2 flex-wrap">
              <Icon name="Info" size={15} className="text-[#515152]" />
              {noAiKind === 'upload' ? (
                <span><b className="font-medium">Recording not uploaded yet.</b> <span className="text-[#515152]">It is still on this computer — keep this page open.{' '}
                  <button type="button" onClick={onTryAgain} disabled={tryAgainBusy} className="underline text-text-primary disabled:opacity-60">Retry</button>.</span></span>
              ) : (
                <span><b className="font-medium">AI drafting isn’t available right now.</b> <span className="text-[#515152]">Your recording is saved. Write the note below, or{' '}
                  <button type="button" onClick={onTryAgain} disabled={tryAgainBusy} className="underline text-text-primary disabled:opacity-60">try drafting again</button>.</span></span>
              )}
            </div>
          )}
          {updateDraftOffer && (
            <div className="px-5 py-3 bg-[#F6F2FF] border-b border-[#EDE4FF] text-[13px] flex items-center gap-2 flex-wrap">
              <Icon name="Sparkles" size={14} className="text-primary" />
              <span>The transcript has new material.</span>
              <button type="button" onClick={onUpdateDraft} className="underline text-text-primary font-medium">Update the draft</button>
            </div>
          )}
          {showEmptyHero ? (
            <div className="py-14 px-6 text-center">
              <span className="w-12 h-12 rounded-xl bg-[#F3EEFF] text-primary grid place-items-center mx-auto mb-4"><Icon name="Sparkles" size={20} /></span>
              <p className="text-[15px] font-semibold">Your note drafts itself after the recording</p>
              <p className="text-[13px] text-[#8A8A90] max-w-[420px] mx-auto mt-1.5">Talk with your patient as usual. When you stop, the conversation, X-rays and photos become a structured note for you to review. Prefer to type?{' '}
                <button type="button" onClick={onWriteMyself} className="text-text-primary underline font-medium">Write the note yourself</button></p>
              {onDraftNow && <button type="button" onClick={onDraftNow} className="mt-4 h-8 px-3 rounded-md bg-primary text-white text-[13px] font-medium inline-flex items-center gap-1.5"><Icon name="Sparkles" size={14} />Draft the note now</button>}
            </div>
          ) : (
            <div>
              {NOTE_SECTIONS.map((s, i) => (
                <div key={s.key} className={`grid grid-cols-1 sm:grid-cols-[150px_1fr] gap-x-4 gap-y-1 px-5 py-3.5 ${i ? 'border-t border-[#F1F1F3]' : ''}`}>
                  <label className="text-[13px] text-[#8A8A90] pt-0.5">{s.heading}</label>
                  <div className="min-w-0">
                    {drafting ? <Skeleton /> : (
                      <>
                        <SectionBody value={note[s.key]} onChange={(v) => onNoteChange(s.key, v)} placeholder={s.placeholder} readOnly={readOnly} label={s.heading} />
                        {s.key === 'findings' && findingsTags.length > 0 && <div className="flex gap-1.5 mt-1.5">{findingsTags.map((t) => <Chip key={t}>{t}</Chip>)}</div>}
                      </>
                    )}
                  </div>
                </div>
              ))}
              {earlierDoctorNotes && (
                <div className="px-5 py-3.5 border-t border-[#F1F1F3] bg-[#FAFAFB] text-[13px]">
                  <p className="text-[12px] text-[#8A8A90] mb-1">Earlier doctor’s notes (from before this page changed)</p>
                  <p className="whitespace-pre-wrap">{earlierDoctorNotes}</p>
                </div>
              )}
            </div>
          )}
          {footer && (
            <div className="px-5 py-3 bg-[#FAFAFB] border-t border-[#F1F1F3] flex items-center justify-between gap-3 text-[12.5px] text-[#8A8A90]">
              <span>{footer}</span>
              {onRedraft && <button type="button" onClick={onRedraft} className="text-text-primary font-medium hover:underline">Redraft</button>}
            </div>
          )}
        </>
      )}
    </section>
  );
};

export default NoteCard;
