#!/bin/bash
# Builds the layer-runtime spike (the H1 experiment: many Core Animation layers instead of one bitmap) and runs its
# experiments, writing raw JSON into results/ (see main.swift for what each step answers).
#
#   scripts/spikes/layer-runtime/run.sh               every step except the interactive click check (about 6 hours)
#   scripts/spikes/layer-runtime/run.sh q1 q5 cost    only these steps:
#                                                     env q5 q1 q4 q6 q7 memtrace offmain glass swap cost wscpu
#                                                     wsmem probes, and the second campaign (with Deskset's own
#                                                     bitmap, B): cost-b wscpu-b wsmem-b memtrace-b cost-c wscpu-c
#                                                     wsmem-c cost-threads, and the corrections (2026-09-28,
#                                                     second half): q1s q5r q5x sysmem cschange wspair cost-d frames60
#                                                     schedpair wspair-billed
#                                                     cschange-person (a person changes the display's color profile)
#                                                     wsfootprint-person (a person types the administrator password
#                                                     once: WindowServer's footprint per way)
#   scripts/spikes/layer-runtime/run.sh --rounds N    rounds of the timing steps (default 3; the cost table runs every
#                                                     combination once per round, interleaved)
#   scripts/spikes/layer-runtime/run.sh --wsmem-rounds N  rounds of the WindowServer memory step (default 5)
#   scripts/spikes/layer-runtime/run.sh --only sixty cost   only the cost / wscpu / wsmem runs of one scenario
#   scripts/spikes/layer-runtime/run.sh --round 1 --combo ten-A cost
#                                                     only these rounds (repeatable) and cost / wscpu / memtrace
#                                                     results (repeatable): to repeat runs taken under load
#   scripts/spikes/layer-runtime/run.sh --wait-load 8 [--wait-max S] cost-d
#                                                     before every timed run (cost-d, frames60, wspair), wait up to
#                                                     S seconds (default 600) for the 1-minute load to drop below 8
#   scripts/spikes/layer-runtime/run.sh --frame-rounds N frames60   rounds of the 60 Hz frame check (default 10)
#   scripts/spikes/layer-runtime/run.sh click         the click-through check: a person clicks where it says (90 s)
#   python3 scripts/spikes/layer-runtime/summarize.py medians and spreads of the cost rounds -> results/summary.json
#
# Small borderless windows float at the bottom right of the main screen while it runs (the top left is left alone);
# they let clicks through. The pixel steps need screen capture to be allowed for the app running the script: the
# spike only checks (CGPreflightScreenCaptureAccess), it never asks. CPU and timing numbers depend on what else
# runs: every phase records the load average, and numbers taken with a 1-minute load above 8 are marked provisional.
set -euo pipefail

ROUNDS=3
WSMEM_ROUNDS=5
WAIT_LOAD=""
WAIT_MAX=600
FRAME_ROUNDS=10
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
        --wait-load) WAIT_LOAD="${2:-}"; shift 2 ;;
        --wait-max) WAIT_MAX="${2:-}"; shift 2 ;;
        --frame-rounds) FRAME_ROUNDS="${2:-}"; shift 2 ;;
        --round) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "--round needs a number" >&2; exit 2; }
                 PICK_ROUNDS+=" $2 "; shift 2 ;;
        --combo) PICK_COMBOS+=" ${2:-} "; shift 2 ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        env|q1|q4|q5|q6|q7|memtrace|offmain|glass|swap|cost|wscpu|wsmem|probes|click|cost-b|wscpu-b|wsmem-b|memtrace-b|cost-c|wscpu-c|wsmem-c|cost-threads|q1s|q5r|q5x|sysmem|cschange|cschange-person|wspair|wspair-billed|schedpair|cost-d|frames60|wsfootprint-person)
            STEPS+=("$1"); shift ;;
        *) echo "unknown step or option: $1 (see $0 --help)" >&2; exit 2 ;;
    esac
done
[[ ${#STEPS[@]} -gt 0 ]] || STEPS=(env probes q5 q1 q4 q6 q7 offmain glass swap memtrace cost wscpu wsmem cost-b wscpu-b
                                  wsmem-b memtrace-b cost-c wscpu-c wsmem-c cost-threads q1s q5r q5x sysmem cschange
                                  wspair cost-d frames60)
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

# waitload: with --wait-load L, waits (up to 10 minutes) until the 1-minute load average is below L.
waitload() {
    [[ -n "$WAIT_LOAD" ]] || return 0
    local waited=0
    while (( waited < WAIT_MAX )); do
        local load
        load="$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')"
        awk -v l="$load" -v m="$WAIT_LOAD" 'BEGIN { exit !(l < m) }' && return 0
        sleep 15
        waited=$((waited + 15))
    done
    echo "[$(date +%H:%M:%S)] load still at or above $WAIT_LOAD after $WAIT_MAX s, running anyway" >&2
}

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

# The second campaign (2026-09-28), after Deskset moved from A to its own bitmap (B): B drawn in full, B with kept
# pictures as Deskset does (Bkept), and the E layers in Deskset's window color space (the screen's, like B): one E
# layer (E1, pixel for pixel B on screen), the partition with its base bitmap in that space (EPw) and drawn through a
# scratch bitmap in that space (EPxw, also pixel for pixel B). A again as the bridge to the first campaign.
COST_B=(
    "ten A --mode A"
    "ten B --mode B"
    "ten Bkept --mode B --kept"
    "ten E1 --mode E1"
    "ten EPw --mode EP --window-space-base"
    "ten EPxw --mode EP --scratch --window-space-base"
    "design A --mode A"
    "design B --mode B"
    "design Bkept --mode B --kept"
    "design E1 --mode E1"
    "design EPw --mode EP --window-space-base"
    "design EPxw --mode EP --scratch --window-space-base"
    "sixty A --mode A --frames"
    "sixty B --mode B --frames"
    "sixty Bkept --mode B --kept --frames"
    "sixty E1 --mode E1 --frames"
    "sixty EPw --mode EP --window-space-base --frames"
    "sixty EPxw --mode EP --scratch --window-space-base --frames"
)
WSCPU_B=(
    "ten A --mode A"
    "ten B --mode B"
    "ten Bkept --mode B --kept"
    "ten E1 --mode E1"
    "ten EPw --mode EP --window-space-base"
    "sixty A --mode A"
    "sixty B --mode B"
    "sixty Bkept --mode B --kept"
    "sixty E1 --mode E1"
    "sixty EPw --mode EP --window-space-base"
)
# WindowServer memory, second campaign: 10 System widgets (two rows at the bottom right), 5 design skins, 5 visualizers.
WSMEM_B=(
    "ten A --mode A --count 10"
    "ten B --mode B --count 10"
    "ten Bkept --mode B --kept --count 10"
    "ten E1 --mode E1 --count 10"
    "ten EPw --mode EP --window-space-base --count 10"
    "ten EPxw --mode EP --scratch --window-space-base --count 10"
    "ten E1srgb --mode E1 --window-cs srgb --count 10"
    "ten EPsrgb --mode EP --window-cs srgb --count 10"
    "ten D1srgb --mode D1 --window-cs srgb --count 10"
    "design A --mode A"
    "design B --mode B"
    "design Bkept --mode B --kept"
    "design E1 --mode E1"
    "design EPw --mode EP --window-space-base"
    "sixty A --mode A"
    "sixty B --mode B"
    "sixty Bkept --mode B --kept"
    "sixty E1 --mode E1"
    "sixty EPw --mode EP --window-space-base"
)

# C: our own bitmaps in the window's color space as the layers' contents (like B's, per layer, from the skin
# thread): one layer (C1), the partition (CPw) and the partition through a scratch bitmap (CPxw). Also B+kept at 60 Hz
# again (its check against a full drawing used to race with the next frame). Written next to the second campaign.
COST_C=(
    "ten C1 --mode D1 --cgimage"
    "ten CPw --mode DP --cgimage --window-space-base"
    "ten CPxw --mode DP --cgimage --window-space-base --scratch"
    "design C1 --mode D1 --cgimage"
    "design CPw --mode DP --cgimage --window-space-base"
    "design CPxw --mode DP --cgimage --window-space-base --scratch"
    "sixty C1 --mode D1 --cgimage --frames"
    "sixty CPw --mode DP --cgimage --window-space-base --frames"
    "sixty CPxw --mode DP --cgimage --window-space-base --scratch --frames"
    "sixty Bkept --mode B --kept --frames"
)
# The skin threads' drawing cost when the 10 widgets update at the same moment on 10 threads (as in every run above)
# vs one after another on one shared thread, and on 10 threads with their updates spread over the second.
COST_THREADS=(
    "ten E1-onethread --mode E1 --one-thread"
    "ten C1-onethread --mode D1 --cgimage --one-thread"
    "ten EPw-onethread --mode EP --window-space-base --one-thread"
    "ten CPw-onethread --mode DP --cgimage --window-space-base --one-thread"
    "ten EPw-stagger --mode EP --window-space-base --stagger"
    "ten E1-stagger --mode E1 --stagger"
)
WSCPU_C=(
    "ten CPw --mode DP --cgimage --window-space-base"
    "sixty C1 --mode D1 --cgimage"
    "sixty CPw --mode DP --cgimage --window-space-base"
)
WSMEM_C=(
    "ten C1 --mode D1 --cgimage --count 10"
    "ten CPw --mode DP --cgimage --window-space-base --count 10"
    "design C1 --mode D1 --cgimage"
    "design CPw --mode DP --cgimage --window-space-base"
    "sixty C1 --mode D1 --cgimage"
    "sixty CPw --mode DP --cgimage --window-space-base"
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

# The corrections (2026-09-28, second half). Memory with a view that sees pixels handed to the window server
# (footprint --vmObjectDirty, SysMem.swift), one window opening per process: 20 System widgets or 12 design skins.
SYSMEM=(
    "ten A --mode A" "ten B --mode B" "ten Bkept --mode B --kept" "ten E1 --mode E1"
    "ten EPw --mode EP --window-space-base" "ten EPxw --mode EP --window-space-base --scratch"
    "ten C1 --mode D1 --cgimage" "ten CPw --mode DP --cgimage --window-space-base"
    "ten CPxw --mode DP --cgimage --window-space-base --scratch"
    "ten D1srgb --mode D1 --window-cs srgb" "ten DPsrgb --mode DP --window-cs srgb"
    "ten E1-onethread --mode E1 --one-thread" "ten EPw-onethread --mode EP --window-space-base --one-thread"
    "ten C1-onethread --mode D1 --cgimage --one-thread"
    "ten CPw-onethread --mode DP --cgimage --window-space-base --one-thread"
    "design A --mode A" "design B --mode B" "design Bkept --mode B --kept" "design E1 --mode E1"
    "design EPw --mode EP --window-space-base" "design EPxw --mode EP --window-space-base --scratch"
    "design C1 --mode D1 --cgimage" "design CPw --mode DP --cgimage --window-space-base"
    "design CPxw --mode DP --cgimage --window-space-base --scratch"
    "design D1srgb --mode D1 --window-cs srgb" "design DPsrgb --mode DP --window-cs srgb"
)
# CPU, one interleaved batch in its own folder (nothing overwritten): the ways the decisions compare, at 60 Hz and
# with 10 widgets, and the scheduling variants (one skin thread, updates spread over the second, coalesced updates),
# all with proc_pid_rusage v6 counters and the GPU's utilization.
COST_D=(
    "sixty A --mode A --frames" "sixty B --mode B --frames" "sixty Bkept --mode B --kept --frames"
    "sixty E1 --mode E1 --frames" "sixty EPw --mode EP --window-space-base --frames"
    "sixty CPw --mode DP --cgimage --window-space-base --frames" "sixty C1 --mode D1 --cgimage --frames"
    "ten A --mode A" "ten Bkept --mode B --kept" "ten E1 --mode E1" "ten EPw --mode EP --window-space-base"
    "ten CPw --mode DP --cgimage --window-space-base" "ten C1 --mode D1 --cgimage"
    "ten E1-onethread --mode E1 --one-thread" "ten EPw-onethread --mode EP --window-space-base --one-thread"
    "ten CPw-onethread --mode DP --cgimage --window-space-base --one-thread"
    "ten EPw-stagger --mode EP --window-space-base --stagger"
    "ten CPw-stagger --mode DP --cgimage --window-space-base --stagger"
    "ten Bkept-stagger --mode B --kept --stagger"
    "ten EPw-onethread-stagger --mode EP --window-space-base --one-thread --stagger"
    "ten EPw-onethread-coalesce --mode EP --window-space-base --one-thread --coalesce"
    "ten CPw-onethread-coalesce --mode DP --cgimage --window-space-base --one-thread --coalesce"
)
# 60 Hz frames on screen, 10 s per round, interleaved.
FRAMES60=(
    "EPw --mode EP --window-space-base" "CPw --mode DP --cgimage --window-space-base" "Bkept --mode B --kept"
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
        cost-b)
            for r in $(seq 1 "$ROUNDS"); do
                for entry in "${COST_B[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    wanted "$r" "$scenario" "$name" || continue
                    run "cost-b/$scenario-$name-r$r" cost --scenario "$scenario" "$@"
                done
            done ;;
        wscpu-b)
            for r in $(seq 1 "$ROUNDS"); do
                for entry in "${WSCPU_B[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    wanted "$r" "$scenario" "$name" || continue
                    run "wscpu-b/$scenario-$name-r$r" cost --scenario "$scenario" --seconds 2 --pairs 10 --settle 5 \
                        --ws-cycles 0 --no-top --off-shown --backdrop "$@"
                done
            done ;;
        wsmem-b)
            for r in $(seq 1 "$WSMEM_ROUNDS"); do
                for entry in "${WSMEM_B[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    wanted "$r" "$scenario" "$name" || continue
                    run "wsmem-b/$scenario-$name-r$r" wsmem --scenario "$scenario" "$@"
                done
            done ;;
        cost-c)
            for r in $(seq 1 "$ROUNDS"); do
                for entry in "${COST_C[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    wanted "$r" "$scenario" "$name" || continue
                    run "cost-b/$scenario-$name-r$r" cost --scenario "$scenario" "$@"
                done
            done ;;
        cost-threads)
            for r in $(seq 1 "$ROUNDS"); do
                for entry in "${COST_THREADS[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    wanted "$r" "$scenario" "$name" || continue
                    run "cost-b/$scenario-$name-r$r" cost --scenario "$scenario" "$@"
                done
            done ;;
        wscpu-c)
            for r in $(seq 1 "$ROUNDS"); do
                for entry in "${WSCPU_C[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    wanted "$r" "$scenario" "$name" || continue
                    run "wscpu-b/$scenario-$name-r$r" cost --scenario "$scenario" --seconds 2 --pairs 10 --settle 5 \
                        --ws-cycles 0 --no-top --off-shown --backdrop "$@"
                done
            done ;;
        wsmem-c)
            for r in $(seq 1 "$WSMEM_ROUNDS"); do
                for entry in "${WSMEM_C[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    wanted "$r" "$scenario" "$name" || continue
                    run "wsmem-b/$scenario-$name-r$r" wsmem --scenario "$scenario" "$@"
                done
            done ;;
        memtrace-b)
            for spec in "ten B" "ten Bkept --kept" "ten E1" "ten EPw --window-space-base" "design B" "design Bkept --kept"; do
                set -- $spec
                scenario="$1" name="$2"
                shift 2
                mode="${name%kept}"
                mode="${mode%w}"
                [[ -z "$PICK_COMBOS" || "$PICK_COMBOS" == *" $scenario-$name "* ]] || continue
                run "memtrace-b/$scenario-$name" memtrace --mode "$mode" --scenario "$scenario" --seconds 40 \
                    --hide-at 25 "$@"
            done ;;
        click) "$BUILD/spike" click ;;
        q1s) run q1-stepped q1 --stepped --crops "$OUT/crops" ;;
        q5r)
            run q5-review-search q5 --review-search
            run q5-review-search-half-point q5 --review-search --grid 0.5 ;;
        q5x)
            # The offline partitions at 1× and 2×, as this Mac's arm64 build and as an x86_64 build (under Rosetta on
            # Apple silicon: CoreGraphics' output depends on the architecture, see ci-probe).
            swiftc -O -swift-version 5 -target x86_64-apple-macos13 -o "$BUILD/spike-x86_64" Sources/*.swift \
                2> "$BUILD/warnings-x86_64.txt" || { cat "$BUILD/warnings-x86_64.txt" >&2; exit 1; }
            for scale in 1 2; do
                run "q5-partitions/arm64-${scale}x" q5 --partitions-only --scale "$scale"
                echo "[$(date +%H:%M:%S)] q5-partitions/x86_64-${scale}x" >&2
                arch -x86_64 "$BUILD/spike-x86_64" q5 --partitions-only --scale "$scale" \
                    --out "$OUT/q5-partitions/x86_64-rosetta-${scale}x.json" && tidy "$OUT/q5-partitions/x86_64-rosetta-${scale}x.json"
            done ;;
        sysmem)
            # The positive control first (8 copies of a 9.77 MB image must show about +78 MB), then the ways.
            for cs in srgb default; do
                for v in none single shared crops copies; do
                    run "sysmem/control-$v-$cs" sysmem --control "$v" --window-cs "$cs" --cycles 3
                done
            done
            for r in $(seq 1 "$ROUNDS"); do
                for entry in "${SYSMEM[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    wanted "$r" "$scenario" "$name" || continue
                    run "sysmem/$scenario-$name-r$r" sysmem --scenario "$scenario" --cycles 1 "$@"
                done
            done ;;
        cschange)
            run cschange/program-no-reaction cschange
            run cschange/program-react cschange --react ;;
        wsfootprint-person)
            # For a person at the Mac (asks for the administrator password once): WindowServer's footprint, which
            # needs root, before, while and after each way's widgets are open (20 System widgets, 12 design skins).
            sudo -v || exit 1
            mkdir -p "$OUT/wsfootprint"
            for r in $(seq 1 "$ROUNDS"); do
                for entry in "${SYSMEM[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    [[ "$name" == *onethread* ]] && continue
                    wanted "$r" "$scenario" "$name" || continue
                    file="$OUT/wsfootprint/$scenario-$name-r$r.txt"
                    echo "[$(date +%H:%M:%S)] wsfootprint $scenario $name r$r" >&2
                    sudo -v
                    { echo "before"; sudo footprint -f bytes --noCategories -p WindowServer; } > "$file" 2>&1
                    "$BUILD/spike" hold --scenario "$scenario" --seconds 45 "$@" &
                    holder=$!
                    sleep 30
                    { echo "open"; sudo footprint -f bytes --noCategories -p WindowServer; } >> "$file" 2>&1
                    wait "$holder"
                    sleep 3
                    { echo "closed"; sudo footprint -f bytes --noCategories -p WindowServer; } >> "$file" 2>&1
                done
            done ;;
        cschange-person)
            # For a person at the Mac: change the display's color profile in System Settings → Displays while each
            # run waits (90 s), and back again.
            run cschange/person-no-reaction cschange --wait 90
            run cschange/person-react cschange --wait 90 --react ;;
        wspair)
            for r in $(seq 1 "$ROUNDS"); do
                wanted "$r" sixty wspair || continue
                waitload
                run "wspair/r$r" wspair --cycles 10 --seed "$r"
            done ;;
        schedpair)
            for r in $(seq 1 "$ROUNDS"); do
                wanted "$r" ten schedpair || continue
                waitload
                run "schedpair/EPw-r$r" schedpair --mode EPw --seed "$r"
            done ;;
        wspair-billed)
            # Whether WindowServer's lower readings for the main-thread ways are CPU time billed to this process.
            waitload
            run "wspair-billed/r1" wspair --sets A,B,Bkept,E1,EPw,CPw --cycles 8 --seed 11 ;;
        cost-d)
            for r in $(seq 1 "$ROUNDS"); do
                for entry in "${COST_D[@]}"; do
                    set -- $entry
                    scenario="$1" name="$2"
                    shift 2
                    wanted "$r" "$scenario" "$name" || continue
                    waitload
                    run "cost-d/$scenario-$name-r$r" cost --scenario "$scenario" --settle 10 --ws-cycles 0 --gpu "$@"
                done
            done ;;
        frames60)
            for r in $(seq 1 "$FRAME_ROUNDS"); do
                for entry in "${FRAMES60[@]}"; do
                    set -- $entry
                    name="$1"
                    shift
                    wanted "$r" sixty "$name" || continue
                    waitload
                    run "frames60/$name-r$r" cost --scenario sixty --settle 3 --pairs 1 --seconds 2 --ws-cycles 0 \
                        --no-top --frames --frames-seconds 10 "$@"
                done
            done ;;
    esac
done
echo "[$(date +%H:%M:%S)] done (load $(sysctl -n vm.loadavg | tr -d '{}' | xargs))" >&2
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "failed: ${FAILED[*]}" >&2
    exit 1
fi
