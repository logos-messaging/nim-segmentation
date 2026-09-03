## In-memory cache of partially received segment sets.
##
## A set is keyed by `(original_payload_hash, original_payload_length)` only.
## `segment_count` is deliberately NOT part of the key: it counts one class, so
## keying on it would file a payload's data and parity segments under two
## different sets and parity recovery would never fire.
##
## This module owns storage, dedup, bounds and expiry. Hashing, Reed-Solomon and
## payload assembly live in `reconstruction`.

{.push raises: [].}
import std/[monotimes, tables, times]
import results
import ./segment_events, ./segment_message, ./segment_set

export segment_events, segment_set, monotimes, tables, times

type AddOutcome* {.pure.} = enum
  Accepted ## Stored; the set may now be reconstructible.
  Ignored ## Discarded per the spec -- duplicate, conflicting counts, or over bounds.

type SegmentCache* = ref object
  sets: Table[string, SegmentSet]
  maxSets: int
  maxBytes: int
  heldBytes: int
  timeout: Duration
  onSetDropped: SegmentSetDroppedHandler

func new*(
    T: type SegmentCache,
    maxSets: int,
    maxBytes: int,
    timeout: Duration,
    onSetDropped: SegmentSetDroppedHandler = nil,
): T =
  ## `onSetDropped` fires for every set this cache abandons: expiry, eviction and
  ## the both-classes-known bound. `nil` disables it.
  ##
  ## Two independent bounds, as the spec's Segment Caching section requires:
  ## `maxSets` caps how many payloads may be in flight, `maxBytes` caps what they
  ## may occupy. The set cap alone leaves the byte ceiling at
  ## `maxSets * maxTotalSegments * segmentSizeBytes`, which is far too large to
  ## be the real protection.
  return T(
    sets: initTable[string, SegmentSet](),
    maxSets: maxSets,
    maxBytes: maxBytes,
    timeout: timeout,
    onSetDropped: onSetDropped,
  )

proc notifyDropped(self: SegmentCache, s: SegmentSet, reason: SegmentSetDropReason) =
  if not self.onSetDropped.isNil():
    self.onSetDropped(s.originalPayloadHash, reason)

func len*(self: SegmentCache): int =
  return self.sets.len

func bufferedBytes*(self: SegmentCache): int =
  ## Segment payload bytes currently held across all sets.
  return self.heldBytes

proc forget(self: SegmentCache, key: string): SegmentSet =
  ## Remove a set and give back its byte budget. The single removal path, so the
  ## running total cannot drift. Returns nil when the key was not held.
  let s = self.sets.getOrDefault(key, nil)
  if not s.isNil():
    self.heldBytes -= s.heldBytes
    self.sets.del(key)
  return s

func get*(self: SegmentCache, key: string): SegmentSet =
  return self.sets.getOrDefault(key, nil)

proc remove*(self: SegmentCache, key: string) =
  ## Silent removal, for a set the caller has finished with or is dropping for a
  ## reason it reports itself.
  discard self.forget(key)

proc sweep*(self: SegmentCache, now: MonoTime) =
  ## Drop sets that have gone `timeout` without a new segment, notifying for each.
  var expired: seq[string]
  for key, s in self.sets:
    if now - s.lastUpdate >= self.timeout:
      expired.add(key)
  for key in expired:
    let s = self.forget(key)
    if not s.isNil():
      self.notifyDropped(s, SegmentSetDropReason.Expired)

proc evictOldest(self: SegmentCache, keep: string = ""): bool =
  ## Drop the least recently updated set, never `keep`. False when there was
  ## nothing eligible left to drop.
  var oldestKey = ""
  var oldest = MonoTime.default
  var first = true
  for key, s in self.sets:
    if key == keep:
      continue
    if first or s.lastUpdate < oldest:
      oldest = s.lastUpdate
      oldestKey = key
      first = false
  if first:
    return false
  let s = self.forget(oldestKey)
  if not s.isNil():
    self.notifyDropped(s, SegmentSetDropReason.Evicted)
  return true

proc makeRoom(self: SegmentCache, needed: int, keep: string): bool =
  ## Evict least-recently-updated sets until `needed` more bytes fit. False when
  ## the budget cannot accommodate them even with everything else gone.
  while self.heldBytes + needed > self.maxBytes:
    if not self.evictOldest(keep):
      return false
  return true

proc add*(
    self: SegmentCache, m: SegmentMessage, now: MonoTime
): tuple[outcome: AddOutcome, key: string, discardReason: Opt[SegmentDiscardReason]] =
  ## Store a segment that has already passed `isValid`.
  let key = segmentSetKey(m)

  var s = self.sets.getOrDefault(key, nil)
  if s.isNil():
    if self.sets.len >= self.maxSets:
      discard self.evictOldest()
    s = SegmentSet.new(
      m.originalPayloadHash, m.originalPayloadLength, m.dataSegmentCount,
      m.paritySegmentCount, now,
    )
    self.sets[key] = s

  # The spec calls segments disagreeing on the counts different sets. Keying on
  # the counts would let one sender open unbounded sets under a single hash, so
  # the disagreeing segment is discarded instead.
  if s.dataCount != m.dataSegmentCount or s.parityCount != m.paritySegmentCount:
    return (AddOutcome.Ignored, key, Opt.some(SegmentDiscardReason.CountMismatch))

  # `(is_parity, index)` is unique within a set; a repeat is ignored rather than
  # overwritten, and must not extend the set's life -- the spec expires a set
  # that receives no *further* segments.
  if m.isParity:
    if s.parity.hasKey(m.index):
      return (AddOutcome.Ignored, key, Opt.some(SegmentDiscardReason.Duplicate))
  else:
    if s.data.hasKey(m.index):
      return (AddOutcome.Ignored, key, Opt.some(SegmentDiscardReason.Duplicate))

  # Evict other sets to fit this segment; if the budget still cannot hold it,
  # drop the set being built rather than exceeding the bound.
  if not self.makeRoom(m.payload.len, key):
    let dropped = self.forget(key)
    if not dropped.isNil():
      self.notifyDropped(dropped, SegmentSetDropReason.Evicted)
    return (AddOutcome.Ignored, key, Opt.some(SegmentDiscardReason.CacheFull))

  if m.isParity:
    s.parity[m.index] = m.payload
  else:
    s.data[m.index] = m.payload
  s.heldBytes += m.payload.len
  self.heldBytes += m.payload.len

  s.lastUpdate = now
  return (AddOutcome.Accepted, key, Opt.none(SegmentDiscardReason))

{.pop.}
