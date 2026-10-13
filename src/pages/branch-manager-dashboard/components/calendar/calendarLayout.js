// Pure layout math for overlapping bookings in a grid column: clustering, the side-by-side card slots and the
// "+N" overflow badge geometry.
// ── Overlap layout constants & helpers ─────────────────
export const MAX_VISIBLE_OVERLAP = 2;
const OVERLAP_GAP = 2;       // px between side-by-side cards
export const OVERLAP_PADDING = 4;   // px from column edges

/**
 * Group overlapping bookings into clusters.
 * Sweep algorithm: sort by startTime, extend running max endTime.
 * Strict overlap (startTime < clusterEnd), back-to-back are separate clusters.
 * Ties on startTime (e.g. simultaneous online bookings) break by createdAt so
 * whichever booking was actually placed first (down to the millisecond) lands
 * in the leftmost card slot.
 */
export function clusterOverlapping(bookings) {
  const valid = bookings.filter(b => b.startTime && b.endTime);
  if (valid.length === 0) return [];

  const sorted = [...valid].sort((a, b) => {
    const byStart = a.startTime.localeCompare(b.startTime);
    if (byStart !== 0) return byStart;
    if (a.createdAt && b.createdAt) return new Date(a.createdAt) - new Date(b.createdAt);
    if (a.createdAt) return -1;
    if (b.createdAt) return 1;
    return 0;
  });
  const clusters = [[sorted[0]]];
  let clusterEnd = sorted[0].endTime;

  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i].startTime < clusterEnd) {
      clusters[clusters.length - 1].push(sorted[i]);
      if (sorted[i].endTime > clusterEnd) clusterEnd = sorted[i].endTime;
    } else {
      clusters.push([sorted[i]]);
      clusterEnd = sorted[i].endTime;
    }
  }
  return clusters;
}

// True end time of a cluster — the latest endTime across ALL members, not
// just cluster[0] (the earliest-STARTING member, which sort order guarantees,
// but which can easily have an earlier end than a later-starting member it
// transitively overlaps through a third booking). Using cluster[0].endTime
// alone under-sizes the cluster's rendered box whenever that happens, which
// visually clips the "+N more" badge into the wrong time range — it renders
// within the earliest member's span even when the hidden booking(s) it
// represents start later, making a booking near the END of a wide cluster
// look like it's happening near the cluster's start until you click it.
export function clusterEndTime(cluster) {
  return cluster.reduce((max, b) => (b.endTime > max ? b.endTime : max), cluster[0].endTime);
}

// Earliest startTime across a set of bookings — symmetric counterpart to
// clusterEndTime(). Used to position the collapsed overflow badge at the
// actual time span of the bookings it hides, not the whole cluster's span.
export function earliestStartTime(items) {
  return items.reduce((min, b) => (b.startTime < min ? b.startTime : min), items[0].startTime);
}

// The overflow badge only ever needs to fit "+N" — giving it a full card-width
// slot (the old behavior) squeezed the two real cards into equal thirds. It
// gets a fixed narrow width instead (clamped so it stays legible in very
// narrow/zoomed-out columns); cards keep the rest of the space.
const BADGE_MIN_WIDTH = 34;
const BADGE_MAX_WIDTH = 56;
export const BADGE_MIN_HEIGHT = 64; // px — keeps wrapped "+N" text readable on short clusters

/**
 * Calculate positioning for cards within an overlap cluster.
 * Shows up to MAX_VISIBLE_OVERLAP full-size cards side by side; any extra
 * bookings collapse into a "+N more" badge (see OverflowBadge) instead of
 * being squeezed into ever-thinner slivers.
 * Returns { cards: [{left, width}|null], badge: {left, width, count}|null }
 */
export function getOverlapLayout(clusterSize, columnWidth) {
  if (clusterSize <= 1) {
    return { cards: [null], badge: null };
  }

  const availableWidth = columnWidth - OVERLAP_PADDING * 2;
  const visibleCount = Math.min(clusterSize, MAX_VISIBLE_OVERLAP);
  const hasBadge = clusterSize > MAX_VISIBLE_OVERLAP;
  const MIN_CARD_WIDTH = 10; // px — floor so cards never go negative-width in a very narrow/zoomed-out column

  const totalGap = (visibleCount + (hasBadge ? 1 : 0) - 1) * OVERLAP_GAP;
  let badgeWidth = hasBadge
    ? Math.min(BADGE_MAX_WIDTH, Math.max(BADGE_MIN_WIDTH, Math.round(availableWidth * 0.38)))
    : 0;
  // The badge's own min-width can exceed what's left for cards in a very
  // narrow column — shrink it (even below BADGE_MIN_WIDTH) rather than let
  // the cards go negative-width.
  if (hasBadge) {
    const maxBadgeWidth = availableWidth - totalGap - MIN_CARD_WIDTH * visibleCount;
    badgeWidth = Math.max(0, Math.min(badgeWidth, maxBadgeWidth));
  }
  const cardWidth = Math.max(MIN_CARD_WIDTH, Math.floor((availableWidth - totalGap - badgeWidth) / visibleCount));

  const cards = [];
  for (let i = 0; i < visibleCount; i++) {
    cards.push({
      left: OVERLAP_PADDING + i * (cardWidth + OVERLAP_GAP),
      width: cardWidth,
    });
  }

  let badge = null;
  if (hasBadge) {
    badge = {
      left: OVERLAP_PADDING + visibleCount * (cardWidth + OVERLAP_GAP),
      width: badgeWidth,
      count: clusterSize - MAX_VISIBLE_OVERLAP,
    };
  }

  return { cards, badge };
}
