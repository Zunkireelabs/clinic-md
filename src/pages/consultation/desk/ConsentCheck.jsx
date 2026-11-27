import React from 'react';
import { CONSENT_SCRIPTS, CURRENT_CONSENT_SCRIPT, consentTime } from '../../../utils/consentScripts';

// The recording-consent checkbox, shared by the computer (RecorderBar) and the phone view: same markup, same words.
// Migration 020: ticking it records consent on the server, once per consultation. Once stored it stays ticked, can't be unticked, and shows the time.
const ConsentCheck = ({ firstName, consent, consentAt, onConsent, busy = false, className = 'mt-2.5' }) => (
  <label className={`${className} flex items-center gap-2 text-[13px] text-[#515152] ${consent ? '' : 'cursor-pointer'}`}>
    <input
      type="checkbox"
      className="w-4 h-4 rounded-[4px] border-[#C9C9CF] text-[#0E0D0C] accent-[#0E0D0C] focus:ring-1 focus:ring-[#0E0D0C] focus:ring-offset-0"
      checked={consent}
      disabled={consent || busy}
      onChange={(e) => { if (e.target.checked) onConsent(true); }}
    />
    {CONSENT_SCRIPTS[CURRENT_CONSENT_SCRIPT].checkbox(firstName)}
    {consent && consentAt && <span className="text-[#8A8A90]">· Agreed {consentTime(consentAt)}</span>}
  </label>
);

export default ConsentCheck;
