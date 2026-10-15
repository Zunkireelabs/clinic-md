import React, { useEffect, useRef } from 'react';

const BARS = 56;

// Live microphone level as a bar waveform (AnalyserNode). With reduced motion, or no stream (phone recording), it draws a calm static
// shape instead. `color` is any CSS colour.
const LevelMeter = ({ stream, paused = false, color = '#EF4444' }) => {
  const ref = useRef(null);
  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return undefined;
    const ctx2d = canvas.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth; const h = canvas.clientHeight;
    canvas.width = w * dpr; canvas.height = h * dpr; ctx2d.scale(dpr, dpr);
    const reduce = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    const levels = new Array(BARS).fill(0.08);
    const draw = () => {
      ctx2d.clearRect(0, 0, w, h);
      const gap = 3; const bw = Math.max(2, (w - gap * (BARS - 1)) / BARS);
      ctx2d.fillStyle = color;
      levels.forEach((l, i) => {
        const bh = Math.max(3, l * h);
        ctx2d.globalAlpha = paused ? 0.35 : 0.85;
        ctx2d.beginPath();
        ctx2d.roundRect?.(i * (bw + gap), (h - bh) / 2, bw, bh, 1.5);
        if (!ctx2d.roundRect) ctx2d.rect(i * (bw + gap), (h - bh) / 2, bw, bh);
        ctx2d.fill();
      });
    };
    if (!stream || reduce || !(window.AudioContext || window.webkitAudioContext)) {
      levels.forEach((_, i) => { levels[i] = 0.12 + 0.5 * Math.abs(Math.sin(i * 0.7)) * (stream ? 1 : 0.6); });
      draw();
      return undefined;
    }
    const AC = window.AudioContext || window.webkitAudioContext;
    const ac = new AC();
    const analyser = ac.createAnalyser();
    analyser.fftSize = 256;
    ac.createMediaStreamSource(stream).connect(analyser);
    const data = new Uint8Array(analyser.fftSize);
    let raf; let last = 0;
    const tick = (t) => {
      raf = requestAnimationFrame(tick);
      if (t - last < 70) return; // ~14 fps is plenty for a meter
      last = t;
      analyser.getByteTimeDomainData(data);
      let peak = 0;
      for (let i = 0; i < data.length; i += 1) peak = Math.max(peak, Math.abs(data[i] - 128) / 128);
      levels.shift(); levels.push(paused ? 0.06 : Math.min(1, 0.08 + peak * 1.8));
      draw();
    };
    raf = requestAnimationFrame(tick);
    return () => { cancelAnimationFrame(raf); ac.close?.(); };
  }, [stream, paused, color]);
  return <canvas ref={ref} aria-hidden="true" className="w-full h-7" />;
};

export default LevelMeter;
