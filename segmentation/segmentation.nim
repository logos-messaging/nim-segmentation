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
## - `segment_message_pb`   -- `SegmentMessagePB`, the proto3 mirror (type only)
## - `segment_set`          -- `SegmentSet`, a payload's segments and its reassembly
## - `segment_cache`        -- `SegmentCache`, the set store: dedup, bounds, expiry
## - `reassembled_payload`    -- `ReassembledPayload`, a reconstructed payload
## - `segmentation_config`  -- `SegmentationConfig` and its defaults
## - `segmentation_handler` -- `SegmentationHandler`, the stateful entry point
## - `parity`               -- Reed-Solomon helpers (no type of its own)
##
## Spec: https://github.com/logos-co/logos-lips -- messaging/application/raw/segmentation.md
import
  ./segmentation_handler,
  ./segment_message,
  ./segment_message_pb,
  ./segmentation_config,
  ./reassembled_payload

export
  segmentation_handler, segment_message, segment_message_pb, segmentation_config,
  reassembled_payload
