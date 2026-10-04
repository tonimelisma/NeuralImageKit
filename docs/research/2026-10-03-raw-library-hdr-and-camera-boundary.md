# RAW library: camera normalization and HDR boundary

> Research evidence from the stated date. Earlier experiment choices are superseded by the active neural-development plan; results are not acceptance of the current pipeline.
Date: October 3, 2026. Documentation research, not runtime validation.

Apple's RAW support parses sensor files, handles camera calibrations and develops
colour images through a common API. RAW9 combines demosaicing and denoising; the
supported-camera list is exposed per decoder and can change with system updates.
Thus a common working RGB representation can remove sensor-layout/file-format
concerns from the appearance model. Identical sensor spectral response, noise,
colour calibration accuracy or cross-camera appearance quality does not follow.
Validate transfer rather than treating each extension as a new rendering engine
or asserting that all decoded inputs are statistically identical.

Core Image provides EDR controls and extended working spaces. Apple's HDR guidance
distinguishes reference white/content headroom, deliberate creative rendition and
adaptation to available display headroom. Adaptive HDR can represent SDR and HDR
renditions using a gain map; ISO HDR supports HDR colour/transfer representations.
Encoding them does not decide which RAW highlights should be bright or how a
learned look should appear. A 10-bit SDR target does not supply missing HDR
appearance supervision. Preserve the working range and obtain appropriate HDR
training targets, then define HDR evaluation and SDR fallback checks separately.

API implication: development should return an explicitly interpreted image/result
for a look and rendering intent. File export is an adapter over that operation.
The library scope includes HDR and separately trained looks; current camera vivid
SDR acceptance is the first implementation milestone. No broad camera coverage,
HDR model, gain-map writer or generic image-return API is claimed implemented.

## Sources

- [Apple RAW9 processing and camera support](https://developer.apple.com/videos/play/wwdc2026/305/)
- [Core Image RAW EDR control](https://developer.apple.com/documentation/coreimage/cirawfilter/extendeddynamicrangeamount)
- [Apple HDR, headroom and dual renditions](https://developer.apple.com/videos/play/wwdc2024/10177/)
- [Core Image gain-map export](https://developer.apple.com/documentation/coreimage/ciimagerepresentationoption/hdrgainmapimage)
