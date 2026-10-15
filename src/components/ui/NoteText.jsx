import React from 'react';

// Read-only rendering of note text: lines starting with "- " or "* " become a real bullet list, other lines stay paragraphs.
// The same text is edited as plain "- " lines in a textarea (consultation page); the chart shows it through this component.
export const parseNoteLines = (text = '') => {
  const blocks = [];
  String(text || '').split('\n').forEach((raw) => {
    const line = raw.replace(/\s+$/, '');
    if (!line.trim()) return;
    const bullet = line.match(/^\s*[-*•]\s+(.*)$/);
    const last = blocks[blocks.length - 1];
    if (bullet) {
      if (last?.type === 'list') last.items.push(bullet[1]); else blocks.push({ type: 'list', items: [bullet[1]] });
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
        ? <ul key={i} className="list-disc pl-5 space-y-0.5 marker:text-[#8A8A90]">{b.items.map((it, j) => <li key={j}>{it}</li>)}</ul>
        : <p key={i}>{b.text}</p>))}
    </div>
  );
};

export default NoteText;
