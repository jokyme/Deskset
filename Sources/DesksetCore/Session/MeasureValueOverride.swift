import Foundation

/// Sample data for the Studio's own instance of a widget (the preview bar's Data menu): what its measures read is
/// replaced when they update, before their rules run — so a rule such as "above 80 % turns red" fires as it would on
/// real data — while the widget on the desktop, which has no override, keeps its live values.
///
/// Only measures that read data are replaced (`readsData`: the processor, memory, disks, the network, sensors, players,
/// web pages…); a Calc measure works its value out from them as usual, and the widget's own timers, scripts and texts
/// run as they are. Time measures show `frozenTime` when it is set.
///
/// Main thread, like the Studio's instance (`Skin.measureValues`).
public final class MeasureValueOverride {
    /// What the data measures show.
    public enum Data: Equatable {
        /// Their own values.
        case live
        /// The values they had when the preset was chosen: nothing is read.
        case paused
        /// This share of each one's range (0…1): 0 %, 50 %, 100 %.
        case level(Double)
        /// A long text in place of each text (`longSample`); numbers stay live.
        case longText
        /// Nothing: 0, and an empty text for those that have one.
        case noData
    }

    /// What the data measures show.
    public var data: Data = .live
    /// The instant the Time measures show (nil: the clock). Those with a `TimeStamp` of their own keep it.
    public var frozenTime: Date?

    public init() {}

    /// Whether anything is replaced.
    public var isActive: Bool { data != .live || frozenTime != nil }

    /// The text the long-text preset shows.
    public static let longSample = "A much longer text than this widget was made for, to see where it wraps or ends"

    /// Measure types (`Measure=`, or the plugin's name) that read data from the Mac, a device or the network.
    public static let dataTypes: Set<String> = [
        "cpu", "memory", "physicalmemory", "swapmemory", "netin", "netout", "nettotal", "freediskspace", "process",
        "sysinfo", "webparser", "powerplugin", "registry",
        "advancedcpu", "coretemp", "macsensors", "usagemonitor", "perfmon", "perfmonplugin", "resmon", "speedfan",
        "speedfanplugin", "msiafterburner", "hwinfo", "audiolevel", "wifistatus", "nowplaying", "itunesplugin",
        "win7audio", "win7audioplugin", "appvolume", "ping", "pingplugin", "folderinfo", "recyclemanager", "quote",
        "quoteplugin", "macweather", "macsun",
    ]

    /// Whether `measure` reads data (rather than working something out or keeping time).
    public static func readsData(_ measure: Measure) -> Bool {
        dataTypes.contains(measure.type)
    }

    /// Called by `Measure.performUpdate` before the measure computes its value: true when the override set the
    /// measure's number and text itself (the measure then only runs its rules).
    func takesOver(_ measure: Measure) -> Bool {
        if let frozenTime, let time = measure as? TimeMeasure {
            return show(frozenTime, in: time)
        }
        // A total (`Total=1`: the memory or the disk there is) is not data that moves: it stays as it is.
        guard data != .live, Self.readsData(measure), !measure.bool("Total", false) else { return false }
        switch data {
        case .live:
            return false
        case .paused:
            // Before its first update there is nothing to keep: it reads once.
            return measure.updateCount > 0
        case .level(let share):
            measure.refreshRange()
            let clamped = min(max(share.isFinite ? share : 0, 0), 1)
            measure.value = measure.minValue + clamped * (measure.maxValue - measure.minValue)
            return true
        case .longText:
            guard measure.updateCount > 0, measure.rawString != nil else { return false }
            measure.rawString = Self.longSample
            return true
        case .noData:
            measure.value = 0
            if measure.rawString != nil { measure.rawString = "" }
            return true
        }
    }

    /// A Time measure at `date`, read with its own Format, TimeZone and FormatLocale.
    private func show(_ date: Date, in measure: TimeMeasure) -> Bool {
        guard measure.string("TimeStamp").trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let format = measure.option("Format")
        let zoneOption = measure.option("TimeZone").map { raw -> String in
            OptionValue.number(raw).map { NumberFormatting.plain($0) } ?? raw
        }
        let zone = TimeFormatting.timeZone(forOption: zoneOption,
                                           daylightSavingTime: measure.bool("DaylightSavingTime", true), at: date)
        let locale = TimeFormatting.locale(fromOption: measure.option("FormatLocale")) ?? TimeFormatting.defaultLocale
        let timestamp = TimeFormatting.measureValue(for: date, timeZone: zone)
        let text = TimeFormatting.format(windowsTimestamp: timestamp, format: format ?? TimeFormatting.defaultFormat,
                                         locale: locale, nameTimeZone: zone)
        measure.rawString = text
        measure.value = format != nil ? TimeFormatting.numberValue(ofFormatted: text) : timestamp
        return true
    }
}
