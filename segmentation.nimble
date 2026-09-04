# Package

version = "0.1.0"
author = "Logos Messaging Team"
description = "Message segmentation and reconstruction (LIP-243)"
license = "MIT"
srcDir = "segmentation"

# Dependencies

requires "nim >= 2.2.6"
requires "results"
requires "nimcrypto"
requires "protobuf_serialization >= 0.5.0"
requires "unittest2"
# Pinned by sha: the `0.1.0` tag imports `pkg/stew/results`, which no longer
# exists in stew, and `main` (declaring 0.1.1) switched encode/decode to a
# raw-pointer API whose erasure marker is a nil pointer rather than an empty
# seq. The `orc-support` branch declares 0.2.0 and keeps the seq API.
requires "https://github.com/status-im/nim-leopard#0478b12df90cbbe531efa69422cff67b5a3a5d93"

# Tasks

task test, "Run the test suite":
  exec "nim c -r --outdir:build tests/test_segment_message.nim"
  exec "nim c -r --outdir:build tests/test_parity.nim"
  exec "nim c -r --outdir:build tests/test_segmentation.nim"
  exec "nim c -r --outdir:build tests/test_wire_vectors.nim"

task clean, "Remove build artifacts":
  if dirExists "build":
    rmDir "build"
