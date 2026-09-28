#!/bin/bash
# Builds and runs the CARenderer probe (question 8 of the H1 experiment: can the CI runners composite Core Animation
# layer trees offscreen, are the pixels the same as on a Mac at a desk, how long does a render take). See main.swift.
# Used as it is by .github/workflows/h1-probe.yml.
#
#   scripts/spikes/layer-runtime/ci-probe/run.sh [--arch arm64|x86_64] [probe options]
#
# Probe options: --out DIR (probe.json and every scene's pixels), --reference DIR (compare with an earlier --out),
# --rounds N (timing rounds, default 3), --renders N (renders per round, default 20), --timeout SECONDS (default 300).
# --arch builds for that architecture (x86_64 on Apple silicon runs under Rosetta). Exit status is the probe's:
# 0 ran, 4 no Metal device, 3 timed out, 1 error.
set -euo pipefail

ARCH="$(uname -m)"
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { echo "--arch must be arm64 or x86_64" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -swift-version 5 -target "$ARCH-apple-macos13" -o "$BUILD/probe" "$HERE/main.swift"
status=0
"$BUILD/probe" ${ARGS[@]+"${ARGS[@]}"} || status=$?
exit "$status"
