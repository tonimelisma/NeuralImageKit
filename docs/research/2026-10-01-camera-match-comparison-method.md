# Comparison method for RAW-to-camera-HEIF matching

> Research evidence from the stated date. Earlier experiment choices are superseded by the active neural-development plan; results are not acceptance of the current pipeline.
Date: 2026-10-01. This pass responds to the user's request to research the actual
comparison method, including the use of medians. It informs Plan 0105 measurement
work; it does not certify a recipe or substitute a new gate for a failing one.

## Conclusion

Use corresponding-location colour differences with spatial error maps, explicit
viewing/colour contracts, separate detail/geometry diagnostics and matched A/B
review. No single scalar establishes that the camera rendering was reproduced.
Keep median signed colour components for diagnosis. Comparing independently pooled
median colours is not a sufficient matching measure.

## Primary sources

- [CIE 199:2011 public summary](https://www.cie.co.at/publications/methods-evaluating-colour-differences-images)
  concerns similar images under similar output media/viewing conditions, describes
  statistical analysis of average colour differences, and recommends CIELAB or
  CIEDE2000. The full paid report was not accessed; no pooling formula or universal
  release threshold is attributed to it here.
- [ISO/CIE 11664-6:2022 public summary](https://www.cie.co.at/publications/colorimetry-part-6-ciede2000-colour-difference-formula-1)
  defines the colour-difference formula. It is not an image-quality or arbitrary
  photograph acceptability threshold. Published implementation reference cases
  remain the numerical oracle for our DE00 implementation.
- [Zhang/Wandell S-CIELAB](https://sid.onlinelibrary.wiley.com/doi/10.1889/1.1985127)
  extends colour comparison to spatially patterned images. The
  [author's presentation](https://stanford.edu/~wandell/data/papers/CIC-10-Wandell.pdf)
  explicitly places spatial filtering in linear opponent coordinates before Lab.
  Our fixed Gaussian blur of encoded RGB is a broad-colour engineering diagnostic;
  it is neither S-CIELAB nor a calibrated human-vision model.
- [FLIP author page](https://research.nvidia.com/publication/flip) describes spatial
  error maps for alternating-reference viewing and reports a user study. Its
  authors explicitly correct their original weighted-median recommendation in
  favour of a mean summary. [Author code](https://github.com/NVlabs/flip) supplies
  LDR and HDR implementations and a BSD-3-Clause licence. Our SDR targets call for
  LDR evaluation. Viewing scale/pixels per visual degree are part of the contract;
  paper defaults cannot be called the user's actual viewing conditions.
- [SSIM author implementation/usage](https://ece.uwaterloo.ca/~z70wang/research/ssim/)
  emphasizes evaluation scale and viewing distance. The posted benchmark converts
  colour images to grayscale. Structural similarity alone cannot establish a vivid
  colour match; image size/scale and implementation must be fixed when comparing it.
- [DISTS paper](https://arxiv.org/abs/2004.07728) deliberately tolerates texture
  resampling and small geometric transformations, combining learned structure and
  texture statistics. This makes it a candidate supplementary texture diagnostic,
  not a replacement for strict local colour or geometry evaluation. Its learned
  weights/dependencies and different tolerance objectives do not justify adding
  it to the native runtime now.
- [RAW-to-sRGB alignment paper](https://arxiv.org/abs/2108.08119) documents shifted
  and blurred outcomes from misaligned supervision. Its multicamera task differs
  from our same-camera capture pairs, but the failure mechanism supports auditing
  correspondence separately from colour and training loss.

## Three distinct statistics

1. Difference between the median Lab coordinates of two regions: each image is
   pooled independently, discarding spatial arrangement before comparison.
   Opposite local errors or swapped colour areas can therefore appear to match.
2. Median of corresponding per-pixel DE00 errors: preserves correspondence, but
   can hide errors covering less than half the region. Useful as a robust summary,
   insufficient on its own for matching acceptance.
3. Mean of corresponding per-pixel DE00 errors: keeps every valid location's
   nonnegative error. It cannot cancel opposing signed casts, but dilution by large
   accurate areas remains possible. Pair it with tails, spatial maps, fixed regions
   and valid/excluded coverage. A whole-image mean cannot certify a small face.

Median signed lightness/chroma components remain useful for explaining the direction
of a mismatch. They answer a different question from how closely all pixels match.

## Recommended layered comparison

| Layer | Measurement | Purpose and limitation |
| --- | --- | --- |
| Decode/display contract | Actual final HEIF; native dimensions/orientation; explicit common sRGB/D65 handling; fixed crop/resample | Prevent encoding/profile/coordinate mistakes; do not normalize away exposure, WB or colour differences |
| Geometry | Candidate-independent RAW baseline, constrained correspondences and coverage; unregistered output separately | Isolate colour without hiding lens defects; unknown correspondence cannot certify accuracy |
| Broad colour/tone | Corresponding-pixel DE00 mean/p95, maps and signed components at fixed low-frequency scale | Quantify the rendering; current 768/sigma-1.2 encoded-space score remains versioned historical evidence |
| Local failures | The same pixelwise errors over frozen face/material/highlight/shadow regions; spatial tails/coverage | Stop a large accurate background from hiding a local mismatch; avoid selection based on a candidate's success |
| Perceived total difference | Candidate LDR-FLIP maps/mean under declared fit-view and native-crop conditions | Supplement colour with visible edges/features; no unvalidated universal FLIP pass threshold |
| Native detail | Identical native crops, edge spread/halo/noise statistics, optional SSIM or texture metric | Separate excessive smoothing, sharpening and noise; do not demand the same random noise realization |
| Review | Same zoom/crop/profile/background, side-by-side and alternating actual outputs | Check visible mismatch missed by pooled numbers; favourable subjective appearance alone cannot replace matching |
| Dataset aggregation | Equal-image and equal-shoot summaries; every failure/worst case; lighting/ISO/lens strata | Bursts and large outdoor regions cannot dominate; retain per-image absolute gates |

Lenses remain separate. Evaluation alignment is offline measurement and must never
silently become a target-guided runtime lens correction. Do not match histograms,
exposure or WB as part of scoring: those are differences the algorithm must solve.

## Calibration before adoption

Use frozen existing development images, not the final untouched reserve, for a
predeclared measurement audit. Include target self-comparison, round-trip colour
conversion, known subpixel/native shifts, clipping, opposing local colour errors,
small global exposure/saturation shifts, local skin casts, blur/halo and noise.
Report responses and maps at whole-view and native-crop scales. Include both aligned
and unaligned variants to separate geometry sensitivity from colour sensitivity.

An evaluator must return zero (within explicit numerical precision) for an identical
image, find local colour errors that cancel under median pooling, flag broad cast
and unwanted detail changes, and reveal its sensitivity to known shifts. Human
visual assessment and general perceptual validity are not proven by these fixtures.

Before changing the low-frequency colour preparation, compare the old encoded-RGB
blur against linear-light/spatial alternatives. Fix target interpretation and
filter/resampling ordering. Preserve the old score rather than calling changed
values improved pipeline accuracy. Full S-CIELAB requires its actual opponent
filters and viewing scale; ordinary linear-RGB Gaussian blur is not S-CIELAB either.

If FLIP is tested, pin source/version, verify its input conventions and identity,
record viewing conditions, licence/dependency scope and limitations. No third-party
runtime or training dependency was added in this research pass. A required ADR must
precede a new dependency. FLIP, DISTS and alternate blur preparation are researched
candidates, not implemented/adopted quality gates.

## Current implementation audit and measured evidence

The current whole-image score computes pixelwise mean/p95 DE00 after the fixed
blur, but compares unregistered image coordinates. It reports native geometry
separately; that does not automatically establish reliable corresponding pixels
throughout the colour score. Regions use a fixed RAW-derived geometry baseline and
explicit native correspondence, but their earlier acceptance used the difference
between median Lab colours.

Measurement report 7 now additionally reports pixelwise mean/p95 region DE00,
unregistered mean, mean-error correspondence sensitivity and explicitly named
matching outcomes. Median diagnostics remain distinct. An adversarial swapped-red/
blue arrangement measures median-colour DE00 approximately 0.0000069 while mean
pixel DE00 is 45.44. The new matching gate correctly rejects it.

On the current recipe's actual warm-lit face HEIF, mean region DE00 is 2.429,
exceeding the original 2.0 gate. An existing whole-region fitted expression
experiment reaches 1.652 there. That is evidence the global stage can express a
closer match on fitted data, not proof of automatic prediction or generalization.
The earlier median diagnostics cannot certify original matching acceptance.

Keep existing threshold failures visible. Current 2.0/5.0 limits are frozen project
engineering requirements, not researched universal invisibility boundaries.
Revisions require demonstrated measurement defects and fresh acceptance; we do
not revise limits just because the current candidate fails.

Private audit evidence: `<local experiment output>`,
`original-hard-regions/summary.json`, `warm-dense-expression.json` and standalone
build fixture log `paired-v2-build.log`. No original was written or new rendering
coefficient selected by this research. The next work is the declared measurement
calibration and correspondence audit before further candidate selection.

## Executed calibration and baseline audit

The native `comparison-calibrate` command now enforces selection/regression roles,
reads guarded target bytes, preserves orientation and rejects output in the source
media directory. An acceptance-role invocation was rejected without an output.
On three already-used camera targets at whole-view and native-crop scales (six
views), identity and the true sRGB round-trip each measured zero. Correctly supplied
one/two-pixel correspondences recovered zero local colour error. Fractional-shift
response retains interpolation effects rather than promising exact recovery.

The reference used to inject defects is display-clamped encoded sRGB. An earlier
audit conflated round-trip with clamping; the unblurred score was zero while the
blurred score was nonzero. Separating those operations exposed extended-range
values in both resized and native decoded targets. Their cause is not assigned to
resampling alone. The target inspected through independent metadata reports sRGB
and 10-bit HEIF. Historical clamping response is retained separately; this audit
changes no renderer coefficient or historical acceptance threshold.

With the isolated perturbations, a +0.04 encoded red change in the central third
produced whole-image mean DE00 0.252–0.440 but affected-region mean 2.163–3.727.
The intended localized error is therefore diluted by whole-image pooling. Gaussian
sigma-1 blur produced low-frequency mean 0.101–0.754 across these views, well below
the colour gate; native-detail evidence must remain separate. These are measurement
responses on particular images, not claimed visibility thresholds.

The frozen baseline exported all 204 development pairs without an export failure;
77 fail historical unregistered mean/p95 limits. Native geometry reports sufficient
coverage on 146, which does not certify pixelwise correspondence for the whole
colour frame. All 283 planned training exports completed without failure.

A fixed 5-by-4 grid on the seven original failures used existing RAW-derived geometry
HEIFs independent of candidate colour. It retained 16–20 low-sensitivity regions per
image, and found 2–16 colour failures in those regions. For example, May 31's
reliable-grid weighted mean changed from 2.661 unregistered to 2.494 aligned and
still fails; July 4 changed from 1.990 to 1.645 while five grid regions still fail.
These grid aggregates are diagnostics, not replacements for original whole-image
or frozen hard-region gates. Uncertain tiles remain reported. This separates genuine
colour residuals from cases whose historical whole-image score includes geometry.

NVIDIA FLIP 1.7 was built from revision
`b475eb4bf394ab877c42166c9eb0a84a02cc5b14` under the offline-only decision in
ADR 0031 (superseded experiment record). The tool includes
BSD-3-Clause FLIP/tinyexr and MIT stb_image. Declared 30/60-PPD sensitivity conditions
are not measured user viewing conditions. The final audit completed 168 LDR-FLIP comparisons across six views, 14
perturbations and two conditions. Identity and round-trip were zero at both
conditions; maps localized the injected cast and responded to blur, halos, noise
and shifts. Earlier confounded maps remain separate evidence. No scalar FLIP
threshold is accepted, and 8-bit preview evaluation cannot certify native 10-bit
colour accuracy.

Private final calibration: `paired-corpus-v2/comparison-calibration-final/`;
RAW-derived grid: `paired-corpus-v2/capacity/grid-baseline/`; broad baseline:
`paired-corpus-v2/baseline-development/`; standalone build:
`comparison-calibration-final-build.log`. The next bounded expression diagnostic
compares existing global colour-field fits in encoded RGB and normalized Lab on
seven failures. All their fitting pixels are expression evidence only; they cannot
establish an automatic selector or independent validation.
