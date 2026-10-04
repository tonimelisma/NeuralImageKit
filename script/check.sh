#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/tools/camera-render-harness/build.sh" "$root/build/check"
