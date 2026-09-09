# Native MTP depth-2 submission incidents

This report records two attempts of the same promoted candidate with the
native MTP declaration set to depth 2. Neither attempt produced candidate
timing, so neither is a score result for the candidate.

| Submission | Workflow run | Observed outcome |
| --- | --- | --- |
| `55f1dfe7-6b45-415c-8788-6fb7fbc76ba3` | [34393319403](https://github.com/Layr-Labs/mlxfast-qwen38-125b-a6b-engine/actions/runs/34393319403) | Setup stopped after the self-hosted runner reported lost communication with GitHub. The workflow never reached transform or timing. |
| `bf47c191` | [34395766718](https://github.com/Layr-Labs/mlxfast-qwen38-125b-a6b-engine/actions/runs/34395766718) | Setup completed, then the serial-control leg failed its out-of-band decode check before candidate timing. |

For the first run, the public Actions annotation reports only that the runner
lost communication with the server. It suggests checking machine health and
network connectivity, and mentions CPU or memory starvation as possible causes.
It does not identify which cause occurred. The available record does not prove
an engine, candidate, or workflow defect, and no compiler-stall explanation
should be inferred from it.

The retry reached the paired benchmark. Its serial-control decode was
`0.032777791015625`, below the lower bound `0.03280095840820312`; the serial
mean was `0.03347036572265625`, against the declared `0.98–1.02` calibration
band. This is a reference-leg/calibration repeatability failure, not candidate
timing. The band should not be widened from this observation.

The public run records do not establish a mapping from these workflow attempts
to physical fleet inventory, and neither run names “Sparks” as a runner.
Operational diagnosis belongs to the user/fleet operator: inspect the runner
service and system logs around the disconnect, then repeat the serial control
under the same declared calibration. The repository maintainer owns any harness
or contract repair identified by those diagnostics.
