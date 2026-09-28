#!/usr/bin/env python3
"""Summarizes the repeated runs in results/ (cost table, off-main commits, glass, window swap): median, minimum and
maximum over the rounds, and whether any phase ran with a 1-minute load average above 8 (provisional).

    python3 scripts/spikes/layer-runtime/summarize.py      writes results/summary.json and prints Markdown tables
"""
import glob
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")
LOAD_LIMIT = 8.0


def load(path):
    with open(path) as f:
        return json.load(f)


def stats(values):
    values = [v for v in values if isinstance(v, (int, float))]
    if not values:
        return None
    out = {"median": round(statistics.median(values), 3), "min": round(min(values), 3),
           "max": round(max(values), 3), "n": len(values)}
    if len(values) >= 2:
        out["mean"] = round(statistics.mean(values), 3)
        out["standardError"] = round(statistics.stdev(values) / len(values) ** 0.5, 3)
    return out


def dig(d, path):
    for key in path.split("."):
        if not isinstance(d, dict) or key not in d:
            return None
        d = d[key]
    return d


def phase_loads(run):
    loads = []
    for p in run.get("phases", []):
        loads += [p.get("loadAverageBefore", [0])[0], p.get("loadAverageAfter", [0])[0]]
    return loads


def cost(directory="cost"):
    groups = {}
    for path in sorted(glob.glob(os.path.join(RESULTS, directory, "*.json"))):
        name = os.path.basename(path)[:-5]
        combo, _, _ = name.rpartition("-r")
        groups.setdefault(combo, []).append(load(path))
    out = {}
    per_round = [
        ("footprintIncreaseMB", "memory.footprintIncreaseMB"),
        ("footprintIncreasePerWidgetMB", "memory.footprintIncreasePerWidgetMB"),
        ("ownedGraphicsAfterSettleMB", "memory.footprintCategoriesAfterSettleMB.Owned physical footprint (unmapped) (graphics)"),
        ("coreAnimationAfterSettleMB", "memory.footprintCategoriesAfterSettleMB.CoreAnimation"),
        ("ioSurfaceAfterSettleMB", "memory.footprintCategoriesAfterSettleMB.IOSurface"),
        ("cgRasterAfterSettleMB", "memory.footprintCategoriesAfterSettleMB.CG raster data"),
        ("freeGBAfterSettle", "memory.memoryPressureAfterSettle.freeGB"),
        ("footprintIncreaseAtEndPerWidgetMB", "memory.footprintIncreaseAtEndPerWidgetMB"),
        ("layerBitmapsPerWidgetMB", "memory.layerBitmapsPerWidgetMB"),
        ("ownedBitmapsPerWidgetMB", "memory.ownedBitmapsPerWidgetMB"),
        ("oneBitmapOfTheWindowMB", "memory.oneBitmapOfTheWindowMB"),
        ("partitionMinimumMB", "memory.partitionMinimumMB"),
        ("windowServerIncreaseMB", "memory.windowServerIncreaseMB"),
        ("windowServerIncreasePerWidgetMB", "memory.windowServerIncreasePerWidgetMB"),
        ("processPercentOfOneCore", "cpu.processPercentOfOneCore"),
        ("interruptWakeupsPerSecond", "cpu.interruptWakeupsPerSecond"),
        ("idleWakeupsPerSecond", "cpu.idleWakeupsPerSecond"),
        ("framesPerSecond", "cpu.framesPerSecond"),
        ("windowServerPercentOfOneCore", "cpu.windowServerPercentOfOneCore"),
        ("windowServerPercentOfOneCoreOff", "cpu.windowServerPercentOfOneCoreOff"),
        ("windowServerPercentOfOneCoreIncrease", "cpu.windowServerPercentOfOneCoreIncrease"),
        ("windowServerIdleWakeupsPerSecondIncrease", "cpu.windowServerIdleWakeupsPerSecondIncrease"),
        ("frameCostP50us", "frameCost.p50us"),
        ("frameCostP99us", "frameCost.p99us"),
        ("commitCostP50us", "frameCost.commitP50us"),
        ("commitCostP99us", "frameCost.commitP99us"),
        ("openAllMs", "openAllMs"),
        ("commitIntervalP50ms", "frames.intervalP50ms"),
        ("commitIntervalP99ms", "frames.intervalP99ms"),
        ("commitIntervalMaxMs", "frames.intervalMaxMs"),
        ("onScreenDistinctFrames", "onScreen.distinctFramesSeen"),
        ("onScreenFramesCommitted", "onScreen.framesCommitted"),
        ("onScreenLongestSameFrameMs", "onScreen.longestSameFrameMs"),
        ("onScreenFrameChangeP50ms", "onScreen.frameChangeIntervalP50ms"),
        ("onScreenFrameChangeP99ms", "onScreen.frameChangeIntervalP99ms"),
        ("onScreenUnreadable", "onScreen.unreadable"),
        ("onScreenSamplesPerSecond", "onScreen.samplesPerSecond"),
        ("windowServerIdleWakeupsPerSecondIncrease", "cpu.windowServerIdleWakeupsPerSecondIncrease"),
        ("keptPicturesCopied", "keptPicturesLastFrame.picturesCopied"),
        ("keptElementsDrawn", "keptPicturesLastFrame.elementsDrawn"),
        ("keptVsFullMaxChannelDiff", "keptPicturesVsFullDrawing.maxChannelDiff"),
        ("keptVsFullDifferingPercent", "keptPicturesVsFullDrawing.differingPercent"),
    ]
    for combo, runs in sorted(groups.items()):
        entry = {"rounds": len(runs), "config": runs[0].get("config"), "widgets": runs[0].get("widgets")}
        loads = [l for run in runs for l in phase_loads(run)]
        entry["loadAverage1mMax"] = max(loads) if loads else None
        entry["provisional"] = bool(loads) and max(loads) > LOAD_LIMIT
        entry["provisionalRounds"] = sum(1 for run in runs if phase_loads(run) and max(phase_loads(run)) > LOAD_LIMIT)
        entry["memoryPressureLevels"] = sorted({dig(run, "memory.memoryPressureAfterSettle.pressureLevel")
                                                for run in runs} - {None})
        for key, path in per_round:
            s = stats([dig(run, path) for run in runs])
            if s:
                entry[key] = s
        # WindowServer CPU per on / off pair (all rounds): the noise is in the pairs.
        pairs = []
        for run in runs:
            ph = run.get("phases", [])
            for on, off in zip(ph[0::2], ph[1::2]):
                a, b = on.get("windowServerPercentOfOneCore"), off.get("windowServerPercentOfOneCore")
                if a is not None and b is not None:
                    pairs.append(a - b)
        if pairs:
            entry["windowServerIncreasePerPair"] = stats(pairs)
        entry["windowServerOpenStepsMB"] = [v for run in runs for v in dig(run, "memory.windowServerOpenStepsMB") or []]
        s = stats(entry["windowServerOpenStepsMB"])
        if s:
            entry["windowServerOpenStepAllCyclesMB"] = s
        entry["windowServerCloseStepsMB"] = [v for run in runs
                                             for v in dig(run, "memory.windowServerCloseStepsMB") or []]
        out[combo] = entry
    return out


def wsmem(directory="wsmem"):
    """One opening per process. A round is clean when WindowServer's footprint went back to where it started after the
    windows closed (the spike's windowServerBackToStart): the medians of the WindowServer steps use clean rounds only
    (all rounds are listed too)."""
    groups = {}
    for path in sorted(glob.glob(os.path.join(RESULTS, directory, "*.json"))):
        name = os.path.basename(path)[:-5]
        combo, _, _ = name.rpartition("-r")
        groups.setdefault(combo, []).append(load(path))
    out = {}
    for combo, runs in sorted(groups.items()):
        clean = [run for run in runs if run.get("windowServerBackToStart")]
        e = {"rounds": len(runs), "cleanRounds": len(clean), "config": runs[0].get("config"),
             "scenario": runs[0].get("scenario"), "widgets": runs[0].get("widgets"),
             "oneBitmapOfTheWindowMB": runs[0].get("oneBitmapOfTheWindowMB")}
        for key in ("windowServerOpenStepMB", "windowServerOpenStepPerWidgetMB", "windowServerCloseStepMB"):
            st = stats([run.get(key) for run in clean])
            if st:
                e[key + "Clean"] = st
        for key in ("windowServerOpenStepMB", "windowServerOpenStepPerWidgetMB", "windowServerBeforeMB",
                    "windowServerResidentOpenStepMB", "gpuInUseOpenStepMB", "gpuInUseOpenStepPerWidgetMB",
                    "gpuInUseCloseStepMB", "footprintIncreasePerWidgetMB", "layerBitmapsPerWidgetMB"):
            st = stats([run.get(key) for run in runs])
            if st:
                e[key] = st
        e["values"] = [run.get("windowServerOpenStepMB") for run in runs]
        e["closeValues"] = [run.get("windowServerCloseStepMB") for run in runs]
        e["gpuValues"] = [run.get("gpuInUseOpenStepMB") for run in runs]
        e["memoryPressureLevels"] = sorted({dig(run, "memoryPressure.pressureLevel") for run in runs} - {None})
        loads = [run.get("loadAverageAtStart", [None])[0] for run in runs]
        e["loadAverage1mAtStartMax"] = max([l for l in loads if l is not None], default=None)
        out[combo] = e
    return out


def rounds(step):
    return [load(p) for p in sorted(glob.glob(os.path.join(RESULTS, step, "r[0-9]*.json")))]


def keyed_stats(runs, fields):
    out = {}
    keys = sorted({k for run in runs for k, v in run.items() if isinstance(v, dict)})
    for k in keys:
        e = {}
        for f in fields:
            s = stats([run.get(k, {}).get(f) for run in runs])
            if s:
                e[f] = s
        if e:
            out[k] = e
    loads = [l for run in runs for l in run.get("loadAverageAtEnd", [])[:1]]
    return out, (max(loads) if loads else None)


def memtrace(directory):
    """Footprint traces: the increase after 20 s and at the end of the shown part, and after closing."""
    out = {}
    for path in sorted(glob.glob(os.path.join(RESULTS, directory, "*.json"))):
        run = load(path)
        trace = run.get("increaseEverySecondMB", [])
        hide = run.get("hideAt", -1)
        out[os.path.basename(path)[:-5]] = {
            "config": run.get("config"), "widgets": run.get("widgets"), "intervalMs": run.get("intervalMs"),
            "after5sMB": trace[4] if len(trace) > 4 else None, "after20sMB": trace[19] if len(trace) > 19 else None,
            "beforeHidingMB": trace[hide - 1] if 0 < hide <= len(trace) else None,
            "whileHiddenMB": trace[hide + 3] if 0 < hide and hide + 3 < len(trace) else None,
            "atEndMB": trace[-1] if trace else None, "afterCloseMB": run.get("increaseAfterCloseMB")}
    return out


def main():
    summary = {"cost": cost(), "wscpu": cost("wscpu"), "wsmem": wsmem(), "costB": cost("cost-b"),
               "wscpuB": cost("wscpu-b"), "wsmemB": wsmem("wsmem-b"), "memtrace": memtrace("memtrace"),
               "memtraceB": memtrace("memtrace-b")}
    off, load_max = keyed_stats(rounds("offmain"), [
        "framesCommitted", "distinctFramesSeen", "tornSamples(codeA != codeB)", "unreadable", "samples",
        "longestSameFrameMs", "framesCommittedDuringStalls", "distinctFramesSeenDuringStalls", "layers"])
    summary["offmain"] = {"loadAverage1mAtEndMax": load_max, "byConfig": off}
    glass, load_max = keyed_stats(rounds("glass"), [
        "frames", "appliedByMain", "reclaimedBySkin", "mainApplyLatencyP50ms", "mainApplyLatencyP99ms",
        "mainApplyLatencyMaxms", "samples", "samplesWithGlassVisibleBesideElement", "maxVisibleGlassWidthPt"])
    summary["glass"] = {"loadAverage1mAtEndMax": load_max, "byScenario": glass}
    swap, load_max = keyed_stats(rounds("swap"), ["swaps", "samples", "blank", "doubled", "ok", "captureFailed",
                                                  "swapMsP50"])
    summary["swap"] = {"loadAverage1mAtEndMax": load_max, "byVariant": swap}
    with open(os.path.join(RESULTS, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1, sort_keys=True)
        f.write("\n")

    def m(e, key, digits=2):
        s = e.get(key)
        if not s:
            return "–"
        if s["n"] == 1 or s["min"] == s["max"]:
            return f"{s['median']:.{digits}f}"
        return f"{s['median']:.{digits}f} ({s['min']:.{digits}f}–{s['max']:.{digits}f})"

    for suffix, title in (("", "first campaign"), ("B", "second campaign, with B")):
        print_tables(summary, suffix, title, m)
    for name in ("memtrace", "memtraceB"):
        print(f"\n## {name}\n")
        for k, e in summary[name].items():
            print(f"- {k}: " + ", ".join(f"{f} {v}" for f, v in e.items()))
    for step in ("offmain", "glass", "swap"):
        block = summary[step]
        inner = next(v for k, v in block.items() if k.startswith("by"))
        print(f"\n## {step} (load max at end {block['loadAverage1mAtEndMax']})\n")
        for k, e in inner.items():
            print(f"- {k}: " + ", ".join(f"{f} {m(e, f, 1)}" for f in e))


def print_tables(summary, suffix, title, m):
    print(f"## Cost table, {title} (median (min–max) over rounds)\n")
    print("| combination | rounds | load max | process MB (all widgets) | process MB/widget | layer bitmaps MB/widget "
          "| WS open step MB | process CPU % | WS CPU on / off % | WS increase per pair % | wakeups/s (intr / idle) "
          "| frame cost p50 µs | commit p50 µs |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for combo, e in summary["cost" + suffix].items():
        flag = " (provisional)" if e["provisional"] else ""
        print(f"| {combo}{flag} | {e['rounds']} | {e['loadAverage1mMax']} | {m(e, 'footprintIncreaseMB', 1)} "
              f"| {m(e, 'footprintIncreasePerWidgetMB')} "
              f"| {m(e, 'layerBitmapsPerWidgetMB')} | {m(e, 'windowServerOpenStepAllCyclesMB', 1)} "
              f"| {m(e, 'processPercentOfOneCore')} "
              f"| {m(e, 'windowServerPercentOfOneCore', 1)} / {m(e, 'windowServerPercentOfOneCoreOff', 1)} "
              f"| {m(e, 'windowServerIncreasePerPair', 1)} "
              f"| {m(e, 'interruptWakeupsPerSecond', 1)} / {m(e, 'idleWakeupsPerSecond', 1)} "
              f"| {m(e, 'frameCostP50us', 0)} | {m(e, 'commitCostP50us', 0)} |")
    print(f"\n## WindowServer CPU, many short on / off pairs, {title}\n")
    print("| combination | rounds | load max | process CPU % | WS CPU on / off % | WS increase per pair % | pairs |")
    print("|---|---|---|---|---|---|---|")
    for combo, e in summary["wscpu" + suffix].items():
        flag = " (provisional)" if e["provisional"] else ""
        pairs = e.get("windowServerIncreasePerPair", {}).get("n", 0)
        print(f"| {combo}{flag} | {e['rounds']} | {e['loadAverage1mMax']} | {m(e, 'processPercentOfOneCore')} "
              f"| {m(e, 'windowServerPercentOfOneCore', 1)} / {m(e, 'windowServerPercentOfOneCoreOff', 1)} "
              f"| {m(e, 'windowServerIncreasePerPair', 2)} (mean {e.get('windowServerIncreasePerPair', {}).get('mean')} "
              f"± {e.get('windowServerIncreasePerPair', {}).get('standardError')}) | {pairs} |")
    print(f"\n## WindowServer memory, several widgets opened once per process, {title}\n")
    print("| scenario | mode | widgets | clean / rounds | WS open step MB, clean rounds (all rounds) | per widget MB (clean) "
          "| close steps MB | GPU in use: open step MB per widget | process MB/widget | layer bitmaps MB/widget |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for combo, e in summary["wsmem" + suffix].items():
        print(f"| {e['scenario']} | {e['config']} | {e['widgets']} | {e['cleanRounds']} / {e['rounds']} "
              f"| {m(e, 'windowServerOpenStepMBClean', 1)} ({e['values']}) "
              f"| {m(e, 'windowServerOpenStepPerWidgetMBClean')} | {e['closeValues']} "
              f"| {m(e, 'gpuInUseOpenStepPerWidgetMB')} | {m(e, 'footprintIncreasePerWidgetMB')} "
              f"| {m(e, 'layerBitmapsPerWidgetMB')} |")
    print(f"\n## 60 Hz, {title}\n")
    print("| combination | commit interval p50 / p99 / max ms | on screen: distinct frames / committed "
          "| longest same frame ms | frame change p99 ms |")
    print("|---|---|---|---|---|")
    for combo, e in summary["cost" + suffix].items():
        if not combo.startswith("sixty"):
            continue
        print(f"| {combo} | {m(e, 'commitIntervalP50ms')} / {m(e, 'commitIntervalP99ms')} / "
              f"{m(e, 'commitIntervalMaxMs')} | {m(e, 'onScreenDistinctFrames', 0)} / "
              f"{m(e, 'onScreenFramesCommitted', 0)} | {m(e, 'onScreenLongestSameFrameMs', 1)} "
              f"| {m(e, 'onScreenFrameChangeP99ms', 1)} |")
    print(f"\n## Opening, kept pictures, WindowServer idle wakeups, {title}\n")
    print("| combination | open all ms | WS idle wakeups/s increase | kept: pictures copied / elements drawn (last frame) "
          "| kept vs full drawing: max / % |")
    print("|---|---|---|---|---|")
    for combo, e in summary["cost" + suffix].items():
        print(f"| {combo} | {m(e, 'openAllMs', 1)} | {m(e, 'windowServerIdleWakeupsPerSecondIncrease', 1)} "
              f"| {m(e, 'keptPicturesCopied', 0)} / {m(e, 'keptElementsDrawn', 0)} "
              f"| {m(e, 'keptVsFullMaxChannelDiff', 0)} / {m(e, 'keptVsFullDifferingPercent', 3)} |")


if __name__ == "__main__":
    sys.exit(main())
