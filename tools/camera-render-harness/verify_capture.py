#!/usr/bin/env python3
"""Verify paired Camera capture facts before an acceptance manifest is frozen.

This independent metadata audit uses the ExifTool already used by the original
research inventory. It is not a model-training or Otos runtime dependency. Each
media path is checked for SF_DATALESS immediately before the metadata subprocess.
No media bytes or private path manifests are written to the repository.
"""

import argparse
import collections
import json
import os
import stat
import subprocess
from pathlib import Path


DATALESS = 0x40000000
FIELDS = [
    "Model", "DateTimeOriginal", "SubSecTimeOriginal", "ExposureTime",
    "FNumber", "ISO", "WhiteBalance", "ColorTemperature",
    "ColorCompensationFilter", "ColorPrimaries",
    "TransferCharacteristics", "ImageWidth", "ImageHeight",
    "Orientation", "LensModel", "FocalLength",
]
SAME_CAPTURE = [
    "Model", "DateTimeOriginal", "SubSecTimeOriginal",
    "ExposureTime", "FNumber", "ISO", "LensModel", "FocalLength",
]
LOOK = {
    "CreativeStyle": 16,
    "PictureProfile": 38,
    "DynamicRangeOptimizer": 0,
    "Contrast": 0,
    "Saturation": 0,
    "Sharpness": 0,
    "Clarity": 0,
    "Highlights": 0,
    "Shadows": 0,
    "Fade": 0,
    "SharpnessRange": 1,
}
# Request maker-note fields separately from similarly named standardized EXIF fields.
FIELDS += ["MakerNotes:" + field for field in LOOK]


def local_regular(path):
    try:
        info = os.lstat(path)
        return stat.S_ISREG(info.st_mode) and not info.st_flags & DATALESS
    except OSError:
        return False


def verify(pair):
    if not local_regular(pair["raw"]) or not local_regular(pair["target"]):
        return {"id": pair["id"], "status": "unavailable"}
    try:
        command = ["exiftool", "-json", "-n", *["-" + field for field in FIELDS],
                   pair["raw"], pair["target"]]
        output = subprocess.run(command, capture_output=True, text=True,
                                timeout=30, check=True)
        entries = json.loads(output.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        return {"id": pair["id"], "status": "metadataError",
                "reason": type(error).__name__}
    if len(entries) != 2:
        return {"id": pair["id"], "status": "metadataError",
                "reason": "entryCount"}
    raw, target = entries
    reasons = []
    for field in SAME_CAPTURE:
        if raw.get(field) is None or raw.get(field) != target.get(field):
            reasons.append("capture:" + field)
    if raw.get("Model") != "ILCE-6700":
        reasons.append("camera")
    capture_date = raw.get("DateTimeOriginal", "").replace(":", "")[:8]
    if capture_date != pair["id"][:8]:
        reasons.append("captureDate")
    if (pair["session"] != capture_date
            and not pair["session"].startswith(capture_date + "_")
            and not pair["session"].startswith("original-")):
        reasons.append("sessionDate")
    for field, expected in LOOK.items():
        if raw.get(field) != expected or target.get(field) != expected:
            reasons.append("look:" + field)
    if target.get("ColorPrimaries") != 1 or target.get("TransferCharacteristics") != 13:
        reasons.append("targetColorEncoding")
    record = {
        "id": pair["id"],
        "status": "verified" if not reasons else "rejected",
        "reasons": reasons,
        "iso": raw.get("ISO"),
        "focalLength": raw.get("FocalLength"),
        "lensModel": raw.get("LensModel"),
        "exposureTime": raw.get("ExposureTime"),
    }
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("verified_manifest", type=Path)
    args = parser.parse_args()
    if args.report.exists() or args.verified_manifest.exists():
        raise FileExistsError("refusing to replace a frozen verification record")
    pairs = json.loads(args.manifest.read_text())["pairs"]
    records = []
    for index, pair in enumerate(pairs, 1):
        records.append(verify(pair))
        if index % 12 == 0:
            print(f"verified metadata {index}/{len(pairs)}", flush=True)
    accepted = {record["id"] for record in records if record["status"] == "verified"}
    args.report.write_text(json.dumps(records, indent=2) + "\n")
    args.verified_manifest.write_text(json.dumps({"pairs": [
        pair for pair in pairs if pair["id"] in accepted
    ]}, indent=2) + "\n")
    counts = collections.Counter(record["status"] for record in records)
    print(json.dumps({"statusCounts": counts,
                      "verifiedSessions": len({pair["session"] for pair in pairs
                                               if pair["id"] in accepted})}, sort_keys=True))


if __name__ == "__main__":
    main()
