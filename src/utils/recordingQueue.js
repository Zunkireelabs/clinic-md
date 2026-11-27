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

// ── which uploaded recordings still need transcribing ─────────────────────────────────────────────────────────────────────────
// The database knows (consultations.transcript_pieces, migration 023); this only filters. Nothing is kept in this browser any more (CMD-146).
export const untranscribedPaths = (audioPaths, transcribed) => {
  const done = new Set(transcribed || []);
  return (audioPaths || []).filter((p) => !done.has(p));
};
