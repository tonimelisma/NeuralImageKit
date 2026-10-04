# Current implementation

`tools/camera-render-harness` contains the independently buildable renderer and tests.
`NativeRAWDevelopment` owns Apple RAW9 development and separate native lens controls.
`CameraSensorRAWHEIFRenderer` owns guarded source reads and native HEIF publication.
`RenderingInstrumentation` owns logging, without consumer dependencies.
`run_bounded.py` owns resource supervision. `script/check.sh` builds and verifies these tools.

The existing compact-model code is experimental. The Core AI neural pipeline and
public Swift package API are not implemented.

The active plan is [0001](plans/0001-vivid-neural-development.md).
Relevant research is tracked in [docs/research](research/README.md).
Media live in ignored `data/paired-corpus/`. Data-provenance receipts are ignored
under `data/provenance/`.
