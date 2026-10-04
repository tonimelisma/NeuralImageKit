# NeuralImageKit

Swift image-processing pipelines for macOS, built around Apple Core AI.

The first pipeline aims to turn RAW photographs into nice-looking, vivid HEIF
images. Additional pipelines will bring other learned looks and HDR processing.

## Approach

Use macOS APIs for technical image development and Core AI neural models for
learned appearance. Keep lens corrections, photographic appearance and output
encoding separate so each can evolve and be evaluated independently.

Models will learn from separate source and target image pairs. Processing will
use the source image, permitted metadata and a trained model; embedded camera
previews will never be used. Original images remain read-only.

## Status

Early development. The neural pipeline and public Swift package API are not yet
available. This repository includes a standalone RAW-to-HEIF development harness,
calibration experiments and synthetic tests. These experimental models do not yet
establish photographic quality for the planned neural pipeline.

## Development

Requires macOS 27 and the full Xcode 27 toolchain.

```sh
script/check.sh
```

This compiles the standalone tools and runs numerical, CPU/Metal, capture-guard
and process-memory supervision fixtures. Training media, private manifests and
checkpoints are excluded from Git.
