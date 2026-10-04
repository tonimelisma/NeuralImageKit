# Standalone image development tools

Build from the repository root with `script/check.sh`.
The command-line renderer uses Apple RAW9, separately owned native lens controls,
explicit colour interpretation and native 10-bit SDR HEIF encoding.
Its compact-model experiments and synthetic fixtures are development tools;
the planned Core AI neural pipeline is not implemented yet.

Source images are read-only and checked for materialization before byte access.
Separate target images are permitted only in offline fitting and evaluation.
Embedded camera images must never be used. Keep private inputs and outputs outside Git.
