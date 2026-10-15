import React from 'react';

// Read-only rendering of note text: lines starting with "- " or "* " become a real bullet list, other lines stay paragraphs.
// The same text is edited as plain "- " lines in a textarea (consultation page); the chart shows it through this component.
export const parseNoteLines = (text = '') => {
  const blocks = [];
  String(text || '').split('\n').forEach((raw) => {
    const line = raw.replace(/\s+$/, '');
    if (!line.trim()) return;
    const bullet = line.match(/^(\s*)[-*•]\s+(.*)$/);
    const last = blocks[blocks.length - 1];
    if (bullet) {
      const nested = bullet[1].length >= 2 && last?.type === 'list';
      if (nested) { const parent = last.items[last.items.length - 1]; parent.children.push(bullet[2]); }
      else if (last?.type === 'list') last.items.push({ text: bullet[2], children: [] });
      else blocks.push({ type: 'list', items: [{ text: bullet[2], children: [] }] });
    } else blocks.push({ type: 'p', text: line.trim() });
  });
  return blocks;
};

const NoteText = ({ text, className = '' }) => {
  const blocks = parseNoteLines(text);
  if (!blocks.length) return null;
  return (
    <div className={`space-y-1 break-words ${className}`}>
      {blocks.map((b, i) => (b.type === 'list'
        ? (
          <ul key={i} className="list-disc pl-5 space-y-0.5 marker:text-[#8A8A90]">
            {b.items.map((it, j) => (
              <li key={j}>{it.text}{it.children.length > 0 && <ul className="list-[circle] pl-5 mt-0.5 space-y-0.5">{it.children.map((c, k) => <li key={k}>{c}</li>)}</ul>}</li>
            ))}
          </ul>
        )
        : <p key={i}>{b.text}</p>))}
    </div>
  );
};

export default NoteText;
