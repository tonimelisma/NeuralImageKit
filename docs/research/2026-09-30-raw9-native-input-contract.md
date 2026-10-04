# RAW 9 native input contract investigation

> Research evidence from the stated date. Earlier experiment choices are superseded by the active neural-development plan; results are not acceptance of the current pipeline.
Date: September 30, 2026. Standalone the initial test camera / VV2 work for
[plan 0105](../plans/0001-vivid-neural-development.md). This investigation
reopens the calibration input boundary. The saved encoded-sRGB reference remains
the default; the candidates described here are private experiments.

## Sources and scope

Apple's [ProRAW processing presentation](https://developer.apple.com/videos/play/wwdc2021/10160/)
shows how to obtain linear output by disabling gamut mapping and setting exposure,
baseline exposure, boost and local tone mapping to zero. It also shows rendering
into a floating-point linear colour space. This motivates an experiment; ProRAW
behaviour is not automatically camera Bayer RAW behaviour. The camera measurements
below use fresh RAW 9 filters. Native white balance and baseline exposure remain
preserved in the tested candidate.

The current Xcode 27 `CIRAWFilter.h` documents gamut mapping, shadow bias,
extended dynamic range and per-control support queries. Apple's
[`linearSpaceFilter`](https://developer.apple.com/documentation/coreimage/cirawfilter/linearspacefilter)
documents a linear processing point, without specifying its RGB primaries.

## Reduced decoding differs from native decoding

The reproducible reference calibration uses reduced RAW decoding at approximately
768 pixels on the long edge. Actual HEIF rendering develops the native resolution.
These are different inputs, even with the same decoder and four zeroed look
controls. A fresh filter was used for each decode and its output forced into the
same floating-point encoded-sRGB frame used by export. The native frame was then
resized in linear light using a numerical separable Lanczos-3 reference, with
normalized weights and edge extension. No target HEIF participates in this
comparison. The score compares reduced and resized-native RAW inputs, with the
unchanged low-frequency Gaussian sigma 1.2.

| Regression scene | Mean low-frequency DE00 | p95 low-frequency DE00 |
| --- | ---: | ---: |
| Pool | 0.321 | 0.837 |
| Green indoor | 0.373 | 1.122 |
| Warm portrait | 0.419 | 0.955 |
| Waterfall | 1.202 | 3.940 |
| High ISO | 0.735 | 1.659 |
| Sunset | 0.305 | 0.563 |

All six have valid fraction 1.0. These values measure input disagreement, not
camera-match accuracy. They justify regenerating calibration from full-resolution
input before judging a more elaborate predictor. They do not prove that the
regenerated model will improve photographic acceptance.

### Alpha and lazy evaluation controls

An initial Core Image bitmap resizing experiment produced alpha outside the
opaque range and was rejected. Its colour scores are not evidence. The native
frames themselves have finite components and opaque alpha (approximately
0.9995–1.0). The independent numerical reference unpremultiplies these opaque
samples before resizing and explicitly emits alpha one. A second native
experiment explicitly removes premultiplication and sets alpha one before the
linear resize. Calibration candidates must state their alpha convention and force
the native decode before reducing; a lazy filter graph is not proof that native
pixels were used.

## Native linear output versus an untagged tap

The captured `linearSpaceFilter` input has no `CIImage.colorSpace` tag. Requesting
an extended-linear-sRGB render context does not independently establish its input
primaries. The earlier tap preserves useful numerical highlight range, but its
colour interpretation is unverified. It must not be described as sensor RGB or
as a proven colour-managed scene representation.

The final RAW output is tagged Display P3. The new experiment instead disables
native gamut mapping and uses the tagged output, converts it explicitly to
extended linear BT.2020, then forces a full-resolution floating-point frame.
Native lens correction remains enabled and separate from the look. No learned
lens/focal correction enters the colour model.

With native gamut mapping enabled, the pool example's maximum linear component
is approximately 1.22. Disabling it increases the maximum to approximately 6.11.
The waterfall increases from approximately 1.16 to 3.59. Changing baseline exposure
from 0.4 to zero scales this range; the candidate preserves the native value.
Setting shadow bias to zero changes dark pixels and reduces some negative
components, but is not yet an accepted improvement. Extended dynamic range 2
produces the same result as zero in the tested gamut-disabled recipe.

## Candidate experiments

Twenty-four existing development pairs were exported through the native-size,
gamut-disabled, zero-shadow-bias recipe. A target-assisted per-image monotone
channel-curve plus 5-cubed residual diagnostic passes 18/24 spatial-held-out gates;
a matrix plus luminance curve and residual passes 13/24. These are diagnostics,
not deployable models, and neither improves on the earlier 20/24 result. Preserving
range alone does not close the photographic gap.

Both deployable comparisons completed. The shared luminance tone plus
wide-indexed residual fails all 24 development score gates; the actual pool HEIF
confirms mean DE00 3.979 / p95 9.744. Its CPU/Metal maximum error across 1,728
signed/highlight vectors is 6.574e-7, so numerical conformance does not imply
photographic quality. The existing encoded-sRGB family refitted from native-size
input passes 2/6 regressions and 16/18 selection cases (regression mean 2.163,
worst p95 7.817). A RAW-only scale adjustment passes 2/6 and 15/18 instead.
Neither candidate is promoted. Training-set and sampling changes confound
attribution of the native refit gains. The gamut-disabled candidate also changes
shadow bias; the next input experiment must change gamut mapping alone.
No scoring mask or supported difficult scene has been removed.

Private inputs and outputs stay outside Git. Every original read retains its
immediately preceding materialization guard; these experiments use previously
verified local pairs and never write into media folders.
