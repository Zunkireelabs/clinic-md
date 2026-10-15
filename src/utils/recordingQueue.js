// Recordings that are not safely through the pipeline yet. A recording is never dropped: it stays in the queue until it has been
// uploaded AND transcribed. (There used to be a single "failed recording" slot, so a second failure overwrote the first.)
//
// item = { id, blob, mimeType, durationSeconds, audioPath|null, status }
//   status: 'uploading' | 'transcribing' | 'failed-upload' | 'failed-transcribe'

let counter = 0;
export const newQueueItem = ({ blob, mimeType, durationSeconds, audioPath = null }) => {
  counter += 1;
  return { id: `rec-${Date.now()}-${counter}`, blob: blob || null, mimeType, durationSeconds, audioPath, status: audioPath ? 'transcribing' : 'uploading', error: null };
};

export const enqueue = (queue, item) => [...queue, item];
export const update = (queue, id, patch) => queue.map((q) => (q.id === id ? { ...q, ...patch } : q));
export const remove = (queue, id) => queue.filter((q) => q.id !== id);

/** True while any audio only exists in this browser tab (not uploaded yet): leaving the page would lose it. */
export const hasUnuploaded = (queue) => queue.some((q) => !q.audioPath && q.blob);

export const failedItems = (queue) => queue.filter((q) => q.status === 'failed-upload' || q.status === 'failed-transcribe');
export const hasUploadFailure = (queue) => queue.some((q) => q.status === 'failed-upload');
export const isBusy = (queue) => queue.some((q) => q.status === 'uploading' || q.status === 'transcribing');

// ── which uploaded recordings still need transcribing (per audio path, survives a reload) ────────────────────────────────────
// Stored per consultation in this browser. Recordings that arrive from the other device are assumed to be transcribed there.
export const transcribedKey = (consultationId) => `clinicmd.consultation.${consultationId}.transcribed`;

/** First time on this device: if there is already a transcript, assume the existing recordings were transcribed; otherwise none were. */
export const seedTranscribed = (audioPaths, transcript) => (String(transcript || '').trim() ? [...(audioPaths || [])] : []);

export const untranscribedPaths = (audioPaths, transcribed) => {
  const done = new Set(transcribed || []);
  return (audioPaths || []).filter((p) => !done.has(p));
};

export const readTranscribed = (consultationId, storage = typeof window !== 'undefined' ? window.localStorage : null) => {
  try { const raw = storage?.getItem(transcribedKey(consultationId)); return raw ? JSON.parse(raw) : null; } catch { return null; }
};
export const writeTranscribed = (consultationId, paths, storage = typeof window !== 'undefined' ? window.localStorage : null) => {
  try { storage?.setItem(transcribedKey(consultationId), JSON.stringify([...new Set(paths)])); } catch { /* storage unavailable */ }
};
