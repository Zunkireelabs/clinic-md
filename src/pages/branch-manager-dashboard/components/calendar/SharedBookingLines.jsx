import React, { useEffect, useState, useCallback } from 'react';

// SVG overlay: inverted-U bracket connectors between shared booking cards
export const SharedBookingLines = ({ containerRef, bookings }) => {
  const [brackets, setBrackets] = useState([]);

  const drawBrackets = useCallback(() => {
    if (!containerRef.current) return;
    const container = containerRef.current;
    const sharedCards = container.querySelectorAll('[data-shared="true"]');
    if (sharedCards.length === 0) { setBrackets([]); return; }

    const groups = {};
    sharedCards.forEach(card => {
      const bid = card.dataset.bookingId;
      if (!groups[bid]) groups[bid] = [];
      groups[bid].push(card);
    });

    const containerRect = container.getBoundingClientRect();
    const newBrackets = [];

    Object.entries(groups).forEach(([bid, cards]) => {
      if (cards.length < 2) return;
      const sorted = [...cards].sort((a, b) => a.getBoundingClientRect().left - b.getBoundingClientRect().left);
      const rects = sorted.map(c => c.getBoundingClientRect());

      // Find the topmost card position
      const minTop = Math.min(...rects.map(r => r.top - containerRect.top));
      // Bridge line sits 20px above the topmost card
      const bridgeY = Math.max(minTop - 20, 2);

      // Build path: for each card, go up from top-center to bridgeY, then horizontal across
      const points = rects.map(r => ({
        cx: r.left + r.width / 2 - containerRect.left,
        cardTop: r.top - containerRect.top,
      }));

      // SVG path: vertical lines up + horizontal bridge
      let path = '';
      points.forEach((p, i) => {
        // Vertical line from card top to bridge
        path += `M ${p.cx} ${p.cardTop} L ${p.cx} ${bridgeY} `;
      });
      // Horizontal bridge connecting leftmost to rightmost
      path += `M ${points[0].cx} ${bridgeY} L ${points[points.length - 1].cx} ${bridgeY} `;

      newBrackets.push({ key: bid, path });
    });

    setBrackets(newBrackets);
  }, [containerRef]);

  useEffect(() => {
    drawBrackets();
    // Multiple delayed redraws to catch DOM settling after data refresh
    const t1 = setTimeout(drawBrackets, 50);
    const t2 = setTimeout(drawBrackets, 200);
    const t3 = setTimeout(drawBrackets, 500);
    return () => { clearTimeout(t1); clearTimeout(t2); clearTimeout(t3); };
  }, [drawBrackets, bookings]);

  // Redraw on scroll
  useEffect(() => {
    const scrollEl = containerRef.current?.closest('.overflow-auto, [class*="overflow-x"]');
    if (!scrollEl) return;
    const handler = () => drawBrackets();
    scrollEl.addEventListener('scroll', handler);
    return () => scrollEl.removeEventListener('scroll', handler);
  }, [containerRef, drawBrackets]);

  // Redraw when DOM changes (cards move/appear/disappear)
  useEffect(() => {
    if (!containerRef.current) return;
    const observer = new MutationObserver(() => {
      requestAnimationFrame(drawBrackets);
    });
    observer.observe(containerRef.current, { childList: true, subtree: true, attributes: true, attributeFilter: ['style'] });
    return () => observer.disconnect();
  }, [containerRef, drawBrackets]);

  if (brackets.length === 0) return null;

  return (
    <svg className="absolute inset-0 pointer-events-none" style={{ zIndex: 5, overflow: 'visible' }}>
      {brackets.map(b => (
        <path
          key={b.key}
          d={b.path}
          fill="none"
          stroke="#dc2626"
          strokeWidth={2}
          strokeLinejoin="round"
          opacity={0.7}
        />
      ))}
    </svg>
  );
};

export default SharedBookingLines;
