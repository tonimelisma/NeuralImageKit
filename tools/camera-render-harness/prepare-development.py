#!/usr/bin/env python3
"""Freeze training and selection roles without reading any original media bytes.

Original capture bursts stay together. Any original session containing a known
regression capture is omitted from fitting. Later dates inspected in the earlier
research pass serve as model selection; the untouched acceptance dates are
excluded completely. Other unexamined dates add training diversity.
"""

import argparse
import datetime as dt
import hashlib
import json
from collections import defaultdict
from pathlib import Path


def write_new(path, pairs):
    if path.exists():
        raise FileExistsError(f"refusing to overwrite {path}")
    path.write_text(json.dumps({"pairs": pairs}, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original_verified", type=Path)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("earlier_inspected", type=Path)
    parser.add_argument("regression_manifest", type=Path)
    parser.add_argument("acceptance_manifest", type=Path)
    parser.add_argument("training_output", type=Path)
    parser.add_argument("selection_output", type=Path)
    args = parser.parse_args()
    originals = json.loads(args.original_verified.read_text())
    inventory = json.loads(args.inventory.read_text())
    earlier = json.loads(args.earlier_inspected.read_text())
    regression = json.loads(args.regression_manifest.read_text())["pairs"]
    acceptance = json.loads(args.acceptance_manifest.read_text())["pairs"]
    regression_ids = {pair["id"] for pair in regression}
    acceptance_dates = {pair["session"] for pair in acceptance}
    earlier_ids = {item["id"] for item in earlier}
    earlier_dates = {item[:8] for item in earlier_ids}
    if regression_ids.intersection(pair["id"] for pair in acceptance):
        raise ValueError("regression overlaps acceptance")

    originals.sort(key=lambda pair: (
        pair["metadata"][0]["DateTimeOriginal"],
        str(pair["metadata"][0]["SubSecTimeOriginal"]),
    ))
    groups = []
    for pair in originals:
        timestamp = dt.datetime.strptime(pair["metadata"][0]["DateTimeOriginal"],
                                         "%Y:%m:%d %H:%M:%S")
        if not groups or (timestamp - groups[-1][-1][0]).total_seconds() > 600:
            groups.append([])
        groups[-1].append((timestamp, pair))
    training = []
    excluded = []
    for index, group in enumerate(groups, 1):
        if any(pair["id"] in regression_ids for _, pair in group):
            excluded.append(len(group))
            continue
        for _, pair in group:
            training.append({"id": pair["id"], "raw": pair["raw"],
                             "target": pair["target"],
                             "session": f"original-{index:02d}", "role": "training"})

    indexed = {pair["id"]: pair for pair in inventory}
    selection = []
    for id in sorted(earlier_ids - regression_ids):
        pair = indexed[id]
        selection.append({"id": id, "raw": pair["raw"], "target": pair["target"],
                          "session": id[:8], "role": "selection"})

    candidate_dates = defaultdict(list)
    for pair in inventory:
        date = pair["id"][:8]
        if date not in earlier_dates | acceptance_dates | {"20260920", "20260921"}:
            candidate_dates[date].append(pair)
    # Five name-only hash-selected captures from every remaining date with enough
    # candidates. A fixed seed prevents later performance-driven reselection.
    selected_dates = sorted(date for date, pairs in candidate_dates.items() if len(pairs) >= 5)
    for date in selected_dates:
        candidates = sorted(candidate_dates[date], key=lambda pair: hashlib.sha256(
            ("otos-0105-training-v1:" + pair["id"]).encode()).hexdigest())
        for pair in candidates[:5]:
            training.append({"id": pair["id"], "raw": pair["raw"],
                             "target": pair["target"],
                             "session": date, "role": "training"})
    if {pair["id"] for pair in training}.intersection(earlier_ids | regression_ids |
                                                       {pair["id"] for pair in acceptance}):
        raise ValueError("role overlap")
    write_new(args.training_output, training)
    write_new(args.selection_output, selection)
    print(json.dumps({"originalGroups": len(groups),
                      "excludedRegressionGroupSizes": excluded,
                      "trainingPairs": len(training),
                      "newTrainingDates": len(selected_dates),
                      "selectionPairs": len(selection)}, sort_keys=True))


if __name__ == "__main__":
    main()
