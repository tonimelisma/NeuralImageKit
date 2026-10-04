#!/usr/bin/env python3
"""Select a private, date-separated candidate acceptance set using names only.

No media bytes, EXIF, thumbnails, or cloud provider APIs are touched here. The
result is a candidate manifest: capture identity, look, and strata must still be
verified before freezing the actual acceptance set.
"""

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path, help="private pair inventory JSON")
    parser.add_argument("observed", type=Path, help="private previously inspected result JSON")
    parser.add_argument("config", type=Path, help="private selection config JSON")
    parser.add_argument("output", type=Path, help="private output manifest JSON")
    args = parser.parse_args()

    inventory = json.loads(args.inventory.read_text())
    observed = json.loads(args.observed.read_text())
    config = json.loads(args.config.read_text())
    dates = config["dates"]
    per_date = config["perDate"]
    seed = config["seed"]
    if not isinstance(dates, list) or len(set(dates)) != len(dates):
        raise ValueError("dates must be a unique list")
    if not isinstance(per_date, int) or per_date < 1 or not isinstance(seed, str):
        raise ValueError("invalid count or seed")

    observed_dates = {item["id"][:8] for item in observed}
    if observed_dates.intersection(dates):
        raise ValueError("candidate date overlaps previously inspected examples")
    grouped = defaultdict(list)
    for pair in inventory:
        if pair["id"][:8] in dates:
            grouped[pair["id"][:8]].append(pair)

    selected = []
    for date in dates:
        options = grouped[date]
        if len(options) < per_date:
            raise ValueError(f"{date} has only {len(options)} pairs")
        options.sort(key=lambda pair: hashlib.sha256(
            f"{seed}:{pair['id']}".encode("utf-8")).hexdigest())
        for pair in options[:per_date]:
            selected.append({
                "id": pair["id"],
                "raw": pair["raw"],
                "target": pair["target"],
                "session": date,
                "role": "acceptance",
            })

    if args.output.exists():
        raise FileExistsError("refusing to replace an already frozen selection")
    args.output.write_text(json.dumps({"pairs": selected}, indent=2) + "\n")
    print(f"selected {len(selected)} candidate pairs across {len(dates)} dates")
    print("capture and look verification still required before acceptance freeze")


if __name__ == "__main__":
    main()
