import React from 'react';
import Icon from '../../../components/AppIcon';

// A friendly line drawing of a tooth, used as the Doctor app's artwork.
export const ToothArt = ({ className = '' }) => (
  <svg viewBox="0 0 120 140" className={className} fill="none" aria-hidden="true">
    <path
      d="M60 12c-12-9-34-8-42 10-8 18 0 38 4 54 3 14 4 38 14 44 8 5 11-12 14-26 2-9 5-14 10-14s8 5 10 14c3 14 6 31 14 26 10-6 11-30 14-44 4-16 12-36 4-54-8-18-30-19-42-10z"
      fill="currentColor" fillOpacity=".16" stroke="currentColor" strokeOpacity=".55" strokeWidth="3" strokeLinejoin="round"
    />
    <path d="M38 34c4-8 12-10 18-6" stroke="currentColor" strokeOpacity=".7" strokeWidth="4" strokeLinecap="round" />
    <circle cx="96" cy="22" r="3" fill="currentColor" fillOpacity=".7" />
    <path d="M100 40v10M95 45h10" stroke="currentColor" strokeOpacity=".6" strokeWidth="3" strokeLinecap="round" />
  </svg>
);

const greeting = () => {
  const h = new Date().getHours();
  return h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening';
};

/** Top of the Doctor app: gradient banner with the doctor's name, today's date and live status. */
const DoctorHero = ({ name, clinic, computerConnected, screenOn, waiting = true }) => (
  <div className="relative overflow-hidden bg-gradient-to-br from-primary to-[#0a4d63] text-white px-5 pt-[max(1.5rem,env(safe-area-inset-top))] pb-14 rounded-b-[2rem]">
    <div className="absolute -right-10 -top-10 w-44 h-44 rounded-full bg-white/10" />
    <div className="absolute right-14 top-24 w-16 h-16 rounded-full bg-white/10" />
    <ToothArt className="absolute right-3 top-3 w-24 h-28 text-white" />
    <div className="relative max-w-sm mx-auto">
      <p className="text-sm text-white/80">{greeting()}</p>
      <h1 className="font-heading font-heading-semibold text-2xl leading-tight mt-0.5 pr-24 break-words">{name || 'Doctor'}</h1>
      <p className="text-xs text-white/70 mt-1">
        {clinic ? `${clinic} · ` : ''}{new Date().toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })}
      </p>
      <div className="flex flex-wrap gap-2 mt-4">
        <span className="inline-flex items-center gap-1.5 px-3 py-1 rounded-full bg-white/15 text-xs">
          <span className={`w-2 h-2 rounded-full ${waiting ? 'bg-emerald-300 animate-pulse' : 'bg-white/60'}`} /> Ready
        </span>
        <span className="inline-flex items-center gap-1.5 px-3 py-1 rounded-full bg-white/15 text-xs">
          <Icon name={computerConnected ? 'Monitor' : 'MonitorOff'} size={12} /> {computerConnected ? 'Computer linked' : 'Computer offline'}
        </span>
        <span className="inline-flex items-center gap-1.5 px-3 py-1 rounded-full bg-white/15 text-xs">
          <Icon name={screenOn ? 'Sun' : 'Moon'} size={12} /> {screenOn ? 'Screen on' : 'Screen may lock'}
        </span>
      </div>
    </div>
  </div>
);

export default DoctorHero;
