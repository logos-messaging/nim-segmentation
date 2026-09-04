# nim-segmentation

Nim implementation of **[LIP-243](https://lip.logos.co/messaging/application/raw/segmentation.html) — Message Segmentation and Reconstruction**.

Carries an application payload larger than the transport's maximum message size by splitting it into
segments that the receiver reassembles, out of order, and — with optional Reed–Solomon parity —
despite partial loss.

## Quick start

```bash
nimble setup -l   # installs dependencies, including nim-leopard's C++ core
nimble test
```

## Usage

```nim
import segmentation

let handler = SegmentationHandler.new(
  SegmentationConfig.init(segmentSizeBytes = 102_400, parityRate = 0.125)
).expect("valid config")

# Sender: each element is one transport message.
for segment in handler.performSegmentation(payload).get():
  transport.send(segment)

# Receiver: `Opt.none` means "not yet" (or a discarded segment); `Opt.some`
# carries the reassembled payload.
let reassembled = handler.handleIncomingSegment(received).get()
if reassembled.isSome():
  deliver(reassembled.get().payload)

# Drop segment sets that are too old. This should be called periodically
# at a rate near reconstructionTimeoutSeconds.
handler.cleanupSegments()
```

Reception discards more than it delivers, and the return value describes only delivery.
Everything else is reported through callbacks supplied at construction:

```nim
let handler = SegmentationHandler.new(
  config,
  onSetDropped = proc(hash: seq[byte], reason: SegmentSetDropReason) {.gcsafe, raises: [].} =
    # Expired | Evicted | HashMismatch | Malformed -- this payload never arrives
    emitMessageLost(hash, reason),
  onSegmentDiscarded = proc(reason: SegmentDiscardReason) {.gcsafe, raises: [].} =
    # Undecodable | Invalid | Oversized | Duplicate | CountMismatch
    metrics.inc(reason),
  onPayloadReassembled = proc(p: ReassembledPayload) {.gcsafe, raises: [].} =
    emitMessageReceived(p.originalPayloadHash, p.payload),
  onSegmentProgress = proc(hash: seq[byte], held, expected: int) {.gcsafe, raises: [].} =
    # Partial arrival -- the one outcome the return value cannot express
    reportProgress(hash, held, expected),
).expect("valid config")
```

All four are **required** — `new` fails on a nil callback. Reception discards far more
than it delivers, and an expired, evicted or hash-failing set has no other channel, so an
unwired `onSetDropped` loses payloads silently. Ignoring an outcome is fine, it just has
to be an explicit no-op rather than an omission:

```nim
proc ignoreDropped(hash: seq[byte], reason: SegmentSetDropReason) {.gcsafe, raises: [].} =
  discard
```

The callbacks are `{.gcsafe.}`, so they may close over locals or a context object but not
over mutable module-level globals. See [tools/roundtrip_demo.nim](tools/roundtrip_demo.nim)
for a complete working example.

`onPayloadReassembled` fires immediately before `handleIncomingSegment` returns the same
payload. They are one event reported twice: wire the callback and the returned `Opt` can
be ignored, which makes reception uniformly event-driven. Acting on both delivers every
payload twice.

The library deliberately has no event system of its own: a drop
here knows a payload hash and nothing more, while the caller knows the channel and the
sender, so it is better placed to raise the event.

`err` is reserved for genuine internal faults. Every spec-level discard — an invalid, duplicate,
out-of-bounds or hash-failing segment — comes back as `ok(Opt.none)`, so callers never have to treat
an error as routine.

## Configuration

| Field | Default | Meaning |
|---|---|---|
| `segmentSizeBytes` | `102_400` | Maximum size of a **serialized** segment message. |
| `parityRate` | `0.0` | Parity segments as a fraction of data segments; `0` disables parity. Must not exceed `1`. |
| `reconstructionTimeoutSeconds` | `300` | How long a set may go without a new segment before it is dropped. |
| `maxTotalSegments` | `256` | Greatest number of segments one set may hold, data and parity together. |
| `maxSegmentSets` | `100` | Concurrent partial sets retained; the least recently updated is evicted first. |
| `maxBufferedBytes` | `32 MiB` | Segment bytes held across all incomplete sets. The bound that actually caps memory. |

The chunk size is derived as `alignDown64(segmentSizeBytes - 128)`. It is rounded to a multiple of 64
**unconditionally**, not only when this node emits parity: Reed–Solomon requires 64-aligned shards, so
aligning always means a receiver can decode a parity-bearing set even when its own `parityRate` is `0`.

Because the segment bound is on the **sum** of both classes, the usable data-chunk ceiling is below
`maxTotalSegments` whenever parity is on — at `parityRate = 0.125` and `maxTotalSegments = 256` it is 227.
`performSegmentation` returns `err` for a payload that would exceed it.

## Layout

One type per module; `segmentation.nim` is the entry point and re-exports the public surface.

```
segmentation/
  segmentation.nim            # package entry point, no code of its own
  segment_message.nim         # SegmentMessage -- the wire unit, and its validity rules
  segment_message_pb.nim      # SegmentMessagePB -- proto3 mirror and codec
  segment_set.nim             # SegmentSet -- a payload's segments, and its reassembly
  segment_events.nim          # drop/discard reasons and callback signatures
  segment_cache.nim           # SegmentCache -- set store: dedup, bounds, expiry
                              # (with AddOutcome, its result enum)
  reassembled_payload.nim     # ReassembledPayload -- a reconstructed payload
  segmentation_config.nim     # SegmentationConfig and its defaults
  segmentation_handler.nim    # SegmentationHandler -- the stateful entry point
  parity.nim                  # Reed-Solomon helpers (no type of its own)
```

A type's operations live in its own module, so private fields stay private:
`SegmentCache.sets` and the handler's internals are reachable only from the module
that declares them.

## Dependencies

`nim-leopard` is pinned by commit sha rather than by version range. Its `0.1.0` tag imports
`pkg/stew/results`, which no longer exists in stew; its `main` branch (declaring `0.1.1`, so it
*satisfies* `>= 0.1.0 & < 0.2.0`) switched `encode`/`decode` to a raw-pointer API whose erasure marker is
a nil pointer rather than an empty seq. The pinned `orc-support` revision declares `0.2.0` and keeps the
seq API. Once that is merged and tagged upstream, move to a normal version range.

`nimble setup -l` builds the Leopard-RS C++ library via CMake (3.7+ required).

## Security

This library **authenticates nothing**, by design — the spec puts sender authentication
out of scope.

`original_payload_hash` detects accidental corruption and mismatched segments, but an
attacker able to inject transport messages can compute a consistent hash over a payload of
their own. The same attacker can deny reconstruction outright: injecting a segment that
occupies an `(is_parity, index)` already held makes the receiver ignore the genuine one,
so the set fails its hash check and never reconstructs. That surfaces as
`onSetDropped(hash, HashMismatch)` — which is why that callback exists.

**Applications SHOULD encrypt each serialized `SegmentMessage` before transmission.** That
hides `original_payload_hash` from observers, which both keeps the segments of one payload
from being linked to each other and denies an attacker the hash the poisoning attack needs.
Applications requiring authenticity must obtain it from another layer.

On memory: a remote sender controls how much a receiver buffers, so `maxSegmentSets` and
`maxBufferedBytes` are the mitigation and both are enforced. Note they are **global, not
per-sender** — this library takes no sender identity, so one hostile sender can evict
another's in-flight sets. Where the transport authenticates senders, use one handler per
sender to partition the budget. Rate limiting at the transport bounds how fast an attacker
can create pending reconstructions.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at
your option.
