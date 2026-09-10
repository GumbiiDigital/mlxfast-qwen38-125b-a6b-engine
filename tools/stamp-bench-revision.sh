#!/bin/sh
# Stamp the git revision of the checkout being compiled into a generated Swift
# source, consumed by this repository's `bench-worker` target.
#
# A MIRROR of the pinned fork's scripts/stamp-bench-revision.sh (449f2d01).
# The fork stamps ITS bench-worker target; this repository builds its own,
# which registers the editable Runner in Runner/, and a plugin inside a pinned
# dependency cannot be reused from here. Same contract, same output shape.
#
# Run as a SwiftPM prebuild command (Plugins/TrackBenchRevisionStamp), so the value
# baked into the executable is the revision that *produced* it, not whatever
# the checkout moved to afterwards.
#
# usage: stamp-bench-revision.sh <package-root> <output.swift>
set -eu

root="$1"
out="$2"

rev="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)"
if [ -z "$rev" ]; then
    # No git, no repository, or a source archive: `unknown` is honest. Never
    # substitute a plausible-looking value here.
    rev="unknown"
elif [ -n "$(git -C "$root" status --porcelain -uall 2>/dev/null)" ]; then
    # Tracked OR untracked changes: the build does not correspond to any
    # commit. -uall rather than -uno because the TrackRunner target declares
    # `path:` without `sources:`, so an UNTRACKED .swift under Runner/ is
    # compiled in and would otherwise stamp clean. Ignored paths (weights/,
    # benchd-bin/, .build*) are not listed by `git status`, so a normal run
    # tree does not stamp dirty.
    rev="$rev-dirty"
fi

mkdir -p "$(dirname "$out")"
tmp="$out.tmp"
cat >"$tmp" <<SWIFT
// Generated at build time by Plugins/TrackBenchRevisionStamp — do not edit, and do
// not check in. See tools/stamp-bench-revision.sh.
enum BenchBuildRevision {
    static let value = "$rev"
}
SWIFT

# Rewrite only on change, so an unchanged revision does not invalidate the
# compiled module on every build.
if [ ! -f "$out" ] || ! cmp -s "$tmp" "$out"; then
    mv "$tmp" "$out"
else
    rm -f "$tmp"
fi
