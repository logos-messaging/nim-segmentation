# nim-segmentation

Nim implementation of **LIP-243 — Message Segmentation and Reconstruction**.

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

# Drop segment sets that went quiet before completing.
handler.cleanupSegments()
```

`err` is reserved for genuine internal faults. Every spec-level discard — an invalid, duplicate,
out-of-bounds or hash-failing segment — comes back as `ok(Opt.none)`, so callers never have to treat
an error as routine.

## Wire format

```protobuf
syntax = "proto3";

message SegmentMessage {
  bytes  original_payload_hash   = 1;  // Keccak256 of the original payload, 32 bytes
  uint32 original_payload_length = 2;  // length in bytes of the original payload
  uint32 index                   = 3;  // position within this segment's own class
  uint32 segment_count           = 4;  // number of items of the given class
  bool   is_parity               = 5;  // selects the class the two fields above refer to
  bytes  segment_payload         = 6;  // data chunk or parity shard
}
```

Golden byte vectors for this encoding are pinned in [tests/test_wire_vectors.nim](tests/test_wire_vectors.nim).

## Configuration

| Field | Default | Meaning |
|---|---|---|
| `segmentSizeBytes` | `102_400` | Maximum size of a **serialized** segment message. |
| `parityRate` | `0.0` | Parity segments as a fraction of data segments; `0` disables parity. Must be `< 1`. |
| `reconstructionTimeoutSeconds` | `300` | How long a set may go without a new segment before it is dropped. |
| `maxTotalSegments` | `256` | Greatest number of segments one set may hold, data and parity together. |
| `maxSegmentSets` | `100` | Concurrent partial sets retained; the least recently updated is evicted first. |

The chunk size is derived as `alignDown64(segmentSizeBytes - 64)`. It is rounded to a multiple of 64
**unconditionally**, not only when this node emits parity: Reed–Solomon requires 64-aligned shards, so
aligning always means a receiver can decode a parity-bearing set even when its own `parityRate` is `0`.

Because the segment bound is on the **sum** of both classes, the usable data-chunk ceiling is below
`maxTotalSegments` whenever parity is on — at `parityRate = 0.125` and `maxTotalSegments = 256` it is 227.
`performSegmentation` returns `err` for a payload that would exceed it.

## Layout

```
segmentation/
  segmentation.nim      # public API
  segment_message.nim   # wire codec and validity rules
  reassembly.nim        # segment-set cache: dedup, bounds, expiry
  parity.nim            # Reed-Solomon via nim-leopard
```

## Dependencies

`nim-leopard` is pinned by commit sha rather than by version range. Its `0.1.0` tag imports
`pkg/stew/results`, which no longer exists in stew; its `main` branch (declaring `0.1.1`, so it
*satisfies* `>= 0.1.0 & < 0.2.0`) switched `encode`/`decode` to a raw-pointer API whose erasure marker is
a nil pointer rather than an empty seq. The pinned `orc-support` revision declares `0.2.0` and keeps the
seq API. Once that is merged and tagged upstream, move to a normal version range.

`nimble setup -l` builds the Leopard-RS C++ library via CMake (3.7+ required).

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at
your option.
