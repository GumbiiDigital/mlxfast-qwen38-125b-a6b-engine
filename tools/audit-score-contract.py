#!/usr/bin/env python3
"""Read-only diagnostic for a manifest/score speedup-floor mismatch."""

import argparse
import json
import math
import sys
from pathlib import Path


def load_json(path: Path):
    def reject_constant(token):
        raise ValueError(f"non-finite JSON constant {token}")

    with path.open(encoding="utf-8") as stream:
        return json.load(stream, parse_constant=reject_constant)


def finite_number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a finite number")
    value = float(value)
    if not math.isfinite(value):
        raise ValueError(f"{label} must be a finite number")
    return value


def audit(manifest_path: Path, score_path: Path):
    manifest = load_json(manifest_path)
    score = load_json(score_path)
    declared = finite_number(
        manifest["scoring"]["decodeSpeedupFloor"],
        "manifest scoring.decodeSpeedupFloor",
    )
    metrics = score["metrics"]
    sealed = finite_number(
        metrics["decode_speedup_floor"],
        "score metrics.decode_speedup_floor",
    )
    speedup = finite_number(metrics["decode_speedup"], "score metrics.decode_speedup")
    passed = metrics["passed_decode_speedup_floor"]
    if not isinstance(passed, bool):
        raise ValueError("score metrics.passed_decode_speedup_floor must be boolean")
    if declared != sealed:
        raise ValueError(
            f"decode floor mismatch: manifest={declared:g}, sealed score={sealed:g}"
        )
    expected = speedup >= sealed
    if passed != expected:
        raise ValueError(
            "decode floor flag mismatch: "
            f"speedup={speedup:g}, floor={sealed:g}, passed={passed}"
        )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--score", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        audit(args.manifest, args.score)
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        print(f"audit-score-contract: {exc}", file=sys.stderr)
        return 2
    print("audit-score-contract: decode floor and pass flag agree")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
