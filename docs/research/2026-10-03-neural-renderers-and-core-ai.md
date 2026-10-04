# Direct image networks and Apple Core AI

> Research evidence from the stated date. Earlier experiment choices are superseded by the active neural-development plan; results are not acceptance of the current pipeline.
Date: October 3, 2026. Research only; no model installed, trained, converted or
benchmarked. The user reports 8,294 paired RAW/HEIF examples; verification and
whole-shoot assignment remain work. This extends the frozen-RAW9 direct-learning
plan, not sensor reconstruction or automatic preset selection.

## Core AI findings

Apple introduced Core AI at WWDC26 for deploying custom models on device across
CPU, GPU and Neural Engine. Python tooling converts exported PyTorch graphs to
.aimodel assets; Swift AIModel/InferenceFunction/NDArray APIs execute them. Apple
shows numerical comparison against the original PyTorch model and supplies
profiling/debugging and specialization tools. This is an inference/deployment
framework, not an automatic training procedure or pretrained camera renderer.

Apple's Core AI Models repository supplies conversion recipes, authoring primitives
and runtime utilities. It requires macOS/iOS 27 and Xcode 27 for execution. The
reviewed catalog includes segmentation, depth and super-resolution models, but
no identified camera vivid model or ready conversion recipe for the candidates
below. Custom model conversion is possible; op/shape/precision compatibility
still needs a real conversion and comparison experiment.

Apple documents PyTorch MPS and MLX as training options on Apple GPUs. Prefer
PyTorch initially to reuse research architecture code and the direct Core AI
conversion path. MLX remains an alternative if measured framework limitations
justify a port. Do not write native training infrastructure or assume training
runs on the Neural Engine. No training speed or memory estimate is established.

Local read-only check: configured Xcode 27.0 (27A266a), macOS 27.0.1, and
CoreAI.framework/Modules/CoreAI.swiftmodule exists in the configured macOS SDK.
Presence is not proof that any candidate converts or meets runtime budgets.

## Concrete architecture candidates

| Candidate | Fit to the task | Limits and first check |
| --- | --- | --- |
| Small residual U-Net | Direct RGB input/output with multi-scale context and detail; narrow standard architecture gives explicit size control | Architecture specification, not a ready camera model. Whole-photo context and native-resolution tiling must be specified and tested; avoid blindly copying an unrelated segmentation implementation |
| NAFNet, narrow configuration | Official PyTorch restoration encoder-decoder; relatively simple residual prediction and configurable width, with released training code | Published denoise/deblur results are not camera colour-matching evidence. Global pooling/context, patch-to-full-image behaviour, normalization ops, MPS training and Core AI conversion require checks |
| MIRNet-v2 | Official PyTorch implementation with paired photo enhancement on FiveK and multi-resolution contextual features | Released code uses a noncommercial academic license; not the default product code dependency. Its published training configuration is not sized for this 16 GiB Mac |
| GleNet | Published paired enhancement separates global intensity treatment and local refinement | Reviewed repository declares TensorFlow 2.2; code completeness/current training support need further audit. Useful methodological reference, not assumed ready modern PyTorch code |

Recommendation: first assess a narrow NAFNet configuration as the concrete
existing PyTorch candidate, before paying for broad training. Its suitability is
unproven. Audit the actual architecture source, component licenses and dependency
requirements in the implementation ADR. Do not import the complete research
training stack automatically. A small residual U-Net is the bounded alternative
if NAFNet's operations/context or memory are unsuitable, not a simultaneous sweep.
MIRNet-v2 supplies relevant enhancement evidence but its released code is not the
default product implementation. Neither weights trained for another task nor
published scores constitute a camera matching checkpoint.

## Implementation checks before broad training

1. Freeze native inputs/colour interpretation and whole-shoot roles first.
2. Specify network width/depth, image context, patch size, precision and native
   inference strategy. Keep target precision; old JPEG/8-bit data loaders are not
   automatically appropriate for the separate 10-bit HEIF targets.
3. Verify forward/backward on a tiny batch under the existing memory owner, and
   direct target reconstruction on the small varied training collection.
4. Test a representative architecture export to Core AI and numerical output
   agreement early, before full-collection training. Measure memory and timing;
   do not require unsupported operations or silently substitute a backend.
5. Verify whole-image versus tiled output, global-context consistency and borders.
   Only a successful pilot permits full eligible training and excluded-shoot tests.

Native deployment is RAW9 -> trained appearance network executed through Core AI
-> native colour-managed 10-bit SDR HEIF. Core ML is a documented alternative
backend only if a measured Core AI limitation justifies it; backend changes require
explicit comparison. No app integration is required to run a standalone Swift
exporter. This research adopts no dependency or completed architectural ADR.

## Primary sources

- [Apple: Meet Core AI](https://developer.apple.com/videos/play/wwdc2026/324/)
- [Apple: Core AI model tools and requirements](https://github.com/apple/coreai-models)
- [Apple: Core AI model catalog](https://github.com/apple/coreai-models/tree/main/models)
- [Apple: training on Apple GPUs](https://developer.apple.com/videos/play/wwdc2024/10160/)
- [NAFNet official implementation](https://github.com/megvii-research/NAFNet)
- [NAFNet architecture](https://github.com/megvii-research/NAFNet/blob/main/basicsr/models/archs/NAFNet_arch.py)
- [NAFNet component licenses](https://github.com/megvii-research/NAFNet/blob/main/LICENSE)
- [MIRNet-v2 official implementation](https://github.com/swz30/MIRNetv2)
- [MIRNet-v2 enhancement training](https://github.com/swz30/MIRNetv2/tree/main/Enhancement)
- [MIRNet-v2 license](https://github.com/swz30/MIRNetv2/blob/main/LICENSE.md)
- [GleNet official implementation](https://github.com/hukim1124/GleNet)
- [GleNet paper](https://www.ecva.net/papers/eccv_2020/papers_ECCV/html/5010_ECCV_2020_paper.php)
