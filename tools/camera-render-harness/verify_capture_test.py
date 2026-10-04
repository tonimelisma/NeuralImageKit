#!/usr/bin/env python3
"""Media-free checks of capture/encoding/look rejection and read gating."""

import copy
import json
import subprocess
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import verify_capture


class CaptureVerificationTests(unittest.TestCase):
    def setUp(self):
        self.pair = {
            "id": "20260920_120000", "session": "20260920_group1",
            "raw": "/synthetic/original.arw", "target": "/synthetic/target.hif",
        }
        self.metadata = {
            "Model": "ILCE-6700", "DateTimeOriginal": "2026:09:20 12:00:00",
            "SubSecTimeOriginal": "123", "ExposureTime": 0.01, "FNumber": 2.8,
            "ISO": 100, "LensModel": "synthetic lens", "FocalLength": 23,
            "ColorPrimaries": 1, "TransferCharacteristics": 13,
            **verify_capture.LOOK,
        }

    def verify(self, raw=None, target=None):
        entries = [raw or self.metadata, target or self.metadata]
        with patch.object(verify_capture, "local_regular", return_value=True), \
                patch.object(verify_capture.subprocess, "run", return_value=SimpleNamespace(
                    stdout=json.dumps(entries))):
            return verify_capture.verify(self.pair)

    def test_matching_capture_and_supported_look(self):
        self.assertEqual(self.verify()["status"], "verified")

    def test_each_look_adjustment_is_required_on_both_originals(self):
        for field, expected in verify_capture.LOOK.items():
            for side in ("raw", "target"):
                for missing in (False, True):
                    with self.subTest(field=field, side=side, missing=missing):
                        changed = copy.copy(self.metadata)
                        if missing:
                            changed.pop(field)
                        else:
                            changed[field] = expected + 1
                        result = self.verify(**{side: changed})
                        self.assertEqual(result["status"], "rejected")
                        self.assertIn("look:" + field, result["reasons"])

    def test_changed_capture_is_rejected(self):
        changed = {**self.metadata, "ISO": 200}
        self.assertIn("capture:ISO", self.verify(target=changed)["reasons"])

    def test_wrong_transfer_is_rejected(self):
        changed = {**self.metadata, "TransferCharacteristics": 16}
        self.assertIn("targetColorEncoding", self.verify(target=changed)["reasons"])

    def test_unavailable_original_never_invokes_byte_reader(self):
        with patch.object(verify_capture, "local_regular", return_value=False), \
                patch.object(verify_capture.subprocess, "run") as reader:
            self.assertEqual(verify_capture.verify(self.pair)["status"], "unavailable")
            reader.assert_not_called()

    def test_metadata_reader_failure_stays_unknown(self):
        with patch.object(verify_capture, "local_regular", return_value=True), \
                patch.object(verify_capture.subprocess, "run", side_effect=subprocess.TimeoutExpired(
                    "synthetic-reader", 30)):
            result = verify_capture.verify(self.pair)
            self.assertEqual(result["status"], "metadataError")


if __name__ == "__main__":
    unittest.main()
