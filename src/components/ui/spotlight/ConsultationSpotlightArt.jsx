import React from 'react';

const BARS = [6, 12, 20, 9, 16, 24, 13, 7, 18, 22, 10, 15, 26, 12, 8, 19, 14, 6, 11, 21, 9, 16];

// Stylised product preview (no photos, no faces): a recording card over a clinical-summary card that bleeds off the bottom edge.
const ConsultationSpotlightArt = () => (
  <div aria-hidden="true" className="absolute right-14 top-4 bottom-4 w-[330px]">
    <div className="absolute left-0 top-1.5 w-[170px] px-3 py-2.5 rounded-[10px] bg-white/[.08] border border-white/[.14] backdrop-blur-[6px] text-white">
      <div className="flex items-center gap-2 text-[11px] font-semibold">
        <span className="w-2 h-2 rounded-full bg-[#FF4D4F] shadow-[0_0_0_4px_rgba(255,77,79,.25)]" />Recording · 02:14
      </div>
      <div className="flex items-center gap-[3px] h-[26px] mt-1.5">
        {BARS.map((h, i) => <i key={i} className="block w-[3px] rounded-sm bg-white opacity-[.85]" style={{ height: h }} />)}
      </div>
    </div>
    <div className="absolute left-[120px] top-[30px] w-[210px] px-3 py-2.5 rounded-[10px] bg-white/95 text-[#0E0D0C] border border-transparent shadow-[0_12px_30px_rgba(0,0,0,.35)]">
      <div className="text-[10.5px] font-semibold text-[#7B2FF7] tracking-[.04em] uppercase">Summary</div>
      <div className="text-[11.5px] font-semibold mt-1">Chief complaint</div>
      <div className="text-[11px] text-[#515152]">Sensitivity, lower-left molar, 2 weeks.</div>
      <div className="text-[11.5px] font-semibold mt-1">Plan</div>
      <div className="text-[11px] text-[#515152]">Filling #36 · review in 6 months</div>
    </div>
  </div>
);

export default ConsultationSpotlightArt;
