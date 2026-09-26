#!/bin/bash
# Builds and runs the skin-threading spike (see SkinThreadingSpike.swift and docs/skin-threading.md §13).
#
#   scripts/spikes/skin-threading/run.sh             every mode in the main-block and slow-skin scenarios, then what
#                                                    each mode costs with nothing stalling (steady, 3 rounds)
#   scripts/spikes/skin-threading/run.sh --rounds N  N rounds of the cost table (modes interleaved in every round)
#   scripts/spikes/skin-threading/run.sh --cost      only the cost table
#
# Two small windows float at the top left of the main screen while it runs (a few minutes); they let clicks
# through. The on-screen columns need screen capture to be allowed for the app running the script (the spike only
# checks, it never asks); without it they read n/a. WindowServer's CPU time counts everything on the screen: run it
# on a quiet screen and compare modes within a round, against the idle row.
set -euo pipefail

ROUNDS=3
STALLS=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rounds) ROUNDS="${2:-}"; [[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || { echo "--rounds needs a number" >&2; exit 2; }
                  shift 2 ;;
        --cost) STALLS=0; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see $0 --help)" >&2; exit 2 ;;
    esac
done
cd "$(dirname "$0")"

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -swift-version 5 -o "$BUILD/spike" SkinThreadingSpike.swift
# mode:executor
RUNS=(main:queue hop:queue commit:queue surface:queue layer:queue layer:thread)

echo "macOS $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores"

if [[ $STALLS == 1 ]]; then
    echo
    echo "## Stalls"
    echo
    header=""
    for scenario in main-block slow-skin; do
        for run in "${RUNS[@]}"; do
            "$BUILD/spike" --mode "${run%%:*}" --executor "${run##*:}" --scenario "$scenario" $header
            header="--no-header"
        done
    done
fi

# WindowServer's CPU time in seconds (ps prints [hours:]minutes:seconds).
window_server_seconds() {
    ps -o time= -p "$(pgrep -x WindowServer | head -1)" \
        | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}

echo
echo "## Cost with nothing stalling (steady, no screen capture)"
echo
echo "| mode | round | draw p50 (µs) | commit p50 / p99 (µs) | CPU, spike / WindowServer (% of a core) |"
echo "|---|---|---|---|---|"
rows="$BUILD/rows"
: > "$rows"
for round in $(seq 1 "$ROUNDS"); do
    before=$(window_server_seconds)
    sleep 5
    after=$(window_server_seconds)
    awk -v r="$round" -v a="$before" -v b="$after" \
        'BEGIN { printf "0 | idle, no windows | %s | – | – / – | – / %.0f |\n", r, (b - a) / 5 * 100 }' >> "$rows"
    for i in "${!RUNS[@]}"; do
        run="${RUNS[$i]}"
        "$BUILD/spike" --mode "${run%%:*}" --executor "${run##*:}" --scenario steady --no-capture --no-header \
            | awk -F'|' -v order="$((i + 1))" -v r="$round" \
                '/Skin A/ { print order " |" $2 "| " r " |" $9 "|" $10 "|" $11 "|" }' >> "$rows"
    done
done
sort -s -n -k1,1 "$rows" | cut -d' ' -f2-
