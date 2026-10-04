# Standalone vivid RAW 9 pipeline: photographic validation

> Research evidence from the stated date. Earlier experiment choices are superseded by the active neural-development plan; results are not acceptance of the current pipeline.
Date: 2026-10-01. Scope: the initial test camera sensor RAW, macOS Core Image decoder 9,
native-resolution 10-bit SDR sRGB HEIF outside Otos. The objective is matching
the user's the target vivid look camera HEIFs from RAW alone. The current recipe is a working
baseline, not an accepted matching pipeline. This report preserves measured export
and fitting evidence; it does not establish completion of Plan 0105.

## Current candidate recipe and responsibilities

The [recipe](authored-raw9-reference/recipe.json) is format 5, fitted with 55% equal
mass for the six explicit authoring examples and 45% broad training mass, minimizing
normalized D65 Lab squared error through the final display transform. Training has
152 captures from 28 dates; authoring has six captures from three other dates;
selection has 18 captures from 18 separate dates. Fitted-example scores are training diagnostics,
not unseen generalization or a replacement for matching acceptance. Canonical encoded recipe SHA256:
`25bfc59a18a64cc18538efac06f52180e7dba9dfa56efbce9ee9b6e2cb0c6c08`.

Native development owns sensor decoding, capture white balance/baseline exposure,
Apple denoise and independently supported native lens correction. Normalization
has separate exposure/WB controls, currently identity. The monotone tone stage
owns contrast, pivot, skew and bounded hue interpolation. Creative colour owns
saturation and the neutral-protected bounded 5-cubed residual. Display owns the
explicit gamut policy and sole sRGB transfer; the exporter owns HEIF encoding,
metadata/orientation and no-overwrite atomic publication. No per-photo selector,
preview statistics, companion dependency, automatic local adjustment or custom
lens profile enters rendering.

## Fitted-region evidence and remaining measurement limits

These median-colour limits are supplementary diagnostics. They do not establish
the original mean-pixel DE00 <=2 difficult-region gate, which remains required.

Brightness |delta L| <=2, median-colour DE00 <=3 and |delta chroma| <=3 remain the
frozen [look-card](authored-raw9-reference/look-card.json) nominal limits. Actual
native HEIFs meet all three on all 17 regions. Fourteen have reliable correspondence
and pass the additional measured relative-uncertainty gate. White wall, warm shirt
and green tent fabric remain quantitatively inconclusive because native texture
cannot establish reliable alignment. Their nominal DE00 is respectively 0.290,
1.338 and 0.445; chroma differences are +0.129, +2.874 and +0.152. They are not
reported as numerical passes. Full-frame and correctly oriented 512-native-pixel
patch review supplies independent appearance/detail evidence for all six examples,
including these three surfaces. Agent visual review found no new systematic cast,
halo, broken skin transition or lost texture attributable to the authored stages.
This is visual evidence, not invented alignment confidence or user aesthetic approval.

The cyan patch now has lightness -1.572, chroma -2.500 and DE00 1.342. Warm-lit skin
has chroma +2.773. The fixed RAW-derived geometry baseline never changes with
candidate colour. Measurement format 6 retains confident native matches and retries
ambiguous matches once at Gaussian sigma 1.2. Moving both patches together is a
reported content-sensitivity diagnostic; relative uncertainty remains a numerical
gate. Flat/ambiguous comparisons cannot reject or certify a recipe numerically;
actual visible defects independently block acceptance.

The 75% author-priority variant was rejected: it closes nominal anchors but creates
three new combined selection failures. A bounded estimate between 50% and 75%
identified 55% as one final experiment. The 55% candidate closes the last
nominal warm-shirt chroma discrepancy with zero new combined passing-case failures
on the 18 selection images. Mean DE00 changes from 1.869291 to 1.885875; the worst
per-image mean increase is +0.04531. Seven of the 18 selection images still fail the original whole-image mean <=2
and p95 <=5 limits. Zero new failures does not mean zero failures. Native review
of three regressions and improvement of fitted regions do not establish acceptance. No arbitrary fraction sweep, larger field or adaptation was
added. The 18 selection images influenced adoption and are not fresh acceptance.

## Native photographic ablations

One unchanged renderer and stage switches produced actual native HEIFs on the
cyan/skin and warm-illumination examples. Disabling identity normalization gives the
same region measurements. Disabling tone makes cyan lightness -34.476 and warm skin
-15.925. Disabling saturation leaves cyan lightness -4.294 and DE00 3.945. Disabling
the residual makes cyan lightness -25.735 / DE00 26.739 and warm skin chroma +9.262 /
DE00 5.595. The combined look is necessary; the controls have independently verified
ownership but their combined colour effect is not additive. Synthetic stage,
neutral-ramp, signed-input and CPU/Metal conformance fixtures cover the same owner.

## Fresh private-photo coverage and operational checks

The recipe was frozen before reading 94 additional private RAWs in eight time-separated
candidate groups. All 94 exported successfully. Agent review inspected every
full-frame preview, nearby bursts and 512-native-pixel crops from the highest-ISO
capture in each group. Coverage includes indoor backlighting, daylight skin beside
saturated red/blue/green clothing, outdoor foliage, warm interiors, coloured tent
light, bright neutral materials, dark museum detail and ISO 100 through 12800.
Nearby-frame review found consistent style; native review found no new systematic
colour contour, halo or texture defect attributable to the authored stages.
Two Sigma lenses are represented, with supported native correction separately reported.

These are previously unread images, not eight certified independent shoots: seven
candidate dates already occur in development data, and the July 10 tent captures
share context with an authoring example. Do not claim ten independent unseen shoots
or population-wide reliability. The private inventory contains no additional RAW
folders beyond the already audited 3969 Camera Roll originals. Fresh pixels remain
useful appearance/operation evidence with this dependency explicitly disclosed.

Five public RAWs from Photography Blog, RTINGS and raw.pixls.us additionally passed
decoder/export checks across four source/date groups and four other lenses. They
have no intended vivid-look reference and are not evidence that the desired look
has been achieved. Their rendered appearance did not select or tune the recipe.
Further online sample collection stopped when the user questioned its relevance.
The original 50-pair/ten-independent-unseen-shoot matching acceptance remains open.
RAW-only export checks cannot replace it. The prior claim that appearance/operation
coverage replaced this gate was unjustified. The paired collection must be audited
and assigned honest training, development and untouched roles.

Across all 99 files, independent FFprobe inspection verifies HEVC Main 10,
yuv420p10le, sRGB transfer and BT.709 primaries; capture metadata and native dimensions
are preserved, orientation is normalized and before/after original hashes match.
RAWs were deliberately provisioned through non-blocking provider requests, then
SF_DATALESS was checked immediately before byte reads. No companion was read by
this rendering batch. Runtime companion-denial and changed-preview tests on the
final recipe produce exactly identical native decoded pixels. Cancellation during
actual HEIF encoding publishes nothing and removes its temporary file.

Three isolated final-recipe native renders take 4.49, 3.99 and 3.93 seconds on this
16-GB MacBook Pro; maximum resident memory is 1,989,689,344 bytes (about 1.85 GiB).
The earlier same-owner five-render resource probe levels off rather than increasing
monotonically. Its Instruments/log evidence records development, colour, encoding
and total spans; it is evidence on this host, not a cross-device latency guarantee.
No performance optimization is justified by these results.

## Reopening and feedback

For a reported failure, preserve the RAW-only input boundary and assign it to native
input/lens geometry, tone, creative colour, display/encoding or availability/publication.
Reproduce on actual HEIF before modifying the responsible owner. Retain the fixed
recipe as comparator; propose one bounded hypothesis and one or two variants, with
explicit predicted improvement and regression cases. Validate the six look examples,
18 selection cases, native detail and matching technical checks. Unknown alignment
stays unknown; no average score buys a new visible defect. If fixed global capacity
fails on a new verified case, run an offline excluded-region capacity diagnostic
before adding automatic/local processing. Inspected fresh captures are consumed
validation data; further tuning requires new validation observations. Keep sampled
RGB, manifests, photos, native outputs, traces and diagnostic recipes private.

## Private evidence locations

Evidence root: `<local experiment output>`. Final freeze: `authored-v5-final-freeze.json`;
photographs: `authored-v5-perceptual-author55-authoring`,
`authored-v5-perceptual-author55-selection`, `author55-native-review`,
`authored-v5-fresh-raw-only`, `fresh-private-native-review`; stage ablations:
`final-native-stage-ablations`; isolation: `authored-final-input-isolation.log`;
performance: `author55-isolated-performance`; cancellation:
`author55-encoding-cancellation.log`. Earlier same-owner trace/resource evidence:
`authored-v5-standalone.trace`, sanitized `authored-v5-trace-summary.json`.
Temporary evidence is reproducible using the durable recipe, look card and harness;
the original user media and offline fitting inputs are never redistributed.
