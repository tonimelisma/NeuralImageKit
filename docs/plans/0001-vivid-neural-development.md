# 0001 — RAW to vivid HEIF through direct image learning

Status: active, not implemented or photographically accepted. Rewritten October 3,
2026 following the user's decision to train an image-to-image network on separate
RAW/HEIF pairs. This document replaces the previous execution instructions.
It is the current plan, not an account of past increments.

## Objective and scope

Produce native-resolution 10-bit SDR sRGB HEIF from sensor RAW from the initial supported camera,
matching the visible appearance of separate, verified vivid HEIF targets.
Use Apple Core Image RAW decoder 9 for sensor development. This repository owns
the standalone library and all training/evaluation. This is the first photographic milestone of a broader RAW development
library: HDR and additional looks, each with separate training data, are core
future capabilities. Native RAW decoding is shared across supported cameras;
look transfer still needs validation. The current matching acceptance remains
vivid SDR. Other looks/HDR targets and consumer integration are not implemented by
this immediate milestone. Encoding formats are output adapters, not the library
roadmap. See [library direction](../roadmap.md).

Training and evaluation may use separate target HEIFs. Embedded camera JPEGs,
HEIFs, previews and their pixels/statistics are forbidden in training, evaluation,
manual inspection and inference. Inference receives only sensor RAW, permitted
RAW metadata and the frozen development configuration/network. No target lookup,
per-photo target-fitted recipe or target-derived registration at inference.

The goal is matching photographs, not compressed-file identity or reproducing
camera's proprietary internals. Existing difficult faces, indoor light, cyan,
greens, warm clothing and highlights remain in scope. Export success, lower
average error and small-set fitting alone do not complete this plan.

## One end-to-end approach

1. Read sensor RAW with guarded file access.
2. Develop it through an explicitly configured Apple RAW9 pipeline, with lens
   correction separately controlled and diagnosed.
3. Pass the developed image to one trained image-to-image appearance network.
4. Convert and encode through native colour-managed 10-bit SDR HEIF output.
5. Decode the actual output for photographic evaluation.

Use a compact established encoder-decoder with whole-image context and local
image detail. First assess a narrow NAFNet configuration; its camera suitability,
whole-image context, component licenses and deployment support are not established.
A small residual U-Net is the bounded alternative if that assessment rejects NAFNet.
See network and Core AI research (retained locally in `private/research/`).
The network predicts the corrected image directly, initially as a correction to
its input. Train against output images, not fitted adjustment coefficients.
Do not introduce image categories, preset templates, LUT selectors or independent
white-balance/exposure/noise-selection networks.

Apple combines operations internally. The numbered outline describes ownership,
not an assertion that every RAW operation is accessible or reorderable. Technical
processing stays supplied by Apple; the network learns the remaining camera
appearance from the data we actually have. Native geometry is not its job.

## What is fixed and what is learned

| Part | Initial policy | When it may change |
| --- | --- | --- |
| Decoder | Explicit RAW9; require support, no silent fallback | A demonstrated platform defect; decoder substitution is a scope decision |
| White balance | Verify and retain camera-recorded balance as interpreted by Apple | Evidence of incorrect interpretation or lost usable colour information |
| Exposure | Apple baseline interpretation, additional exposure offset zero; no new automatic exposure selector | Demonstrated clipping/crushed data or other input limitation |
| Highlight recovery | Retain supported native default; record effective support/enabled state | A measured input-information limitation |
| Noise | RAW9 supplied processing and default supported controls | Demonstrated loss of required texture or unacceptable noise |
| Sharpening/local contrast/tone | Record and retain native defaults initially; no extra selector | Demonstrated artifacts or information loss |
| Other RAW controls | Inventory every exposed control, support and effective value; explicitly retain default policy | A named defect, not an open parameter sweep |
| Lens | Validate supported native correction independently; custom profiles deferred | A validated ready profile option, separately investigated |
| Colour/precision | Explicit floating-point working boundary; choose a supported wide range without premature clipping | A verified colour-boundary defect |
| Appearance | One shared supervised image-to-image network | Controlled architecture/training experiments below |
| Output | Native-resolution 10-bit SDR sRGB HEIF, explicit encoding settings | Demonstrated output defect |

Defaults can vary with input metadata. Freeze our policy and record effective
per-input settings, OS/Xcode versions and decoder support; do not force the same
numbers onto every RAW or assume OS defaults never change. RAW9 handles colour
noise internally; do not tune unsupported/no-effect controls. Read API support
rather than treating every exposed property as an effective independent knob.

Stage settings are independently controlled, but their photographic effects can
interact. The network's internal weights are not independent exposure, saturation
or contrast knobs. Brightness, colour and detail are separately measured and their
training penalties explicitly weighted; this does not create independent artistic
controls. Such controls are not required for this single-look task.

## Reuse and evidence boundary

Reuse verified pairing, safe local corpus storage, colour/geometry measurements,
actual HEIF evaluation and resource supervision where their contracts remain valid.
Do not reopen retired model paths or continue coefficient/selector experiments.
A direct image-to-image network has not been trained or accepted at this checkpoint.
Numerical/infrastructure repairs are not photographic gains.

Standalone research code, public model fixtures and historical research have been
extracted into this repository. Source inventory records the preserved checkpoint
367cd30 and origin hashes. The harness owns its logging and build scripts. Private
corpus relocation records are kept beside the corpus; do not change role assignments
or claim old reports are newly evaluated. The new neural model/public API remain
unimplemented. See native capabilities (retained locally in `private/research/`)
and network research (retained locally in `private/research/`).

## Milestone 1 — Freeze pairs, roles and comparisons

The user reports 8,294 RAW/HEIF pairs available for training and validation.
Treat this as the available collection, not a claim that every pair has already
been independently capture/look/alignment verified. Plan learning around the full
collection, allocating eligible whole shoots to training, development and untouched
acceptance; the small pilot is a training check, not the eventual dataset limit.

Inventory all 8,294 reported pairs using filesystem facts first. Guard metadata reads;
verify camera, capture identity and declared vivid settings. Audit all prior fitting, scoring,
selection and inspection. Group actual shoots/bursts; dates/time gaps are clues,
not proof of independent scenes. Retain training, development and untouched final
shoots. Repeatedly used validation is development, not untouched acceptance.

Verify orientation, crop, colour interpretation and independent correspondence.
Retain unregistered views and native lens diagnostics. Exclude unreliable alignment,
never high error alone. Record excluded coverage and motion/lens differences.
Freeze difficult regions before scoring; keep every previous failure reported.
No exposure, white-balance or saturation matching during evaluation.

Deliver: private versioned manifests, prior-use ledger, coverage and shoot roles,
alignment/mask contract, target decoding check and representative paired overlays.
Feedback: identity/colour-round-trip checks and existing known-perturbation tests.
Reuse validated measurements; repair only reproduced defects.
Gate: trustworthy training observations, no cross-role shoot leakage. Missing
reserve coverage leaves final acceptance open but need not stop training.

## Milestone 2 — Freeze the complete native input configuration

Inventory the current native renderer's controls against API documentation and
runtime support. Produce an explicit policy/value receipt for every exposed
control. Verify camera white-balance interpretation rather than assuming it.
Choose and validate working colour space, range and precision. Preserve and
record useful highlight range for the library's future HDR path before the SDR
appearance/output boundary; do not assume native defaults preserve all of it.
Source alpha,
finite values, crop and full-resolution decoding remain checked boundaries.

Use a small, varied development set covering low/high ISO, faces, saturated colour,
indoor/mixed light, bright highlights and dark texture. Inspect whether input
processing destroys information: clipping, crushed shadows, excessive smoothing,
halos or gamut clipping. Do not require the input to already match the vivid look.

If an input defect is observed, change only the responsible native setting with
all others fixed. At most two predeclared variants per defect. Test actual native
renders and reject unsupported/invalid outputs; do not keep exploring controls
merely because target colour differs. If no defect is established, retain defaults.

Deliver: versioned development configuration, effective-value receipts, saved
floating-point inputs and native crops. Network training does not start until this
boundary is explicit and suitable. Input changes invalidate derived data and the
claim that a previously trained network was evaluated on the current pipeline.

## Milestone 3 — Prove direct training on a small collection

Select a small varied training subset before inspecting candidate results; retain
hard examples. Deliberately overfit it. Choose one established architecture with
whole-image context plus detailed patches; preserve the target's precision and
avoid premature 8-bit conversion. Training patches alone must not remove the
whole-image information used at inference. Define native-resolution inference
and seam-free reconstruction before committing to an architecture.

Start with supervised image reconstruction, multi-scale brightness and colour
penalties, plus an edge/detail penalty. Specify colour domain, correspondence
masking, weights and sample weighting before a run. Match prediction directly to
separate target images; fitted per-photo coefficients are not supervision. Assess
encoded HEIF alongside floating-point output. Do not train against unreliable
pixel correspondence, lens shifts or exact random noise realizations.

Before a heavy run, write architecture/version, initialization, optimizer/rate,
steps, sampling, loss weights, checkpoint cadence, maximum elapsed time and memory
budget. These implementation choices remain open here; resolve them once in the
pilot contract rather than silently varying them. Verify a tiny batch loads,
backpropagates, reduces training loss and round-trips through output first.

Deliver: trained checkpoint, repeatable command/configuration and paired outputs
for every pilot image; separate brightness, colour and native-detail findings.
Gate: convincingly reproduce the training examples without new artifacts under
the unchanged photographic limits below. A lower training loss is insufficient.

Failure loop: classify alignment, information loss, numerical/training defect or
model limitation. Permit one repair or at most two declared variants for the
named cause, then report success/rejection/inconclusive. Do not expand a failed
pilot or silently spend days increasing capacity. Exhausted compute is not proof
that the model family cannot work. A blocked pilot requires a concrete revised
experiment, evidence and a progress report before further heavy work.

## Milestone 4 — Learn transferable behaviour across the collection

After pilot fidelity, train across the eligible training allocation from the
8,294-pair collection, deliberately provisioning more pairs where needed. Preserve the
input configuration and withheld roles. Balance independent shoots/lighting/ISO,
not just abundant neighbouring frames. Measure benefits of additional data using
fixed development shoots; inventoried pairs are not verified independent examples.

Explore only a named cause: training duration, sampling, network capacity or
brightness/colour/detail loss balance. At most two variants in one cycle. Use
checkpoint selection on development only. No target-derived features at inference.

Feedback: per-image and per-region results, error maps, native crops, worst cases,
lighting/ISO groups and adjacent-frame consistency. Good training/poor excluded
results sends work to generalization/coverage; poor results on both sends work to
training/representation. A specific input limitation reopens Milestone 2, not an
extra automatic selector beside the network.

Gate: excluded-shoot benefit, difficult controls meet limits and detail remains
sound. Do not promote a model based on averages or training reproduction. Close
an unsuccessful bounded experiment before choosing the next evidence-backed action.

## Milestone 5 — Full-resolution native inference and HEIF

Run one complete frozen configuration at native resolution. Initially retain the
chosen input detail policy with no extra sharpening. Add a separately controlled
native output operation only for a demonstrated defect; compare fixed variants,
avoid duplicating RAW9/network processing and rerun development after any change.

Verify actual HEIF bit depth, codec, SDR transfer/primaries/profile, dimensions,
orientation and decoded appearance. Test full-image/patch inference agreement,
seams/borders, highlights, faces, texture, noise and halos. If reduced-resolution
training does not transfer, revise training scale/detail sampling explicitly.
Prefer PyTorch for training and Core AI for native inference. Test an early
representative export before broad training; compare training-runtime and deployed
outputs before claiming equivalence, with measured tolerances and malformed/input
fixtures. Core ML is an alternative only for a demonstrated Core AI limitation.
Do not require a CPU implementation of Apple Neural Engine internals.

Deliver: one reproducible RAW-only export path, versioned model/configuration and
native photographic/latency/memory evidence. An inference backend or preprocessing
change requires renewed comparison, not presumed equivalence.

## Milestone 6 — Untouched acceptance and completion

Freeze source, model, native controls, output and comparison contract before using
the final reserve. Require at least 50 verified unused pairs across at least 10
independently checked shoots, using more eligible pairs when available. Report
coverage and every failure. Previously inspected/fitted/scored groups are ineligible.

| Aspect | Acceptance |
| --- | --- |
| Whole-photo colour/brightness | Each image: valid low-frequency mean CIEDE2000 <= 2.0 and p95 <= 5.0; report unblurred errors too |
| Difficult regions | Every frozen reliable region: low-frequency mean pixel CIEDE2000 <= 2.0; no visible broad mismatch or new artifact |
| Native detail | No systematic halos, lost texture, fringes, excess noise or inference seams; random noise identity is not required |
| Geometry | Independently reported; unsupported/residual lens correction remains an explicit limitation, never absorbed or hidden |
| Independence | Sensor RAW and allowed metadata only at inference; embedded camera images excluded everywhere |
| Operation | Guarded reads, read-only originals, no-overwrite output, complete publication, cancellation, measured memory/latency and no silent fallback |

Retain the existing 768-pixel long-edge, Gaussian sigma 1.2 comparison contract,
validated D65 Lab/DE00 and identical colour/crop/resampling. Report valid fractions
and clipping. These numerical limits are engineering gates, not guarantees of
visual identity. They supplement native visual/detail inspection. Do not relax
limits after a failure or substitute median colours for pixel comparisons.

A failed reserve becomes development evidence; diagnose it and obtain fresh final
acceptance material. No accepted matching model or independent reserve sufficiency
is currently claimed. Delete this plan only after photographic, operational and
independent acceptance plus delivery are complete.

## Resource, media and execution rules

Keep originals read-only. Check SF_DATALESS immediately before every original byte
read. Authorized deliberate cloud-file provisioning/copying continues through the
existing safeguards. Store private copies, manifests, source tensors, targets,
checkpoints and diagnostics in the independent repository's ignored
data/paired-corpus/, outside media folders and Git. Preserve source provenance
and verify copy size/hash. Worktree cleanup must not delete the corpus.

Integrate/verify the existing bounded-execution owner before heavy work. One heavy
job at a time; no overlap with compilation/full repository checks. Initially retain
4096 MiB summed process-tree RSS and physical-footprint limits, 25% system memory
availability and one-second sampling. Include training workers and native/GPU
allocations in resource observations; these limits are safeguards, not exact total
GPU memory guarantees. Validate accelerator/resource observation before expansion.
Stop the owned process group on breach, record incomplete work and halt the batch;
no silent retry. Use bounded batches and fresh processes where needed. Never load
the whole native-resolution collection into RAM. Record per-run memory and time.

Each experiment has one hypothesis, unchanged stages, at most two variants,
predeclared data roles and stopping/regression rules. Report adopt/reject/inconclusive,
actual photographic changes, infrastructure repairs separately, resource cost and
one next action. Communicate meaningful progress during work; do not replace failed
experiments with unreported sweeps. A failed bounded experiment is not plan completion.

No third-party dependency before an ADR comparing alternatives, licensing,
training/runtime support, memory and native export. Training tools may differ from
native inference but their boundary must be explicit. Establish this repository's own library/training checks and monitored run entry
point as implementation begins. Do not depend on another application's check,
logging or install scripts. GitHub CI is not an experimental milestone. This
migration installs no model and starts no heavy training. Preserve the source
checkpoint and originals; migrate private data separately with verified copies.
