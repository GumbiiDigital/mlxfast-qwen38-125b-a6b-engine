# Auditing official score receipts against the track manifest

After an official run, compare the sealed receipt with the track's declared decode floor:

```sh
python3 tools/audit-score-contract.py --manifest benchmark.json --score /path/to/score.json
```

This is a read-only diagnostic. It does not modify a score, override a benchmarker gate, or determine leaderboard promotion. A nonzero exit identifies a missing, malformed, or inconsistent decode-floor metric for organizer investigation. No prefill floor is inferred because the manifest does not declare one.

## Reproduced discrepancy

Official run [34365765860](https://github.com/Layr-Labs/mlxfast-qwen38-125b-a6b-engine/actions/runs/34365765860), candidate `aacab823f9afe8a37c6e02c854a4158aa43e8500`, passed correctness and was promoted with score `1.1216070069077113`. Its receipt reports `metrics.decode_speedup_floor: 0.95`; the candidate manifest declares `scoring.decodeSpeedupFloor: 0.90`. Measured decode speedup was `1.1646982603384306`, so the discrepancy did not change that run's floor verdict.

Source inspection of `Layr-Labs/mlxfast-bench` channel `qwen3.8-125b-a6b-v1` at `c64d1f98d5aac0e8180b1e791c45a9573c398391` shows the paired path calling `official_core_windowed`, whose `finish_official` uses the generic `evaluate_timed_run`. The generic core floor and the receipt metrics built in `iterate.rs` both use `SCORE_DECODE_SPEEDUP_FLOOR = 0.95`. This is more than a displayed-number discrepancy: the inspected path evaluates the generic floor. Other acceptance gates also apply, so this finding alone does not establish the outcome for any hypothetical candidate between 0.90 and 0.95.

The shared benchmarker needs a track-specific policy review and boundary tests before changing enforcement. This diagnostic exposes the disagreement without silently rewriting either policy or historical receipts. The original official binary's complete source mapping has not been independently established by this audit; its receipt is direct evidence of the reported 0.95 value, and the current channel source independently shows the generic gate.

## Local regression checks

```sh
python3 -m unittest discover -s tools -p 'test_audit_score_contract.py'
```

These tests use synthetic receipts and require neither model weights nor a GPU. Full model evaluation remains the official runner's responsibility.
