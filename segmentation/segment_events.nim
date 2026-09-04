## What the receiver reports to the consumer application.
##
## The library owns no event system of its own: it invokes plain callbacks, and
## the layer above turns them into whatever it already uses. That keeps this
## package free of an async runtime, and keeps events where the context lives --
## a set drop here knows a payload hash and nothing else, while the caller knows
## the channel and the sender.
##
## Callbacks are supplied to `SegmentationHandler.new` and are never reassigned,
## so there is no window where half a handler is wired up.

{.push raises: [].}
import ./reassembled_payload

export reassembled_payload

type SegmentSetDropReason* {.pure.} = enum
  ## Why a partially received set was abandoned. In every case the payload it
  ## belonged to will never be delivered.
  Expired ## No further segment arrived within `reconstructionTimeoutSeconds`.
  Evicted ## `maxSegmentSets` was reached and this was the least recently updated.
  HashMismatch
    ## The set reassembled, but the payload did not match `original_payload_hash`.
    ## Either corruption, or the poisoning attack the spec's Integrity section
    ## describes -- an injected segment occupying an `(is_parity, index)` slot.
  Malformed
    ## The set never reassembled: its segment lengths, declared payload length
    ## and shard geometry do not agree, so the hash was never reached.

type SegmentDiscardReason* {.pure.} = enum
  ## Why a single arriving segment was dropped. The set it named, if any, is
  ## left intact.
  Undecodable ## Not well-formed protobuf.
  Invalid ## Failed the spec's validity rules; see `SegmentMessage.isValid`.
  Oversized ## `payload` was longer than `segmentSizeBytes`.
  Duplicate ## The set already holds this `(is_parity, index)`.
  CountMismatch ## `segment_count` disagreed with the count already fixed for its class.
  CacheFull
    ## `maxBufferedBytes` could not accommodate the segment even after evicting
    ## every other set. The set being built is dropped with it.

type PayloadReassembledHandler* =
  proc(payload: ReassembledPayload) {.gcsafe, raises: [].}
  ## Invoked the moment a set reassembles and its Keccak256 verifies, immediately
  ## before `handleIncomingSegment` returns the same payload.
  ##
  ## The return value and this callback report one event, not two: wire this and
  ## a consumer can ignore the returned `Opt` entirely, treating reception as
  ## uniformly callback-driven alongside the drop and discard notifications.
  ## Acting on both would process every payload twice.

type SegmentProgressHandler* =
  proc(originalPayloadHash: seq[byte], held, expected: int) {.gcsafe, raises: [].}
  ## Invoked for each segment stored, with the count now held for that payload
  ## and the data-segment count needed to reconstruct it.
  ##
  ## The only outcome the return value cannot express: it speaks solely when a
  ## set completes, so a large payload arriving over a lossy link is otherwise
  ## invisible until the end. `expected` is the data-segment count, known from
  ## the first segment of the set to arrive whichever class it belongs to, since
  ## every segment carries both class counts.

type SegmentSetDroppedHandler* = proc(
  originalPayloadHash: seq[byte], reason: SegmentSetDropReason
) {.gcsafe, raises: [].}
  ## Invoked once per abandoned set. Required: `SegmentationHandler.new` rejects
  ## a nil callback.

type SegmentDiscardedHandler* =
  proc(reason: SegmentDiscardReason) {.gcsafe, raises: [].}
  ## Invoked per rejected segment. Expect volume: duplicates are routine during
  ## retransmission. Required: `SegmentationHandler.new` rejects a nil callback.

{.pop.}
