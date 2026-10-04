# Native paired supervision and bounded experiment execution

> Research evidence from the stated date. Earlier experiment choices are superseded by the active neural-development plan; results are not acceptance of the current pipeline.
Date: October3,2026. Plan0105 execution revision after the user explicitly
approved target-assisted training/manual learning and reported memory exhaustion.
No newly accepted matching model or completed final validation is claimed.

## What target access means

Training may fit directly to separate verified the target vivid look HEIFs, inspect target
pixels manually and use fitted corrections as supervision. Embedded camera images
remain forbidden everywhere. Shared prediction sees only RAW-derived features,
permissible metadata and frozen model parameters. Whole-shoot exclusion assesses
generalization; repeatedly inspected tests become development. This implements
the original supervised objective, not a new authored look or runtime target lookup.

## Fixed-bank expression result

Private contract `control/native-bank-blend-contract.json` freezes original cyan
[capture], the existing six WB/ISO fields, original three regions
plus17 grid regions, independent RAW geometry and bounded softmax blending.
Six iterations,103 observations,28.527s: loss12.4284->6.69245, derivative checks
pass, iteration budget exhausted. One field gets weight0.9999575. Actual HEIF
mean/p95 is2.35939/6.23805; face1.75749 passes, white2.04320 and cyan11.57241
fail. Source/recipe/bounds are unchanged; this is target-assisted expression,
not inference or a global incapacity certificate. Report's `bankSHA256` hashes
serialized field contents, not full model bytes. The successful unrestricted
same-capacity original-cyan witness motivates learning corrections before another
selector over this bank. Neither witness certifies every region or native detail.

Private evidence: `diagnostics/cyan-fixed-bank-blend/fit.json`,
`evaluation/cyan-fixed-bank-blend/[capture].json`,
`control/cyan-fixed-bank-blend-regions.json`. No reserve pixels used.

## Resource failure and operating contract

The Mac has16GiB RAM. The multi-image RAW-context feature exporter reached about
3GiB resident memory despite per-image autorelease scope; its first attempt exited
137 without a final report. Exit137 alone does not establish a macOS OOM kill.
Full-resolution float frames are roughly400MiB each; multiple copies/native
allocations and overlapping compilation/probes compound demand. The user reports
exhaustion. The agent should have bounded resource use before batch expansion.
The existing evaluator already uses a new process per image to release graphics
allocations; apply that lifecycle consistently to the new training work.

`run_bounded.py` owns a shared exclusive job lock, one process group, output log
and resource receipt. Sample summed descendant RSS, physical footprint and system availability every
second. Public macOS libproc RUSAGE_INFO_V4 layout was verified against configured
Xcode SDK resource.h/libproc.h. Enforce4096MiB RSS and footprint (including observed
summed process lifetime peaks), and25% reported system availability;
fail closed if monitoring is unavailable. Stop the whole owned process group on
budget breach/interruption/monitor failure and record incomplete work. No automatic
retry or shared-tool wall-clock timeout. Footprint, RSS and availability are sampled safeguards,
not exact unified GPU footprint or a guarantee against between-sample spikes.
Failed cleanup records its process group beside the lock and blocks another job.
Do not overlap heavy training/rendering, compilation and repository verification.

A five-second native-fit CPU sample on [capture] reports2.2G physical
footprint,3.3G lifetime peak. Buffer copies account for977/2504 main-thread samples
in the two sampled derivative paths, plus further array/CI processing. This is a
short diagnostic, not a whole-run timing decomposition. Retain
`control/native-teacher-fit-cpu.sample.txt`; optimize only after the training method
is useful. Scoped source/output buffer reuse is a justified future candidate; no
pipeline cache/pool, render-order shortcut or optimizer change is implemented here.

## Frozen native-label pilot

Select12 training captures for RAW-feature coverage from77 previously assigned
fit captures, one per date; freeze18 uniform grid regions before target scoring.
Keep23 fit-excluded captures and9 development controls out of fitting. Dates are
not independently verified shoots; this is internal validation, not final reserve.
The static/metadata bank has prior target use on these23 images, so exclusion
applies to the new teacher/residual fitting step, not the complete learned pipeline.
Fit the existing81-coefficient field against native observations, initialized
from the frozen metadata field. Training loss is equal-region squared meanDE00
with target0 and step-only prior; bounds, six iterations,20 halvings and numerical
difference checks remain explicit. This differs from threshold-feasibility fitting:
already passing examples still provide useful correction labels. Acceptance
limits remain mean2/p955 and original region2. All sensitive/unknown support and
numerical/budget failures remain reported. Target-fit labels are finite-budget
solutions, not ground truth coefficients or guaranteed unique transforms.

The pilot's next gate is actual training fit quality, then one fixed RAW-only
residual-coefficient regression and excluded-group HEIF evaluation. If fitting
fails, inspect numerical/support/representation causes. If fitting succeeds but
prediction fails, inspect supervision/predictor features rather than assuming
more images solve it. Expand to the verified collection only after a named screen
failure resolves without lost old passes and held-out results support expansion.
The outcomes below close this pilot; the rejected predictor is not promoted.


## Completed pilot and decision

All twelve native target-fitted training corrections reduced actual HEIF mean and
p95 error. Equal-image mean fell from 1.37928 to 1.13105. Eleven whole images pass;
the indoor portrait remains above the mean limit. All fits exhausted their six
iterations with passing derivative checks: useful corrections, not optima or full
regional/native-detail acceptance.

The portrait initially had only six reliable grid regions, below the unchanged
eight-region requirement. One manually annotated variant retained all eighteen
grid regions and added adult face, child face, book, hand/book and sleeve regions,
frozen before scoring. All five anchors were reliable. Mean/p95 improved from
2.40610/5.07248 to 2.15871/4.78864; both faces pass, book mean 2.024 still fails.
Original support failure and all uncertain regions remain in the private reports.
This illustrates authorized manual training supervision without relaxing gates.

The frozen ridge1 residual-coefficient predictor used twelve usable training
labels and only eight RAW summaries plus six metadata weights at prediction.
Actual native HEIF evaluation rejected it:

| Set | Metadata comparator passes | New predictor passes | Mean before | Mean after |
| --- | ---: | ---: | ---: | ---: |
| Training, 12 | 11 | 10 | 1.37928 | 1.24581 |
| New-fit-excluded, 23 | 23 | 20 | 1.27296 | 1.51480 |
| Development controls, 9 | 5 | 3 | 1.96179 | 2.51644 |

No failing development control resolved. New failures: training [capture];
excluded [capture], [capture], [capture]; controls
[capture] and [capture]. Equal-date excluded mean also worsened,
1.26805 to 1.51710. No full204 evaluation, reserve use or runtime predictor
integration is justified. Keep the best shared metadata model as comparator.

Training correction success does not establish that dense coefficient regression
is suitable supervision. The lost training pass has coefficient residual RMSE
0.02454 despite an improved teacher HEIF. Its teacher derivatives at the bright
cube corner have RMS about 0.083–0.131 versus 28.6–60.4 at the dark corner;
photographs constrain different colour directions unequally. This suggests a
support/identifiability investigation, not proof of its cause. Few coefficients
of the three excluded failures lie outside observed training residual ranges
(1, 1, 2 of81), so unbounded extrapolation alone is not established either.
The next bounded diagnostic should measure RAW colour support and teacher/student
transform disagreement before changing model capacity or collecting more labels.
That diagnostic remains unexecuted at this checkpoint.

Repeated fits/evaluations completed within the resource safeguards. The portrait
fit observed a 3331MiB lifetime physical-footprint peak. Retain per-job receipts;
these sampled limits are operational evidence, not a universal memory guarantee.
The tool fixtures cover normal completion, output protection, RSS/footprint limits,
pressure rejection, job exclusivity, monitor failure and descendant cleanup.

Private evidence under the ignored `data/paired-corpus` corpus:
`control/native-teacher-pilot-contract.json`,
`control/native-teacher-manual-portrait-result.json`,
`control/native-teacher-student-diagnosis.json`,
`native-teacher-pilot/`, `native-teacher-predictor/`, and
`evaluation/native-teacher-student-{training,heldout,screen}/`.
The rejected predictor SHA256 is
`7d18978b0a8ea55d03c7238cda74a7361c12bf2a1635aef551e258b55528f9ea`.
No private media, per-photo labels or predictor are committed.
