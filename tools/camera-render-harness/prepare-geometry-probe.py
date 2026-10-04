#!/usr/bin/env python3
"""Select focal-extreme training pairs per session for a private geometry audit.

Read only previously verified private manifest and metadata JSON. Choose the
minimum and maximum focal length within each session; a fixed name hash breaks
ties. No image bytes or result scores influence membership. Refuse to replace
a frozen output manifest.
"""

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("training_manifest", type=Path)
    parser.add_argument("verification_report", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to replace {args.output}")
    pairs = json.loads(args.training_manifest.read_text())["pairs"]
    records = {record["id"]: record for record in
               json.loads(args.verification_report.read_text())}
    grouped = defaultdict(list)
    for pair in pairs:
        record = records[pair["id"]]
        if record["status"] != "verified" or not isinstance(record["focalLength"], (int, float)):
            raise ValueError("training manifest includes an unverified focal length")
        grouped[pair["session"]].append(pair)

    selected = []
    for session in sorted(grouped):
        options = sorted(grouped[session], key=lambda pair: (
            records[pair["id"]]["focalLength"],
            hashlib.sha256(("otos-0105-geometry-v1:" + pair["id"]).encode()).hexdigest(),
        ))
        first = options[0]
        last = options[-1]
        selected.append(first)
        if last["id"] != first["id"]:
            selected.append(last)
    args.output.write_text(json.dumps({"pairs": selected}, indent=2) + "\n")
    print(json.dumps({"pairs": len(selected), "sessions": len(grouped)}, sort_keys=True))


if __name__ == "__main__":
    main()
