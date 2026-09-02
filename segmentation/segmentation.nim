## Message segmentation and reconstruction, per LIP-243.
##
## Splits an application payload into transmittable segments and reassembles it
## on reception, optionally adding Reed-Solomon parity segments so a set can be
## recovered despite partial loss.
##
## This module is the package entry point; it holds no code of its own, only the
## public surface gathered from the modules below. One type per module:
##
## - `segment_message`      -- `SegmentMessage`, the wire unit, and its validity rules
## - `segment_set`          -- `SegmentSet`, a payload's segments and its reassembly
## - `segment_cache`        -- `SegmentCache`, the set store: dedup, bounds, expiry
## - `reassembled_payload`    -- `ReassembledPayload`, a reconstructed payload
## - `segmentation_config`  -- `SegmentationConfig` and its defaults
## - `segmentation_handler` -- `SegmentationHandler`, the stateful entry point
## - `parity`               -- Reed-Solomon helpers (no type of its own)
##
## Public API
## -----------
##
## Everything below is reachable from `import segmentation`; anything not listed
## is internal and may change without notice.
##
## **Setup**
## ```nim
## SegmentationConfig.init(segmentSizeBytes, parityRate,
##                         reconstructionTimeoutSeconds,
##                         maxTotalSegments, maxSegmentSets): SegmentationConfig
## SegmentationHandler.new(config): Result[SegmentationHandler, string]
## ```
##
## **Sending**
## ```nim
## handler.performSegmentation(payload): Result[seq[seq[byte]], string]
## ```
## Each element is one transport message.
##
## **Receiving**
## ```nim
## handler.handleIncomingSegment(bytes): Result[Opt[ReassembledPayload], string]
## handler.cleanupSegments()
## ```
## `Opt.none` means "not yet, or discarded"; `err` is reserved for internal
## faults, never for a segment the spec says to drop.
##
## **Introspection**
## ```nim
## handler.chunkSize(): int
## handler.pendingSets(): int
## ```
##
## **Wire unit**, for callers that inspect segments directly:
## ```nim
## SegmentMessage.init(...): SegmentMessage
## SegmentMessage.decode(bytes): Result[SegmentMessage, string]
## message.encode(): Result[seq[byte], string]
## message.isValid(maxTotalSegments): bool
## message.segmentSetKey(): string
## ```
##
## **Types**: `SegmentationHandler`, `SegmentationConfig`, `SegmentMessage`,
## `ReassembledPayload`.
## **Constants**: `Default*` config values, `SegmentHashLen`,
## `SegmentHeaderMaxBytes`, `MinSegmentSizeBytes`, `MaxSupportedTotalSegments`.
##
## Spec: https://github.com/logos-co/logos-lips -- messaging/application/raw/segmentation.md
import
  ./segmentation_handler,
  ./segment_message,
  ./segmentation_config,
  ./reassembled_payload

export segmentation_handler, segment_message, segmentation_config, reassembled_payload
