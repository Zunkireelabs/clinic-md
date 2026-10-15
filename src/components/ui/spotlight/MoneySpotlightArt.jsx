import React from 'react';

// Static preview (no faces): an "Owed" card overlapping an "Upcoming" card, in the same translucent style as ConsultationSpotlightArt.
const MoneySpotlightArt = () => (
  <div aria-hidden="true" className="absolute right-14 top-4 bottom-4 w-[300px]">
    <div className="absolute left-0 top-2 w-[160px] px-3 py-2.5 rounded-[10px] bg-white/95 text-[#0E0D0C] shadow-[0_12px_30px_rgba(0,0,0,.35)]">
      <div className="flex items-center gap-2 text-[11px] font-semibold text-[#515152]"><span className="w-2 h-2 rounded-full bg-[#F59E0B]" />Owed</div>
      <div className="text-[18px] font-semibold tracking-tight mt-1 tabular-nums">NPR 8,000</div>
      <div className="text-[11px] text-[#8A8A90]">1 unpaid visit</div>
    </div>
    <div className="absolute left-[130px] top-[66px] w-[170px] px-3 py-2.5 rounded-[10px] bg-white/[.08] border border-white/[.14] backdrop-blur-[6px] text-white">
      <div className="flex items-center gap-2 text-[11px] font-semibold text-white/80"><span className="w-2 h-2 rounded-full bg-white/50" />Upcoming</div>
      <div className="text-[18px] font-semibold tracking-tight mt-1 tabular-nums text-white/90">NPR 3,000</div>
      <div className="text-[11px] text-white/60">Not owed yet</div>
    </div>
  </div>
);

export default MoneySpotlightArt;
