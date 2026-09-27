import Foundation

extension Skin {
    /// Takes over what a new instance of a widget cannot read from its files from an instance of the same widget that is
    /// already running: the Calc `Counter`, and the samples of every Line and Histogram meter of the same name and kind.
    /// The Studio's own instance of a widget is seeded from the widget on the desktop when the Studio opens it, so the
    /// canvas shows the graphs the desktop shows, as it did when it drew the desktop copy itself, instead of starting
    /// them empty. Call it after `load()` and before the first `update()`, on the thread that owns both skins.
    public func seed(from running: Skin) {
        continueCounter(from: running)
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
