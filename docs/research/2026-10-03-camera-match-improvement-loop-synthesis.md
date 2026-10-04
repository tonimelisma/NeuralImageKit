# Camera matching: pipeline and improvement-loop synthesis

> Research evidence from the stated date. Earlier experiment choices are superseded by the active neural-development plan; results are not acceptance of the current pipeline.
Date: October 3, 2026. Research and recommendations for active Plan 0105.
This document proposes execution refinements; it does not declare photographic
acceptance, a newly adopted model or completion of the pending source increment.

## Scope and research method

The objective remains the initial test camera sensor RAW9 to native 10-bit SDR sRGB HEIF
matching the user's separate verified VV2 HEIFs. Embedded camera images are
excluded from development, fitting, evaluation and inference. Runtime has only
sensor RAW, permissible capture metadata and frozen model parameters. Apple lens
correction has separate ownership; custom profiles remain deferred. No app
integration or new dependency is introduced by this research.

Read primary papers, author repositories and official documentation. The accessible
HTML of ParamISP, HDRNet and Modular Neural ISP was inspected, including relevant
methods and supplementary sections. The adaptive-LUT paired training code was
inspected. Alignment and ChameleonTuner conclusions below use their accessible
abstracts/author descriptions where full papers were unavailable. CIE evidence uses
its public report description, not the paid report. These are different evidence
levels. Published results do not establish performance on our camera and VV2 data.

## Relevant implementations and what transfers

| Source | Observed approach | Implication for this project |
| --- | --- | --- |
| [ParamISP, CVPR 2024](https://arxiv.org/html/2312.13313v2) | Canonical RAW preparation; global and local networks; image context plus capture parameters; forward loss on rendered sRGB. | RAW context is a justified conditioning hypothesis. The paper does not prove metadata insufficiency or a need for local processing in our remaining cases. |
| [HDRNet, SIGGRAPH 2017](https://arxiv.org/html/1707.02880v1) | Predict transforms from a small image; apply an edge-aware transform at output resolution; train against the output. | Reduced guidance is compatible with native output. It is different from applying a nonlinear look to averaged RGB and treating that as the native result. |
| [Image-Adaptive-3DLUT, author implementation](https://github.com/HuiZeng/Image-Adaptive-3DLUT) and [paired training code](https://raw.githubusercontent.com/HuiZeng/Image-Adaptive-3DLUT/master/image_adaptive_lut_train_paired.py) | Image-conditioned basis LUT combination; paired MSE with smoothness/monotonicity regularization. | A compact adaptive global model is credible. MSE is not intrinsically invalid; our approximation and validation need measurement. Generic retouch models are not a ready the target vivid look recipe. |
| [Modular Neural ISP, December 2025 preprint](https://arxiv.org/html/2512.08564v1) | Separate denoising, photofinishing and detail; gain/global tone/local tone/chroma/gamma interact within jointly trained photofinishing. Uses several losses and component ablations. | Stage ownership should support inspection without requiring independent fits. Its picture-style task is particularly relevant, but its reported preferences do not certify exact camera matching. |
| [RAW-to-sRGB with inaccurate alignment, ICCV 2021](https://arxiv.org/abs/2108.08119), [ISP in the Wild, ECCV 2022 author page](https://martin-danelljan.github.io/publication/trisp/) | Address correspondence problems in weakly paired training. | Alignment errors can become blur or false colour failures. Preserve independent correspondence confidence; do not normalize away the camera colour differences we intend to learn. |
| [ChameleonTuner, WACV 2026 abstract](https://openaccess.thecvf.com/content/WACV2026/html/Tan_ChameleonTuner_Automatic_ISP_Color_Tuning_in_Subjective_Scenarios_WACV_2026_paper.html) | Region correspondence and interpretable colour tuning for subjective scenarios. | Useful related problem; target-assisted tuning is not a deployable RAW-only selector. Its [repository](https://github.com/ZjTan4/ChameleonTuner) currently contains a release announcement rather than implementation code. |
| [RawTherapee pipeline](https://rawpedia.pixls.us/toolchain_pipeline/), [darktable 4.6 module order](https://docs.darktable.org/usermanual/4.6/en/darkroom/pixelpipe/the-pixelpipe-and-module-order/) | Explicit processing order and colour-space boundaries, with distinct optical and image adjustments. | Document and inspect boundaries. These references do not justify replacing our decoder or rewriting a working baseline solely to resemble another editor. |

## Verified project state

The current plan and implementation were inspected, not inferred from previous
reports. Runtime source is `NativeRAWDevelopment.swift`; conditional fitting is
`ConditionalProfile.swift`; export preparation is `LookCalibration.swift`; native
application is `SensorRAWHEIFRenderer.swift`; emitted-HEIF evaluation and colour
scoring are `SensorRAWHEIFEvaluation.swift` and `Scorecard.swift`.

- Runtime uses RAW decoder9, scale1, non-draft development and explicit colour
  boundaries. Supported Apple lens corrections are separately reported.
- Static curves plus9-cube residual LUT pass173 of204 development images.
- Best shared WB/ISO candidate passes186 of204: thirteen failures resolved, zero
  new whole-image failures, but eighty higher means. These are development results,
  with unresolved hard regions and optical/detail effects; not final acceptance.
- There are463 verified training captures across36 assigned dates. Dates are not
  certified independent shoots. Development has204 captures across21 dates.
- Tint, weighting and finer-field variants did not clear the fixed screen or lost
  controls. They are rejected, not promoted or extended into open-ended sweeps.
- Recent coverage and solver repairs made experiments more trustworthy. The native
  cyan expression experiment passes its original cyan/face/white regions and whole
  image, but still has one reliable grid colour failure plus uncertain/sensitive
  regions. This is a target-assisted witness, not automatic inference or proof of
  global capacity for every failure class.
- The matched100-capture full-native preparation pilot still passes five of nine,
  with no resolved failure or lost pass. Seven means improve, two worsen. Keep the
  consistent source contract; reject the pilot model as photographic progress.
- That source implementation is unmerged and lacks final full local verification.
  Its standalone checks are not a substitute for the required final-tree check.
- The reserve has seven provisional groups across six dates, below ten independently
  checked shoots. Metadata verification is not an independence/coverage certificate.

Private evidence lives under the ignored primary checkout's
`data/paired-corpus/`: `control/conditional-broad-final-summary.json`,
`control/native-input-control-screen-results.json`,
`control/native-input-screen-results.json`, and their actual emitted HEIFs.
See source pilot and code audit (superseded experiment record)
and native expression evidence (superseded experiment record).

## Main unresolved diagnosis

The shared fitter evaluates a nonlinear base look on averaged source RGB points
and solves a regularized squared encoded-RGB residual. Native rendering applies
that look to individual full-resolution pixels before HEIF encoding. Evaluation
then decodes the actual HEIF and computes perceptual colour differences after
reduction and a separately defined blur. Training uses Core Image blur radius;
scoring uses an explicit Gaussian sigma. These are verified differences. We have
not established their contribution to the remaining errors.

The successful cyan witness changed both objective and prior treatment. It cannot
isolate which change mattered or prove that another metadata predictor is the
necessary next solution. The native-source pilot rules out that preparation change
alone as a sufficient fix on its screen; it does not prove every other approximation
harmless. Do not promote a causal conclusion from an association.

## Recommended pipeline ownership

Retain the native foundation and existing frozen baseline. Keep explicit owners for:

1. Sensor preparation and technical colour normalization under the RAW9 contract.
2. Lens/geometry with independent support and residual diagnostics.
3. Global brightness/tone, including highlights and output range.
4. Global colour/chroma, including hue-specific vividness and skin behaviour.
5. RAW-only selection of global parameters, using justified metadata/image context.
6. Local tone/colour only if reliably spatial residuals survive adequate global fits.
7. Noise/detail/sharpening, evaluated at native scale.
8. Output gamut, transfer and native HEIF encoding.

This is an ownership map, not an instruction to reorder existing operations or
add every stage. Coupled tone/colour parameters may be fitted jointly. Save stage
checkpoints for diagnosis. Do not let a local stage or LUT learn lens defects.

## Evaluation contract

[CIE's public description](https://www.cie.co.at/publications/methods-evaluating-colour-differences-images)
supports image colour comparison under common viewing conditions, using CIELAB or
CIEDE2000. [FLIP's authors](https://research.nvidia.com/publication/flip) recommend
mean over their original weighted median and provide visible-error maps.
[SSIM guidance](https://ece.uwaterloo.ca/~z70wang/research/ssim/) explicitly considers
viewing scale and includes grayscale evaluations. None provides a universal scalar
that certifies our look.

Use complementary evidence:

- Format: actual emitted HEIF dimensions, orientation, bit depth, primaries,
  transfer and HDR facts. An8-bit preview cannot establish10-bit fidelity.
- Colour/tone: per-pixel low-frequency DE00 mean andp95, unblurred results, signed
  brightness/hue/chroma diagnostics, clipping and error maps. Retain current limits:
  per-image mean<=2/p95<=5; every frozen region mean<=2.
- Correspondence: original unregistered images plus reliably corresponding-area
  results, with independent masks, valid fraction and uncertain coverage reported.
  Never remove a location because the candidate has high colour error there.
- Important areas: fixed face, white, cyan, green and other difficult regions.
  Whole-image means can hide a small wrong face. Median colours of separately pooled
  patches do not establish pixel correspondence or pixelwise matching.
- Detail: native edges/halos, repeated textures, fringes and flat-region noise
  distributions. Matching individual random noise realizations is not required.
- Perception: existing offline LDR-FLIP as a diagnostic under declared viewing
  scale; controlled side-by-side/alternating inspection at fit-to-view and100%.
  Preference for a pleasing photo is a different question from likeness to camera.
- Groups: per-photo failures, worst cases and lighting/ISO/lens/shoot coverage.
  Compute uncertainty across independent shoots rather than treating pixels/bursts
  as independent observations. Keep capture weighting and shoot weighting distinct.

Training groups fit parameters; internal group-held-out validation selects fitting
choices; repeatedly examined development data diagnose/select experiments. Only
unused, independently verified reserve groups establish final generalization.
Reserve failures must remain recorded; once used to tune, that material becomes
validation/development and cannot remain an untouched final test.

## Improvement loop and decision points

Each cycle starts with a concrete failed image/region and a visible error description.
Write a contract before fitting: one hypothesis, fixed stages/input/features,
training and checking groups, at most two variants, computation budget, expected
residual change and unchanged acceptance/regression rules.

| Step | Evidence required | Decision |
| --- | --- | --- |
| Establish failure | Repeated actual HEIF, colour/detail map, trustworthy correspondence | If measurement is invalid, repair measurement before learning |
| Test numerical behaviour | Coverage, bounds, convergence/gradient checks, objective vs actual native outcome | Solver failure or budget exhaustion is not model incapacity |
| Test expression per failure class | Diagnostic per-image fit using the same runtime family | Success permits shared prediction work; failure needs a bounded representation/input investigation |
| Learn shared inference | Training-only parameters; RAW-only inputs; group-held-out validation | A target-assisted success does not count as a deployed success |
| Fixed nine-image screen | Named failure/region resolved, old passes preserved, hard-region regressions reported | Reject unsuccessful variants; no larger run or blind capacity sweep |
| Broader204 development run | Actual native outputs, all failures, grouped/worst-case/detail deltas | Promote only a justified candidate; lower average alone is insufficient |
| Frozen acceptance | >=50 unused pairs, >=10 verified independent shoots, unchanged colour/detail/operation gates | Accept or record failure and reopen the diagnosed stage |

Every report ends with adopt/reject/inconclusive and exactly what the result permits
next. Include a visual before/after and resolved/introduced failure counts. Numerical
infrastructure progress and photographic progress must be reported separately.

## Recommended execution order

1. Finish verification/integration of the already implemented native-source contract.
   Do not repeat463 exports merely because the100-capture pilot failed to fix colour.
2. On already-used controls, audit whether the current fitting objective correctly
   ranks changes to actual native HEIF colour/region outcomes. Isolate operation order,
   blur and loss/prior effects rather than changing them all at once. Keep capacity fixed.
3. Obtain native expression evidence for green/foliage and other unresolved classes;
   do not extrapolate the cyan witness. For classes with successful global fits,
   evaluate shared prediction using the validated fitting procedure.
4. Test a compact RAW-image-context predictor against the metadata baseline while
   retaining the same bounded correction field. Start with declared exposure/colour/
   clipping/gradient summaries. A learned thumbnail-to-basis-LUT model is an alternative
   if the simple predictor fails and observed residuals justify it; not a default rewrite.
5. Add edge-aware local processing only when reliable spatial failures survive global
   expression tests. Develop detail/noise fixes only from native-scale defects.
6. Run broad development and freeze the complete candidate, then consume a sufficiently
   independent reserve. Continue reserve independence/coverage work without using its
   pixels to select the model.

The plan's objective, stages and acceptance gates remain appropriate. Its immediate
execution should put objective validation before another predictor and stop describing
one cyan witness as a general shared-learning diagnosis. No research result guarantees
exact camera matching; completion depends on our own paired evidence.
