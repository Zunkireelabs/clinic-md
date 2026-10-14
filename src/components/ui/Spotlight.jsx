import React, { useCallback, useEffect, useRef, useState } from 'react';
import Icon from '../AppIcon';
import { useAuth } from '../../contexts/AuthContext';
import { capture } from '../../lib/analytics';
import { isSpotlightDismissed, dismissSpotlight } from '../../utils/spotlightStorage';

/** `{ visible, dismiss }` for a banner id; dismissal is remembered per user in localStorage. */
export function useSpotlight(id) {
  const { user } = useAuth();
  const userId = user?.id;
  const [dismissed, setDismissed] = useState(() => isSpotlightDismissed(id, userId));
  useEffect(() => { setDismissed(isSpotlightDismissed(id, userId)); }, [id, userId]);
  const dismiss = useCallback(() => {
    dismissSpotlight(id, userId);
    setDismissed(true);
    capture('spotlight_dismissed', { id });
  }, [id, userId]);
  return { visible: !dismissed, dismiss };
}

// A single announcement banner. Callers decide *whether* it is relevant; this only renders it (and tracks shown/clicked/dismissed).
// 124px tall at lg+; below lg the art is hidden and the height follows the content.
const Spotlight = ({ id, eyebrow, title, body, primary, secondary, art, onDismiss }) => {
  const shown = useRef(false);
  useEffect(() => {
    if (shown.current) return;
    shown.current = true;
    capture('spotlight_shown', { id });
  }, [id]);

  const click = (action) => () => { capture('spotlight_clicked', { id }); action?.onClick?.(); };

  return (
    <section
      role="region"
      aria-label={title}
      className="relative overflow-hidden rounded-xl text-white flex items-center px-5 py-4 lg:px-7 lg:py-0 lg:h-[124px]"
      style={{
        background: 'radial-gradient(120% 160% at 100% 0%,#7B2FF7 0%,rgba(123,47,247,.55) 28%,rgba(14,13,12,0) 60%),linear-gradient(90deg,#0E0D0C 0%,#151320 55%,#2A1650 100%)',
      }}
    >
      <div className="min-w-0 pr-8 lg:pr-0">
        <span className="inline-flex items-center gap-1.5 text-[11px] font-semibold tracking-[.06em] uppercase text-[#C9B2FF]">
          <Icon name="Sparkles" size={13} />{eyebrow}
        </span>
        <h3 className="text-[17px] font-semibold tracking-[-0.3px] mt-1.5 leading-snug">{title}</h3>
        <p className="text-[13px] text-white/[.72] mt-1">{body}</p>
        <div className="flex gap-3.5 items-center mt-3 flex-wrap">
          <button type="button" onClick={click(primary)} className="h-7 px-3 rounded-full bg-white text-[#0E0D0C] text-[12.5px] font-medium hover:bg-white/90">{primary.label}</button>
          {secondary && <button type="button" onClick={click(secondary)} className="text-[12.5px] font-medium text-white/80 hover:text-white">{secondary.label}</button>}
        </div>
      </div>
      <div className="hidden lg:block">{art}</div>
      <button type="button" onClick={onDismiss} aria-label="Dismiss" className="absolute top-3 right-3 w-6 h-6 grid place-items-center rounded-md text-white/60 hover:text-white hover:bg-white/10">
        <Icon name="X" size={16} />
      </button>
    </section>
  );
};

export default Spotlight;
