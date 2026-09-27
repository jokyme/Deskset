import Foundation

extension Skin {
    /// Takes the graphs of an instance of the same widget that is already running: the samples of every Line and
    /// Histogram meter of the same name and kind. The Studio's own instance of a widget is seeded from the widget on the
    /// desktop when the Studio opens it — `mirrorCounter(of:)` before its first update, this right after it — so the
    /// canvas shows what the desktop shows, as it did when it drew the desktop copy itself, instead of starting the
    /// graphs empty. Both skins must be owned by the calling thread.
    public func takeGraphs(from running: Skin) {
        for meter in meters {
            guard let source = running.meter(named: meter.name) else { continue }
            if let line = meter as? LineMeter, let from = source as? LineMeter {
                line.takeHistory(from: from)
            } else if let histogram = meter as? HistogramMeter, let from = source as? HistogramMeter {
                histogram.takeHistory(from: from)
            }
        }
    }
}
