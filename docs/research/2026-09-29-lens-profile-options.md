# Lens correction options for the standalone camera RAW renderer (2026-09-29)

> Research evidence from the stated date. Earlier experiment choices are superseded by the active neural-development plan; results are not acceptance of the current pipeline.
The user asked for existing lens-correction code and profiles, and directed us
to leave custom lens correction for now if no strong ready option fits. This is
a decision about the first standalone RAW-to-HEIF renderer, not a claim that
lens matching to camera is solved.

## Available options

- Apple's `CIRAWFilter` exposes `isLensCorrectionSupported` and
  `isLensCorrectionEnabled`. The enabled default varies by image. In our
  switch audit (superseded experiment record), the tested the initial test camera
  files supported correction and enabled it by default. Turning it off lost
  reliable camera correspondences. The enabled 18 mm result still had about
  24 native pixels of p95 edge displacement from camera's companion. Apple's
  correction is therefore a useful native baseline, not proof of camera-equivalent
  geometry. Sources:
  [support](https://developer.apple.com/documentation/coreimage/cirawfilter/islenscorrectionsupported),
  [enabled state](https://developer.apple.com/documentation/coreimage/cirawfilter/3801632-lenscorrectionenabled).
- [Lensfun](https://lensfun.github.io/manual/latest/) supplies correction code
  and an open XML lens database for distortion, lateral chromatic aberration,
  and vignetting. Its [current lens list](https://lensfun.github.io/lenslist/)
  has a crop-1.534 Sigma 18-50mm F2.8 DC DN Contemporary 021 entry and a
  crop-1.534 Sigma 16mm f/1.4 DC DN Contemporary entry, each with all three
  correction categories. The newly verified 10-18mm F2.8 DC DN Contemporary
  023 entry has distortion but no listed TCA or vignetting correction. The list
  has no Sigma 23mm F1.4 DC DN Contemporary 023 entry as checked September 29.
  Both lenses appear in our verified corpus. Lensfun's
  [modifier documentation](https://lensfun.github.io/manual/latest/structlfModifier.html)
  also says the caller supplies pixel interpolation. Its
  [architecture notes](https://lensfun.github.io/manual/latest/basearch.html)
  require TCA and vignetting correction early in linear sensor-space RGB;
  applying these profiles on Apple's already corrected output would have the
  wrong input domain and risks correcting twice. The
  [project license](https://github.com/lensfun/lensfun#license) is LGPL-3.0 for
  libraries and CC BY-SA 3.0 for database content, requiring a separate
  dependency/license decision before product integration.
- Adobe Camera Raw has lens profiles and a custom profile creator, but those
  are documented for Adobe's Camera Raw workflow, not a verified reusable
  macOS runtime or redistributable profile corpus for this renderer.
  [Adobe documentation](https://helpx.adobe.com/in/camera-raw/desktop/using/correct-lens-distortions-camera-raw.html).

## Decision

Use Apple's supported correction as an explicitly recorded lens stage for
the first renderer. Keep lens identity, focal length, and enabled/supported
state separate from the look/color model. Report geometry, vignetting and TCA
residuals by lens/focal length, including the known 18 mm discrepancy. Do not
import Lensfun or apply its full profiles on top of Apple's correction. Revisit
only if a complete, correctly staged profile or measured residual correction
clearly improves held-out pairs for the affected lens. The camera-match geometry
target remains diagnostic while this custom-lens work is deferred.

The expanded private sample materialized and verified 144 additional exact
RAW/HEIF pairs across 41 dates: 126 used the 18-50mm, ten the 16mm, five the
23mm, and three the 10-18mm. ISO spans 100-12800 and focal lengths 10-50 mm.
The 72 untouched acceptance pairs were not scored in this lens decision.
