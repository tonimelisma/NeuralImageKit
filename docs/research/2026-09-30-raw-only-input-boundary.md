# RAW-only input boundary and publication evidence

> Research evidence from the stated date. Earlier experiment choices are superseded by the active neural-development plan; results are not acceptance of the current pipeline.
Date: September 30, 2026. First execution milestone of the revised Plan 0105.
Standalone RAW decoder 9; no app integration. This verifies the input boundary,
not completion of photographic quality or generalization.

## Hypothesis and fixed factors

Removing camera-guide dependencies must preserve the saved RAW-only baseline.
Changing camera previews while preserving sensor data and capture metadata must
leave every decoded native output pixel unchanged. The look coefficients and
all RAW controls remain fixed; draft mode is now explicitly false.

## Implementation

The renderer/evaluator no longer accepts a camera-guide switch. PreviewGuide and
both embedded-JPEG comparator source files and CLI modes are removed. Rendering
uses one immediately materialization-gated Data read for metadata and CIRAWFilter;
the metadata source carries the camera RAW type hint. Native lens correction remains
separate. Cancellation is checked around expensive work and before publication;
CancellationError is preserved and temporary output cleaned up.

## Private runtime experiment

A verified capture (`[capture]`) was copied into a private fixture directory
outside media roots. In a second copy, both camera JPEG blobs were replaced with
valid constant-colour JPEGs of the same dimensions and padded to their original
lengths. The rest of the container is unchanged. This modifies private copies,
never originals. The folder contains only the two RAWs, with no companion images.

- PreviewImage: offset 196770, length 417996, dimensions 1616 x 1080.
- JpgFromRaw: offset 618496, length 3814864, dimensions 6192 x 4128.
- Sensor strip: offset 4435968, length 33208992, identical SHA256
  `e9ffc111403a7e811336af3dde1a8d97883735117b6ff6ab79daa96991f6d8bb`.
- Whole-file size and every byte outside the two JPEG spans are unchanged.
- Both RAW-only exports succeed at 6192 x 4128, reporting 10-bit output, RAW 9
  and supported/enabled native lens correction.
- Image I/O decodes each HEIF to a 16-bit-per-component buffer. The decoded buffers
  are byte-identical, including all 25,560,576 native pixels, and identical to the
  previously saved RAW-only baseline output. SHA256:
  `057dcf1469a1ff4b11ad94aa24dc3ad26afcb1ad37eb3f38b763f7631c8357c5`.
  Decode buffer precision does not alter the reported 10-bit file encoding.

Private evidence: `raw-only-preview-independence/fixture-report.json`, both export
JSON records and `pixel-comparison.log` under the existing private harness root.
The build is `raw-only-framework-build/camera-render-harness`; the model is the
committed RAW 9 reference. The test proves independence for these valid replacement
previews; it does not claim all camera containers tolerate deleting preview tags.
No separate operating-system file-denial tracer was used. Rendering with no
companion present demonstrates that a companion is unnecessary for this path.

## Operational evidence

Standalone published DE00, geometry, capture, model/calibration rejection,
destination/original/cancellation and 560 CPU/Metal fixtures pass. Maximum model
GPU discrepancy is 1.998e-7. A private executable compiled from the revised renderer
cancels an actual render after observing its temporary HEIF file: CancellationError
is returned, no final file is published and zero temporary files remain
(`raw-only-cancellation-runtime.log`). This is cancellation during encoding;
underlying synchronous Core Image work is not interruptible mid-call.

## Decision and next feedback

Adopt removal of forbidden camera inputs: native pixels remain unchanged. Retain
the saved baseline only as a comparator. Next produce the look card and measured
failure atlas, then change gamut mapping alone with all other native controls fixed.
Repository verification and integration are reported separately; these fixtures
are not evidence that the entire plan is implemented.
