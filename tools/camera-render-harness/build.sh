#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
    echo "usage: $0 output-directory" >&2
    exit 2
fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$1"
mkdir -p "$output/swift-cache"

python3 -B "$root/tools/camera-render-harness/verify_capture_test.py"
python3 -B "$root/tools/camera-render-harness/run_bounded_test.py"

xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -Xcc -DACCELERATE_NEW_LAPACK -module-cache-path "$output/swift-cache" \
    "$root/tools/camera-render-harness/RenderingInstrumentation.swift" \
    "$root/tools/camera-render-harness/NativeRAWDevelopment.swift" \
    "$root/tools/camera-render-harness/AuthoredLook.swift" \
    "$root/tools/camera-render-harness/CreativeColour.swift" \
    "$root/tools/camera-render-harness/BoundedColourSolve.swift" \
    "$root/tools/camera-render-harness/NativeProfileFieldSolve.swift" \
    "$root/tools/camera-render-harness/NativeProfileField.swift" \
    "$root/tools/camera-render-harness/ConditionalProfile.swift" \
    "$root/tools/camera-render-harness/ConditionalProfileSelfTest.swift" \
    "$root/tools/camera-render-harness/NativeInputRangeAudit.swift" \
    "$root/tools/camera-render-harness/NativeRegionPalette.swift" \
    "$root/tools/camera-render-harness/DisplayColourCalibration.swift" \
    "$root/tools/camera-render-harness/AuthoredLookSelfTest.swift" \
    "$root/tools/camera-render-harness/LookRegions.swift" \
    "$root/tools/camera-render-harness/AuthoredCalibration.swift" \
    "$root/tools/camera-render-harness/AuthoredCapacitySelfTest.swift" \
    "$root/tools/camera-render-harness/AuthoredCalibrationExport.swift" \
    "$root/tools/camera-render-harness/ColorDifference.swift" \
    "$root/tools/camera-render-harness/Scorecard.swift" \
    "$root/tools/camera-render-harness/ComparisonCalibration.swift" \
    "$root/tools/camera-render-harness/NativeOrderDiagnostic.swift" \
    "$root/tools/camera-render-harness/Geometry.swift" \
    "$root/tools/camera-render-harness/NativeGeometry.swift" \
    "$root/tools/camera-render-harness/LensAudit.swift" \
    "$root/tools/camera-render-harness/Viewer.swift" \
    "$root/tools/camera-render-harness/SensorRAWHEIFRenderer.swift" \
    "$root/tools/camera-render-harness/SensorRAWHEIFSelfTest.swift" \
    "$root/tools/camera-render-harness/SensorRAWHEIFEvaluation.swift" \
    "$root/tools/camera-render-harness/LookModel.swift" \
    "$root/tools/camera-render-harness/LookCalibration.swift" \
    "$root/tools/camera-render-harness/LookCalibrationSelfTest.swift" \
    "$root/tools/camera-render-harness/LookModelSelfTest.swift" \
    "$root/tools/camera-render-harness/main.swift" \
    -o "$output/camera-render-harness"

xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library -module-cache-path "$output/swift-cache" \
    "$root/tools/camera-render-harness/Materialize.swift" \
    -o "$output/camera-render-materialize"

"$output/camera-render-harness" self-test \
    "$root/tools/camera-render-harness/ciede2000-reference.txt"
"$output/camera-render-harness" look-self-test \
    "$root/docs/research/camera-vv2-raw9-reference/model.json" \
    "$root/docs/research/camera-vv2-raw9-reference/test-vectors.json"
