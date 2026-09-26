#!/bin/bash
# Runs both self-test programs with Apple's Main Thread Checker loaded and lists what it reports: AppKit (and the other
# UI frameworks it knows) called off the main thread. A guard rail for moving skins off the main thread
# (docs/skin-threading.md). ThreadSanitizer is not an option yet: on macOS 26.5 with Xcode 26.2 its runtime crashes at
# startup.
#
#   scripts/check-main-thread.sh              every suite
#   scripts/check-main-thread.sh Executor     a filter, passed to both programs (a suite prefix or part of a name)
#
# The checker ships with Xcode (not with the Command Line Tools) and works outside it: the script finds it with
# `xcode-select -p`. It only reports; the runs go on. Each program gets a private TMPDIR, and its full output is kept
# in the folder printed at the end. Exit status: 0 when both programs pass and nothing was reported, 1 otherwise,
# 2 when the checker cannot be found.
set -o pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
CHECKER="$DEVELOPER_DIR_PATH/usr/lib/libMainThreadChecker.dylib"
if [[ -z "$DEVELOPER_DIR_PATH" || ! -f "$CHECKER" ]]; then
    echo "Main Thread Checker not found at $CHECKER." >&2
    echo "It comes with Xcode: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 2
fi

swift build || exit 1

LOGS="$(mktemp -d "${TMPDIR:-/tmp}/deskset-main-thread.XXXXXX")"
STATUS=0

# run NAME COMMAND...: runs a self-test program with the checker and summarizes its reports.
run() {
    local name="$1"
    shift
    local log="$LOGS/$name.log"
    local tmp
    tmp="$(mktemp -d "$LOGS/$name-tmp.XXXXXX")"
    echo "== $name: $*"
    TMPDIR="$tmp/" DYLD_INSERT_LIBRARIES="$CHECKER" "$@" > "$log" 2>&1
    local result=$?
    rm -rf "$tmp"
    echo "   $(grep -E '^(All [0-9]+ checks passed|[0-9]+ FAILED)' "$log" | tail -n 1)"
    if [[ $result -ne 0 ]]; then
        STATUS=1
        echo "   the self-tests failed (exit status $result)"
    fi
    local reports
    reports="$(grep -c '^Main Thread Checker:' "$log")"
    if [[ "$reports" -gt 0 ]]; then
        STATUS=1
        echo "   $reports report(s) of UI API called off the main thread (count, API):"
        grep '^Main Thread Checker:' "$log" | sed 's/^Main Thread Checker: UI API called on a background thread: //' \
            | sort | uniq -c | sort -rn | sed 's/^/   /'
        echo "   (backtraces in $log)"
    else
        echo "   Main Thread Checker: nothing reported"
    fi
}

run core .build/debug/DesksetSelfTest "$@"
run app .build/debug/Deskset -AppleShowScrollBars Always --self-test "$@"
echo "Full output: $LOGS"
exit $STATUS
