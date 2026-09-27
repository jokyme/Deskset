#!/bin/bash
# Builds the layer-runtime spike (the H1 experiment: many Core Animation layers instead of one bitmap) and runs its
# experiments, writing raw JSON into results/ (see main.swift for what each step answers).
#
#   scripts/spikes/layer-runtime/run.sh               every step except the interactive click check (about 3 hours)
#   scripts/spikes/layer-runtime/run.sh q1 q5 cost    only these steps:
#                                                     env q5 q1 q4 q6 q7 memtrace offmain glass swap cost wscpu
#                                                     wsmem probes
#   scripts/spikes/layer-runtime/run.sh --rounds N    rounds of the timing steps (default 3; the cost table runs every
#                                                     combination once per round, interleaved)
#   scripts/spikes/layer-runtime/run.sh --wsmem-rounds N  rounds of the WindowServer memory step (default 5)
#   scripts/spikes/layer-runtime/run.sh --only sixty cost   only the cost / wscpu / wsmem runs of one scenario
#   scripts/spikes/layer-runtime/run.sh --round 1 --combo ten-A cost
#                                                     only these rounds (repeatable) and cost / wscpu / memtrace
#                                                     results (repeatable): to repeat runs taken under load
#   scripts/spikes/layer-runtime/run.sh click         the click-through check: a person clicks where it says (90 s)
#   python3 scripts/spikes/layer-runtime/summarize.py medians and spreads of the cost rounds -> results/summary.json
#
# Small borderless windows float at the top left of the main screen while it runs; they let clicks through. The
# pixel steps need screen capture to be allowed for the app running the script: the spike only checks
# (CGPreflightScreenCaptureAccess), it never asks. CPU and timing numbers depend on what else runs: every phase
# records the load average, and numbers taken with a 1-minute load above 8 are marked provisional.
set -euo pipefail

ROUNDS=3
WSMEM_ROUNDS=5
ONLY=""
PICK_ROUNDS=""
PICK_COMBOS=""
STEPS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rounds) ROUNDS="${2:-}"; [[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || { echo "--rounds needs a number" >&2; exit 2; }
                  shift 2 ;;
        --wsmem-rounds) WSMEM_ROUNDS="${2:-}"
                        [[ "$WSMEM_ROUNDS" =~ ^[1-9][0-9]*$ ]] || { echo "--wsmem-rounds needs a number" >&2; exit 2; }
                        shift 2 ;;
        --only) ONLY="${2:-}"; shift 2 ;;
        --round) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "--round needs a number" >&2; exit 2; }
                 PICK_ROUNDS+=" $2 "; shift 2 ;;
        --combo) PICK_COMBOS+=" ${2:-} "; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        env|q1|q4|q5|q6|q7|memtrace|offmain|glass|swap|cost|wscpu|wsmem|probes|click) STEPS+=("$1"); shift ;;
        *) echo "unknown step or option: $1 (see $0 --help)" >&2; exit 2 ;;
    esac
done
[[ ${#STEPS[@]} -gt 0 ]] || STEPS=(env probes q5 q1 q4 q6 q7 offmain glass swap memtrace cost wscpu wsmem)
cd "$(dirname "$0")"

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -swift-version 5 -o "$BUILD/spike" Sources/*.swift 2> "$BUILD/warnings.txt" \
    || { cat "$BUILD/warnings.txt" >&2; exit 1; }
OUT=results
mkdir -p "$OUT"

# Rewrites a result with short numbers and sorted keys (JSONSerialization prints doubles with 17 digits).
tidy() {
    python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
with open(path, "w") as f:
    json.dump(data, f, indent=1, sort_keys=True, ensure_ascii=False)
    f.write("\n")
PY
}

# run NAME ARGS…: one spike process, its result in results/NAME.json.
run() {
    local name="$1"
    shift
    echo "[$(date +%H:%M:%S)] $name: $* (load $(sysctl -n vm.loadavg | tr -d '{}' | xargs))" >&2
    mkdir -p "$(dirname "$OUT/$name.json")"
    if "$BUILD/spike" "$@" --out "$OUT/$name.json"; then
        tidy "$OUT/$name.json"
    else
        echo "[$(date +%H:%M:%S)] $name FAILED (exit $?)" >&2
        FAILED+=("$name")
    fi
}
FAILED=()

# wanted ROUND SCENARIO NAME: whether --round / --combo / --only let this run through.
wanted() {
    [[ -z "$PICK_ROUNDS" || "$PICK_ROUNDS" == *" $1 "* ]] || return 1
    [[ -z "$PICK_COMBOS" || "$PICK_COMBOS" == *" $2-$3 "* ]] || return 1
    [[ -z "$ONLY" || "$2" == "$ONLY" ]]
}

# The cost table: scenario, name, arguments. E and D windows are sRGB (the plan's format for every layer); A is
# today's window (the screen's color space). "EP16" is the partition in today's window color space with RGBA16Float
# layers and the base bitmap in that space (the combination closest to A, see q4); "EPx" draws groups in a scratch
# bitmap at their window position (exact, see q5).
COST=(
    "ten A --mode A"
    "ten E1 --mode E1 --window-cs srgb"
    "ten EP --mode EP --window-cs srgb"
    "ten EPx --mode EP --window-cs srgb --scratch"
    "ten EP16 --mode EP --format rgba16f --window-space-base"
    "ten D1 --mode D1 --window-cs srgb"
    "ten DP --mode DP --window-cs srgb"
    "design A --mode A"
    "design E1 --mode E1 --window-cs srgb"
    "design EP --mode EP --window-cs srgb"
    "design D1 --mode D1 --window-cs srgb"
    "design DP --mode DP --window-cs srgb"
    "sixty A --mode A --frames"
    "sixty E1 --mode E1 --window-cs srgb --frames"
    "sixty EP --mode EP --window-cs srgb --frames"
    "sixty D1 --mode D1 --window-cs srgb --frames"
    "sixty DP --mode DP --window-cs srgb --frames"
)

WSCPU=(
    "ten A --mode A"
    "ten E1 --mode E1 --window-cs srgb"
    "ten EP --mode EP --window-cs srgb"
    "ten D1 --mode D1 --window-cs srgb"
    "ten DP --mode DP --window-cs srgb"
    "sixty A --mode A"
    "sixty E1 --mode E1 --window-cs srgb"
    "sixty EP --mode EP --window-cs srgb"
    "sixty D1 --mode D1 --window-cs srgb"
    "sixty DP --mode DP --window-cs srgb"
)

for step in "${STEPS[@]}"; do
    case "$step" in
        env) run env env ;;
        probes) run probes probes ;;
        q5) run q5 q5 ;;
        q1) run q1 q1 --crops "$OUT/crops" ;;
        q4) for cs in default srgb p3; do run "q4-$cs" q4 --window-cs "$cs"; done ;;
        q6)
            for cs in srgb default; do
                for v in none single shared-cgimage shared-surface crops copies; do
                    run "q6/memory-$v-$cs" q6 --variant "$v" --window-cs "$cs"
                done
            done
            for v in none single shared-cgimage shared-surface crops copies; do
                run "q6/memory-$v-srgb-noise" q6 --variant "$v" --window-cs srgb --noise
            done
            run q6/readback q6 --readback ;;
        q7) run q7 q7 ;;
        memtrace)
            for spec in "A default ten" "A default static" "E1 srgb ten" "EP srgb ten" "D1 srgb ten" "DP srgb ten"; do
                set -- $spec
                [[ -z "$PICK_COMBOS" || "$PICK_COMBOS" == *" $3-$1 "* ]] || continue
                run "memtrace/$3-$1" memtrace --mode "$1" --window-cs "$2" --scenario "$3" --seconds 40 --hide-at 25
            done
            # Today's view drawing: the design skin updated at several rates.
            for interval in 1 0.5 0.1 0.0333 0.0167; do
                [[ -z "$PICK_COMBOS" || "$PICK_COMBOS" == *" design-A-every-${interval}s "* ]] || continue
                run "memtrace/design-A-every-${interval}s" memtrace --mode A --scenario design --interval "$interval" \
                    --seconds 20
            done ;;
        offmain) for r in $(seq 1 "$ROUNDS"); do run "offmain/r$r" offmain; done ;;
        glass)
            for r in $(seq 1 "$ROUNDS"); do run "glass/r$r" glass; done
            run glass/real-glass glass --real-glass ;;
        swap) for r in $(seq 1 "$ROUNDS"); do run "swap/r$r" swap; done ;;
        cost)
            for r in $(seq 1 "$ROUNDS"); do
                for entry in "${COST[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    wanted "$r" "$scenario" "$name" || continue
                    run "cost/$scenario-$name-r$r" cost --scenario "$scenario" "$@"
                done
            done ;;
        wscpu)
            # WindowServer's CPU moves by several % of a core between phases on a busy screen: many short on / off
            # pairs (2 s each, no `top` sampling in between) for the main combinations. The windows stay on screen
            # in the off phases (only their updates stop), so ordering windows out and in does not spill into the
            # phases.
            for r in $(seq 1 "$ROUNDS"); do
                for entry in "${WSCPU[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    wanted "$r" "$scenario" "$name" || continue
                    run "wscpu/$scenario-$name-r$r" cost --scenario "$scenario" --seconds 2 --pairs 10 --settle 5 \
                        --ws-cycles 0 --no-top --off-shown --backdrop "$@"
                done
            done ;;
        wsmem)
            # One opening per process: 20 System widgets, 5 design skins or 5 visualizers at 60 Hz.
            for r in $(seq 1 "$WSMEM_ROUNDS"); do
                for scenario in ten design sixty; do
                    [[ -z "$ONLY" || "$scenario" == "$ONLY" ]] || continue
                    for spec in "A default" "E1 srgb" "EP srgb" "D1 srgb" "DP srgb"; do
                        set -- $spec
                        run "wsmem/$scenario-$1-r$r" wsmem --scenario "$scenario" --mode "$1" --window-cs "$2"
                    done
                done
            done ;;
        click) "$BUILD/spike" click ;;
    esac
done
echo "[$(date +%H:%M:%S)] done (load $(sysctl -n vm.loadavg | tr -d '{}' | xargs))" >&2
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "failed: ${FAILED[*]}" >&2
    exit 1
fi
