#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


TOOL = Path(__file__).with_name("audit-score-contract.py")


class AuditScoreContractTests(unittest.TestCase):
    def run_audit(self, manifest, score):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "benchmark.json"
            score_path = root / "score.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            score_path.write_text(score if isinstance(score, str) else json.dumps(score), encoding="utf-8")
            before = score_path.read_text(encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(TOOL), "--manifest", str(manifest_path), "--score", str(score_path)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(score_path.read_text(encoding="utf-8"), before)
            return result

    @staticmethod
    def manifest(floor=0.90):
        return {"scoring": {"decodeSpeedupFloor": floor}}

    @staticmethod
    def score(floor=0.90, speedup=1.0, passed=True, **extra):
        metrics = {
            "decode_speedup_floor": floor,
            "decode_speedup": speedup,
            "passed_decode_speedup_floor": passed,
            "prefill_speedup_floor": 123.0,
        }
        metrics.update(extra)
        return {"score": 1.0, "metrics": metrics}

    def test_matching_floor_passes_and_ignores_prefill_floor(self):
        result = self.run_audit(self.manifest(), self.score())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_floor_boundary_and_consistent_failure_are_valid_receipts(self):
        for speedup, passed in [(0.90, True), (0.89, False)]:
            with self.subTest(speedup=speedup):
                result = self.run_audit(self.manifest(), self.score(speedup=speedup, passed=passed))
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_mismatching_sealed_floor_fails(self):
        result = self.run_audit(self.manifest(0.90), self.score(0.95))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("decode floor mismatch", result.stderr)

    def test_malformed_boolean_nan_and_missing_values_fail(self):
        cases = [
            (self.manifest(True), self.score()),
            (self.manifest(), self.score(float("nan"))),
            (self.manifest(), {"metrics": {"decode_speedup": 1.0, "passed_decode_speedup_floor": True}}),
        ]
        for manifest, score in cases:
            with self.subTest(manifest=manifest, score=score):
                result = self.run_audit(manifest, score)
                self.assertNotEqual(result.returncode, 0)

    def test_pass_flag_must_match_speedup_and_floor(self):
        result = self.run_audit(self.manifest(), self.score(speedup=0.89, passed=True))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("decode floor flag mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
