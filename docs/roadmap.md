# NeuralImageKit roadmap


User direction, October 3, 2026: the separate library is a RAW development engine,
with HDR and multiple learned looks as core capabilities. File encoders are output
adapters, not the capability roadmap. Vivid is the first look being developed.
This section records future library scope; it does not claim implementation or
expand Plan 0001's immediate photographic acceptance to untrained looks.

### Capability sequence

1. **Common RAW foundation.** Use macOS-supported RAW development to produce a
   documented floating-point working image with explicit colour/range metadata.
   Keep sensor development, supported lens correction, learned appearance and
   output representation separately owned. Check useful highlight range before
   narrowing it for SDR. Camera-specific decoding/calibration belongs to Apple.
2. **First learned look.** Train the direct image-to-image vivid model using
   the eligible allocation from the reported 8,294 pairs. Establish training
   reproduction, excluded-shoot behaviour, native detail and resource reliability.
3. **SDR and HDR development.** Preserve useful RAW brightness range, define HDR
   reference white/headroom, develop deliberate SDR/HDR renditions and establish
   display adaptation. Use appropriate HDR training targets; existing 10-bit SDR
   training targets do not establish the desired HDR rendition. Evaluate HDR under
   declared viewing conditions and SDR fallback independently. Gain maps or PQ/HLG
   are representations after development, not substitutes for learning HDR intent.
4. **Additional looks.** Add separate training pairs and a versioned model/input
   contract for each look. Initially prefer independently trained models with the
   same runtime/API; a shared look-conditioned network is a later measured option.
   Do not invent image categories, template presets or per-photo target lookups.
5. **Practical development controls.** Explore exposure/white balance before the
   learned appearance and optional look strength, only with evidence that controls
   behave meaningfully across SDR/HDR. Look-specific nonlinear effects may require
   control-aware training; separate operations do not prove independent effects.
6. **Camera coverage and library consumers.** Aim to accept RAWs supported by the
   configured macOS developer through one common interface. Test transfer across
   additional camera models. A normalized RGB boundary avoids new raw-format
   parsing; it does not prove identical colour/noise response or model quality.
   Do not require a separate model per camera without measured need. Report decoder
   support separately from validated look coverage. a consumer application and command-line tools
   consume the same independently owned library.

### Boundary and network choices

The central operation develops a RAW into a colour-managed image/result for a
requested look and SDR/HDR intent. Encoding is a separate convenience adapter
calling that same operation. Version model, input-development policy and supported
rendering intent together. Keep the standalone file-in/file-out wrapper available;
a consumer application must not own development settings or neural execution.

Direct RGB networks remain the initial approach. HDR options include distinct
SDR/HDR models, a shared network conditioned on rendering intent, or a shared
learned scene appearance followed by established SDR/HDR rendering. Compare them
only when HDR target data and an evaluation contract exist; do not assume an
SDR-trained network preserves or predicts HDR highlights. Additional look data
can train the same architecture with new weights before introducing multi-look
conditioning. No network/encoder/camera option is declared implemented here.

See [Plan 0001](plans/0001-vivid-neural-development.md) for current
execution and HDR and RAW boundary research retained locally in `private/research/`
for the technical evidence behind this direction.
