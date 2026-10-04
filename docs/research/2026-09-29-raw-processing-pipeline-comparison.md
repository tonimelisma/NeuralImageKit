# RAW processing pipeline comparison (2026-09-29)

> Research evidence from the stated date. Earlier experiment choices are superseded by the active neural-development plan; results are not acceptance of the current pipeline.
This review informs the standalone the initial test camera RAW-to-HEIF renderer. The
user chose Core Image RAW decoder version 9 as its foundation. The target is a
ready 10-bit SDR HEIF developed from the sensor RAW, with the target vivid look companions
used only for evaluation and private calibration. Lens corrections remain a
distinct concern; custom lens profiles are deferred under the separate
[lens review](2026-09-29-lens-profile-options.md).

## What established processors separate

Apple describes RAW development as metadata/unpacking, demosaic, denoise,
sharpen/local contrast, then white balance, exposure, color and tone. RAW 9
changes the demosaic/denoise foundation with a Core ML model; it is opt-in,
not the default decoder. The the initial test camera samples probed locally report RAW
versions 7, 8 and 9 as supported. In RAW 9,
`colorNoiseReductionAmount` has no effect and `detailAmount` and
`moireReductionAmount` are unsupported. A full-resolution export should use a
`CIContext` with `cacheIntermediates: false`; interactive repeat rendering has
different caching advice. [Apple WWDC26](https://developer.apple.com/videos/play/wwdc2026/305/).

Darktable describes a scene-referred workflow that retains floating-point,
unbounded values and leaves display preparation until a final transform. Its
color-calibration module expects linear scene-referred RGB and distinguishes
technical white balance from later chromatic adaptation and creative grading.
Processing modules have explicit input/output spaces and order. This is a
reason to test an earlier, linear Core Image output boundary rather than assume
an encoded-sRGB correction is lossless; it is not proof that Core Image exposes
Apple's intermediate sensor data.
[Darktable color pipeline](https://docs.darktable.org/usermanual/development/en/special-topics/color-pipeline/),
[color calibration](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/color-calibration/),
[Apple `linearSpaceFilter`](https://developer.apple.com/documentation/coreimage/cirawfilter/linearspacefilter).

RawTherapee also publishes a fixed processing order: technical RAW preparation,
optical corrections, demosaic and highlight work precede color-space conversion,
while tone curves and RGB color styling occur later. It describes an
auto-match tone curve as its own late operation. This supports independently
switchable and testable adjustments with a declared order, rather than one
undifferentiated "make it like the JPEG" transform.
[RawTherapee toolchain](https://rawpedia.rawtherapee.com/Toolchain_Pipeline).

The practical boundaries for this renderer are:

1. **Sensor development:** choose RAW 9 explicitly, retain camera white balance
   and exposure metadata, and document supported RAW controls. Apple owns the
   internal demosaic/denoise order, which the API does not fully expose.
2. **Lens stage:** use Apple's supported native correction and record the lens,
   focal length, and correction state. Measure geometry, vignetting and lateral
   chromatic aberration independently of color. Do not fit a lens defect into
   the shared camera look or apply a second broad profile on top of Apple.
3. **Color calibration:** test a scene-linear or extended-range boundary and
   isolate white balance/chromatic adaptation and camera-to-working-space
   color from the later display look where Core Image exposes enough control.
   Measure highlight and gamut preservation before committing to that boundary.
4. **Tone and camera look:** calibrate display tone and creative color from
   separate camera HEIF training companions. Keep the fixed global curves/LUT
   independently evaluable from any optional per-image adaptation. The current
   fixed model mixes color and tone; it is an empirical baseline, not proof
   that those effects are independently solved. An embedded camera JPEG may
   guide a smooth per-image field, but is never substituted for sensor output.
5. **Output:** make the transfer function, output space, clipping, bit depth,
   compression and metadata explicit. Test the decoded HEIF, not just an
   in-memory frame.

These are distinct responsibilities and measurements. They do not imply that
every visible adjustment is mathematically independent: Apple's internal RAW
stages are coupled, and a per-channel curve plus residual LUT can mix hue and
tone. The model must be evaluated with and without the optional guide to show
what the RAW-derived fixed stage can actually accomplish.

## Local RAW 9 findings so far

The six permanent RAWs tested for decoder availability all support version 9.
Native crop inspection found sharper detail than RAW 8 in a waterfall frame
and less chroma noise at ISO 12,800. Both versions retained magenta/green
fringing and a camera geometry difference in the waterfall crop. Directly adding
the embedded smooth guide to uncalibrated RAW 9 was worse on that regression
than the prior fixed-model-plus-guide path. Reusing RAW 8 look coefficients on
RAW 9 was only a diagnostic; the input contract changed and requires a new fit.

The earlier 72/72 low-frequency color acceptance result cannot by itself
validate RAW-derived color. The smooth camera guide supplies low-frequency
color/tone from a JPEG inside the RAW, while the color score measures a
low-frequency difference to the camera HEIF. That run establishes operational
HEIF production and guide similarity on those 72 pairs; those pairs have now
influenced design and cannot be counted as untouched for RAW 9. The next
release gate needs fresh session-held-out pairs and independent fixed-look,
guide, high-frequency, geometry, highlight and native-crop measurements.

Before RAW 9 scoring, a fresh 64-pair candidate manifest was selected by a
fixed hash seed from dates absent from training, development selection and the
earlier 72-pair acceptance. Capture groups were split at filename time gaps
over 30 minutes, with up to five pairs per group. Every pair was explicitly
materialized, then independently verified to be the same the initial test camera capture
and specified the target vivid look/DRO-off HEIF. All 64 verified. The frozen private
manifest SHA-256 is `1cbf2887fed8345b39dfa2bf3a952108736652aa1613ae40ac5377ba8ad50b79`;
the saved RAW 9 model SHA-256 is
`f2f4326c2a687b55e4b438e1e5f41cc913250225b5803a312091cb1a457c865c`.
This set has 15 time-separated groups across eight dates, ISO 100–12800,
focal lengths 10–50 mm, 59 Sigma 18–50mm pairs and five Sigma 10–18mm pairs.
It cannot certify the 16mm or 23mm lens strata or unrelated cameras/looks.

## Frozen RAW 9 result

The final saved RAW 9 model and renderer produced 64/64 full-resolution guided
HEIFs and 64/64 fixed-look HEIFs with zero file failures. The guide-on and
guide-off modes were both specified before the frozen set was opened. The
actual decoded HEIFs, not an in-memory substitute, were scored. One inspected
output reports 6192 × 4128 pixels in Image I/O, 10-bit HEVC tiles, BT.709
primaries and sRGB transfer, with capture/lens/exposure metadata retained.
`ffprobe` exposes the HEIF's tiles as smaller streams, so a single stream's
dimensions are not the composed image dimensions.

| Frozen result | Guided | Fixed look without guide |
| --- | ---: | ---: |
| Broad-color gates (mean ΔE00 ≤ 2, p95 ≤ 5 on every image) | 63/64 | 42/64 |
| Average image mean low-frequency ΔE00 | 0.809 | 1.684 |
| Worst image p95 low-frequency ΔE00 | 5.115 | 7.570 |
| 10–18mm pairs passing | 5/5 | 1/5 |
| ISO ≥ 6400 pairs passing | 7/7 | 0/7 |

The sole guided gate miss is a foliage/boardwalk frame: mean 1.544 and p95
5.115. Its native geometry comparison has 34/35 reliable matches and p95
residual 22.282 pixels; a native corner also shows purple/green branch
fringing relative to camera. This supports a lens/geometry contribution to the
score but does not mathematically apportion the color error. Across all 64,
40 frames had sufficient native geometry coverage. Their median p95 residual
is 6.747 pixels and maximum 25.963; all five 10–18mm frames had coverage and
median p95 25.624 pixels. These are separately reported lens limits, not
silently folded into the camera-wide look.

The guided render's mean measured render time was 4.117 seconds per image,
p95 4.621 seconds and maximum 4.988 seconds on this machine, excluding scoring.
This is not a peak-memory or cancellation measurement. In three selected native
corner crops, the mean absolute change in a three-pixel high-pass component
between fixed and guided outputs was 0.391–0.549 on an 8-bit channel scale,
versus fixed-output high-pass energy 2.194–6.689. The guide leaves most of that
measured fine structure from RAW development in these crops, while still
altering some fine edges; this is not a full detail certification.

The fixed RAW-derived look remains below the predeclared every-image color
gate. The smooth guide supplies much of the missing per-image broad rendering.
Do not claim an independently accurate RAW-only camera look, universal lens
fidelity or complete Plan 0105 acceptance from this result. The next
development pass must test an earlier linear/extended-range color boundary,
separate color calibration from tone, and determine whether RAW/metadata-only
adaptation can close the fixed-look gap without learning lens-specific geometry
in the camera-wide model. The known waterfall regression remains above its
guided p95 target as well.
