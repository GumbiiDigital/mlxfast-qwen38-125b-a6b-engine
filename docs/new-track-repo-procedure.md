# New-track repo & branch procedure

How a new model track is stood up across the engine and bench repos. This is the
procedure this repo itself was created by; it applies to every future track family.
Ruled 2026-08-22 (engine fork = new repo). Ruled 2026-09-07 (benchd is published from `main`).

## 1. Engine fork = a NEW repo per track family

- Create a fresh org repo with a **decoder-neutral** name: `mlxfast-{model}{ver}-{params}-engine`
  (no spec-decoder kind — mtp/dflash/dspark — in repo, track, or branch names; model-facts inside
  code/config are fine).
- **Fresh-seed, do not fork-push.** The org ruleset requires verified commit signatures and the
  source engine's early history contains unsigned commits, so a history-carrying push is rejected.
  Seed one signed commit whose tree is identical to the source engine's `main` tip, and name the
  source commit in the seed message. History stays in the source repo.
  - Precedent: this repo's `main` root `1c50f3f6` = tree-identical seed of
    `mlxfast-qwen-38-27b-mtp-engine @ 31dee355`.
- The repo is created **private**; the visibility flip to internal is org-owner-gated.

## 2. Bench side = the `main` branch

benchd is published from `main`. There is no bench release branch for a track
(ruled 2026-09-07). The engine pins a benchd commit, and `main` is the channel
every track resolves. The track id still names the leaderboard namespace, the
runner label and the R2 key prefix. It no longer names a bench branch.

## 3. Engine ↔ bench binding: the submodule pin

- benchd rides as a **SHA-pinned submodule**: the gitlink IS the pin. `.gitmodules` carries a
  `branch` hint naming `main` (never a SHA in the comment — it goes stale).
- Verify the pin and its branch containment:

  ```sh
  git ls-tree HEAD benchd
  git -C benchd branch -r --contains $(git rev-parse HEAD:benchd)   # must list main
  ```

  The containment check must use a **remote-tracking** branch (`-r`); local branches inside
  `.git/modules/benchd` prove nothing.
- Gitlink advances are **deliberate two-verdict PRs**, never `submodule update --remote` drift.

## 4. Re-baseline discipline

A seeded engine inherits the **source track's** gitlink, which may be far behind the bench repo's
current `main`. Before any new measurement logic lands:

1. Advance this repo's gitlink onto the bench repo's current `main`, **in its own reviewed PR**
   (the scoring stack is load-bearing; the bump is a pinned identity).
2. Only then build track measurement features on top.

## 5. Goldens for the new track

- Authored **on the track's designated benchmark hardware**, never a development laptop
  (greedy-decode argmax near-ties differ across silicon).
- **A≡B double-generated** — two independent generations, byte-identical asserted **before**
  pinning. Non-identical = STOP; it is also the determinism tripwire for the track's pinned
  runtime configuration.
- Identity = **sha256 + bytes**, never name/path/location. The gates-bound golden pin is the
  oracle-carrying file's hash; the oracle is mandatory on the timed path.
- Uploaded to R2 under `{track_id}/{sha256}.json` (content-addressed, name-free), append-only,
  per-instance authorization, operator-workstation credentials only, GET + sha + bytes
  round-trip verified after upload.
- Upload happens **once the track is stable and ready for testing** — after the engine port and
  measurement stack are proven on-box, before the first scored window.
  `official_scoring_enabled` flips true LAST, in its own PR, after one clean scored window.

## 6. Stamping with tools/new-track.sh

The seed from section 1 still carries the SOURCE track's identity in every file.
`tools/new-track.sh` replaces that identity in one pass. Run it from the root of
the fresh seed, on a clean worktree:

```sh
tools/new-track.sh --track-id <{model}{ver}-{params}-{platform}-v{N}> \
                   --fork-sha <40 hex> \
                   --checkpoint <hf_repo>@<40 hex revision> \
                   [--bench-commit <40 hex>] \
                   [--os macOS|Linux]
```

What it changes:

- `benchmark.json`: `name`, `trackId`, `staticReviewTrackId`,
  `leaderboard.namespace` and `contractPath`. The commands, the editable paths,
  the byte budget and the scoring constants stay as they are.
- The contract fixture: a copy of the current one under the new name, with the
  new track id, the fork revision, `official_scoring_enabled: false`, an empty
  timed pool, an empty live golden, and the pending-organizer sentinel. The old
  fixture is deleted.
- The checkpoint file list: rewritten from the Hugging Face tree of
  `--checkpoint`. LFS entries use the LFS object's own sha256. A file the tree
  publishes no sha256 for is refused by name.
- `tools/fetch-benchd.sh`: `BENCHD_BRANCH` defaults to `main`.
- `.github/workflows/benchmark.yml`: the `runs-on` list becomes
  `[self-hosted, <os>, <track id>]`. The default OS is macOS for `mlx` and Linux
  for `cuda`.
- `Vendor/mlx-swift-lm`: the gitlink moves to the fork sha. The `.gitmodules`
  url does not change.
- Every other tracked text file: the old track id and the old fixture name become
  the new ones. The port notes, the manifest linter, this procedure and the two
  new-track scripts keep the old names, because they record the source track.
- The goldens: nothing to do. A track's goldens are recorded on its own box,
  published to R2 under `correctness_prompts/<track id>/` and staged on the
  ranked box as `MLXFAST_QWEN38_GOLDEN_DIR`. They are never in git, so the new
  track carries none of the source track's and there is no directory to rename.

The script never commits. Review the diff, then commit.

The model facts do not change. The layer counts, the attention geometry, the
expert counts and the n-gram shape in the new fixture are the source model's.
The script prints this at the end. Re-author them before any measurement.

`tools/test-new-track.sh` proves all of the above offline, in CI.
