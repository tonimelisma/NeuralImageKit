# NeuralImageKit agent instructions

This is an independent Swift and Core AI image-processing library, not an application component.
Keep it buildable, testable and runnable without any consumer repository.

- Use Apple RAW9 for sensor development; preserve useful range, explicit colour
  interpretation and separately owned lens correction.
- Train appearance models from verified separate RAW/target pairs. Never read
  embedded camera images, including during training and evaluation.
- Keep originals read-only and check materialization immediately before byte reads.
- Keep private pixels, manifests and checkpoints outside Git.
- Public interfaces expose development intent and typed results/errors, not
  consumer catalog/UI types or unrestricted internal model settings.
- Model, development policy and rendering-intent compatibility are versioned.
- One owner implements both library and command-line rendering.
- Bound and measure resource use before heavy training; one heavy job at a time.
- Separate shoot roles and preserve untouched acceptance data.
- Do not claim implementation from research, training fidelity from a lower loss,
  or photographic success from an export completing.
- Document dependencies, licensing, alternatives and tradeoffs before adding them.
- Verification belongs to this repository. Do not invoke consumer app checks or
  depend on consumer logging/build helpers.

The active plan is `docs/plans/0001-vivid-neural-development.md`. Relevant private
research is in `private/research/`; its index states what each document supports.
Private history is provenance, not current execution instructions.
