# Ready macOS imaging capabilities and the camera vivid learning boundary

> Research evidence from the stated date. Earlier experiment choices are superseded by the active neural-development plan; results are not acceptance of the current pipeline.
Date: October 3, 2026.

## Question and scope

The user requests a fresh assessment of ready software across the entire RAW-to-
HEIF pipeline. RAW decoder 9 and lens correction were examples, not an exhaustive
list of stages to retain. Prefer supplied, validated operations wherever possible;
learn camera vivid rendering decisions from separate RAW/HEIF training pairs.
Missing technical calibration, especially lens profiles, remains a separate gap.
No RAW, lens, local or learned renderer was implemented or modified in this review.
Previous failed experiments do not eliminate entire model families.

## Evidence boundary

Reviewed current Apple documentation and WWDC26, Lensfun primary documentation,
and the configured Xcode 27 macOS 27 SDK headers: CIRAWFilter.h,
CIFilterBuiltins.h and CIContext.h. Header inspection confirms exposed controls,
not that each control is effective on every camera file. No new image-byte reads or
runtime support tests were performed. Do not present this API inventory as a
photographic comparison or proof of camera-equivalent processing.

## Available operations

| Task | Ready capability | What remains specific to this project |
| --- | --- | --- |
| Sensor development | CIRAWFilter, including RAW9 joint demosaic/denoise | Confirm camera/decoder support and freeze the development recipe; do not train a replacement |
| White balance and exposure | RAW neutral temperature/tint/chromaticity, exposure/baseline controls; Core Image exposure and temperature/tint filters | Determine whether additional adjustments are needed to match camera |
| Highlight recovery | RAW support/enabled controls | Check support on each input; distinguish recovery from cosmetic highlight compression |
| Tone and contrast | RAW boost/shadow/local controls, CIToneCurve, CIColorCurves, CIColorControls, CIHighlightShadowAdjust | Fit or learn settings and operation order; controls are not a camera preset |
| Selective colour | CIColorMatrix, CIColorPolynomial, CIColorCrossPolynomial, CIVibrance, CIColorCubeWithColorSpace | Learn matrices, curves or table values; root-polynomial is not identical to the ordinary polynomial filters |
| Local adjustment | Masked blending and CIColorCubesMixedWithMask; shadow/highlight filtering | Learn whether spatial decisions are needed and what adjustments should apply |
| Subject location | Vision face detection and foreground/person masks | These locate content; they do not supply camera rendering decisions |
| Noise and detail | RAW luminance denoise, sharpness/local contrast; post-development noise/sharpen filters | Compare supported settings with target detail; avoid assuming Apple defaults match camera |
| Lens corrections | RAW lens support/enabled controls | Exact lens support and residual quality; no custom profile import exposed by CIRAWFilter.h |
| Colour management | Core Image working/output colour spaces, Core Graphics colour spaces and floating-point working formats | Choose and consistently use input/working/output interpretation |
| Output | CIContext HEIF and explicit HEIF10 export | Verify resulting precision, colour metadata and decoded file; SDR/HDR depends on colour interpretation |
| Offline pair alignment | Vision translation and homographic registration | Registration confidence/movement/optical residuals still need assessment; registration is not a lens profile |
| Learned-model execution | Core ML and Metal/Core Image custom kernels | Train or obtain a suitable model; execution frameworks are not pretrained camera vivid renderers |

Apple provides automatic enhancement via autoAdjustmentFilters. It analyses the
image and returns configured photographic filters. This is a ready comparison
candidate, not evidence of camera matching or an API promising to reproduce Photos'
entire editing pipeline.

## Decoder and support details

WWDC26 describes RAW9 as an Apple-trained tiled Core ML model combining demosaic
and denoise, running on the Neural Engine. Using a supplied trained model fits the
user's ready-software principle; the distinction is whether we must invent/train
technical processing ourselves. Apple explicitly documents opt-in to RAW9. The SDK
header describes default decoder selection differently; explicitly selecting and
checking version9 avoids depending on that ambiguity.

RAW9 automatically handles colour noise; Apple says colorNoiseReductionAmount has
no effect, and detailAmount/moireReductionAmount are unsupported. Other controls
have per-image support properties. Neither the presence of an API nor a property
name proves an effective independently configurable operation for all inputs.

The public linearSpaceFilter hook allows a custom filter while processing is
linear. It does not document complete internal ordering or guarantee untouched
sensor RGB. The API is a developed-image boundary, not an exposed replacement
sensor pipeline.

## Lens gap

Lensfun is ready code plus calibration data for distortion, lateral chromatic
aberration and vignetting. Coverage must be checked for the exact lens and
conditions. Its integration domain and interpolation requirements matter; applying
a complete profile after Apple's correction risks double correction. Availability
of Lensfun does not mean integration or camera-equivalent geometry has been proven.
Keep existing project custom-profile deferral until a validated ready option is
established. Do not train a vivid model to absorb geometric/vignetting errors.

## Mapping to the report's eleven approaches

1. Classical parametric rendering: many operations already native; fit their
   settings before deciding a new mathematical implementation is required.
2. Matrix plus curves: native application operations exist; fitting still required.
3. Polynomial/root-polynomial: ordinary polynomial filters exist; root-polynomial
   requires its particular formula or a validated table representation.
4. DCP/ICC: colour management exists; custom DCP camera-look interoperability is a
   separate requirement, not automatically supplied by CIRAWFilter.
5. Shaper plus fixed LUT: native curve/table operations can apply the representation;
   choose domains and learn data, verifying ordering/interpolation.
6. Conditional LUTs: native table application exists; condition-to-table selection
   or blending is project logic, with frozen settings or learned parameters.
7. Image-adaptive LUTs: native rendering and model execution exist; a camera-specific
   image-to-adjustment selector and training still required.
8. HDRNet/local affine: native masks/local filters are simpler candidates first;
   no public ready camera-trained HDRNet renderer was identified.
9. Neural RGB renderer: execution infrastructure exists, camera-trained model does not.
10. Full neural RAW ISP: outside the ready-technical-processing boundary.
11. Hybrid: use native processing and supplied operations, fitting/learning only
    the adjustments or transforms necessary for the target appearance.

## Consequences for a reset

Separate operation availability, per-input support, and photographic suitability.
A built-in operation may exist yet differ from camera; learned parameter selection
can use built-in operations without learning a replacement demosaicer or lens
model. Local residuals warrant checking native local operations, not automatically
escalating to a spatial neural network. Prefer one clearly specified, consistently
executed development boundary and test native built-in candidate combinations on
separate paired data. The report's model families remain alternatives; this review
selects no new model and claims no improved matching results.

For batch export Apple recommends cacheIntermediates=false and Core Image export
methods. Context memory controls govern Core Image tasks, not every allocation in
an experiment. Retain the independently verified process-level resource owner.

## Primary sources

- [Apple RAW9 processing and controls, WWDC26](https://developer.apple.com/videos/play/wwdc2026/305/)
- [CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter)
- [Core Image filter reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html)
- [Colour curves](https://developer.apple.com/documentation/coreimage/cicolorcurves)
- [Colour table with explicit space](https://developer.apple.com/documentation/coreimage/cicolorcubewithcolorspace)
- [Masked colour tables](https://developer.apple.com/documentation/coreimage/cicolorcubesmixedwithmask)
- [Automatic adjustments](https://developer.apple.com/documentation/coreimage/ciimage/autoadjustmentfilters(options:))
- [Apple auto-enhancement explanation](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_autoadjustment/ci_autoadjustmentSAVE.html)
- [Vision face detection](https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest)
- [Vision foreground masks](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest)
- [Working colour management](https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace)
- [HEIF10 export](https://developer.apple.com/documentation/coreimage/cicontext/writeheif10representation(of:to:colorspace:options:))
- [Core ML](https://developer.apple.com/documentation/coreml)
- [Custom Core Image kernels](https://developer.apple.com/documentation/coreimage/writing-custom-kernels)
- [Vision alignment](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest)
- [Lensfun](https://lensfun.github.io/manual/latest/)
