import AppKit

/// Numeric controls exchange canonical finite values. Formatting here never evaluates a widget expression.
enum StudioNumericValue {
    static func text(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    static func clamped(_ value: Double, minimum: Double, maximum: Double, step: Double?) -> Double? {
        guard value.isFinite, minimum.isFinite, maximum.isFinite, minimum <= maximum,
              step.map({ $0.isFinite && $0 > 0 }) ?? true else { return nil }
        let bounded = min(max(value, minimum), maximum)
        guard let step else { return bounded }
        let offset = (bounded - minimum) / step
        let result: Double
        if offset.isFinite, (offset.rounded() * step).isFinite {
            result = minimum + offset.rounded() * step
        } else {
            // The endpoints can both be finite even when their difference overflows. Work at their scale;
            // a step too small to survive that scaling is already below the representable value's precision.
            let scale = max(abs(minimum), abs(maximum), step)
            let unit = step / scale
            let count = unit > 0 ? (bounded / scale - minimum / scale) / unit : .infinity
            guard count.isFinite else { return bounded }
            let normalized = minimum / scale + count.rounded() * unit
            result = min(max(normalized, minimum / scale), maximum / scale) * scale
        }
        guard result.isFinite else { return bounded }
        return min(max(result, minimum), maximum)
    }

    static func fraction(_ value: Double, minimum: Double, maximum: Double) -> Double {
        guard minimum < maximum else { return 0 }
        let span = maximum - minimum
        let fraction = span.isFinite ? (value - minimum) / span
            : (value / 2 - minimum / 2) / (maximum / 2 - minimum / 2)
        return min(max(fraction, 0), 1)
    }

    static func value(_ fraction: Double, minimum: Double, maximum: Double) -> Double {
        let fraction = min(max(fraction, 0), 1)
        return minimum * (1 - fraction) + maximum * fraction
    }
}

/// AppKit's tracking loop can deliver owner replies. Keep its local value until the gesture has ended.
final class StudioTrackingSlider: NSSlider {
    var onFinish: (() -> Void)?
    private(set) var isTrackingValue = false

    func beginTrackingValue() { isTrackingValue = true }
    func finishTrackingValue() {
        guard isTrackingValue else { return }
        isTrackingValue = false
        onFinish?()
    }

    override func mouseDown(with event: NSEvent) {
        beginTrackingValue()
        defer { finishTrackingValue() }
        super.mouseDown(with: event)
    }
}

final class StudioNumericSlider: NSView {
    var onChange: ((Double, Bool) -> Void)?
    let slider = StudioTrackingSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let valueLabel = StudioPageStyle.label("", font: StudioPageStyle.smallFont, color: .labelColor)
    private(set) var model = StudioPage.Slider(value: 0, minimum: 0, maximum: 1)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.onFinish = { [weak self] in self?.sendValue(done: true) }
        valueLabel.alignment = .right
        addSubview(slider); addSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ value: StudioPage.Slider, label: String) {
        slider.setAccessibilityLabel(label)
        // A pending snapshot may still contain the last accepted value, not the current finger position.
        guard !slider.isTrackingValue else { return }
        guard let current = StudioNumericValue.clamped(value.value, minimum: value.minimum, maximum: value.maximum,
                                                       step: nil) else {
            slider.isEnabled = false
            return
        }
        model = value
        // Keep AppKit's tracking arithmetic bounded even for a valid range spanning ±Double.greatestFiniteMagnitude.
        slider.doubleValue = StudioNumericValue.fraction(current, minimum: value.minimum, maximum: value.maximum)
        slider.isEnabled = value.minimum < value.maximum
        updateLabel(current)
    }

    @objc private func changed() { sendValue(done: !slider.isTrackingValue) }

    func sendValue(done: Bool) {
        guard slider.isEnabled, slider.doubleValue.isFinite,
              let value = StudioNumericValue.clamped(StudioNumericValue.value(slider.doubleValue,
                minimum: model.minimum, maximum: model.maximum),
            minimum: model.minimum, maximum: model.maximum, step: model.step) else { return }
        slider.doubleValue = StudioNumericValue.fraction(value, minimum: model.minimum, maximum: model.maximum)
        model.value = value
        updateLabel(value)
        onChange?(value, done)
    }

    private func updateLabel(_ value: Double) {
        let text = StudioNumericValue.text(value) + (model.unit.map { " " + $0 } ?? "")
        valueLabel.stringValue = text
        slider.setAccessibilityValueDescription(text)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let labelWidth = min(max(ceil(valueLabel.intrinsicContentSize.width), 35), bounds.width * 0.48)
        valueLabel.frame = NSRect(x: bounds.width - labelWidth, y: (bounds.height - 16) / 2, width: labelWidth, height: 16)
        slider.frame = NSRect(x: 0, y: (bounds.height - 20) / 2, width: max(bounds.width - labelWidth - 8, 1), height: 20)
    }
}

/// The existing editable number field alongside a real NSStepper, with no typography action or text-size scale.
final class StudioNumericStepper: NSView {
    var onChange: ((StudioNumberChange) -> Void)?
    let numberBox = StudioNumberBox()
    let stepper = NSStepper()
    private(set) var number = StudioPage.Number(text: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        stepper.controlSize = .small
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped)
        numberBox.onChange = { [weak self] change in self?.onChange?(change) }
        addSubview(numberBox); addSubview(stepper)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ value: StudioPage.Number, label: String) {
        number = value
        numberBox.show(value)
        numberBox.field.setAccessibilityLabel(label)
        stepper.setAccessibilityLabel(label)
        guard let minimum = value.minimum, let maximum = value.maximum, let value = value.value,
              let current = StudioNumericValue.clamped(value, minimum: minimum, maximum: maximum, step: nil),
              number.step.isFinite, number.step > 0 else {
            stepper.isEnabled = false
            return
        }
        stepper.minValue = minimum
        stepper.maxValue = maximum
        stepper.increment = number.step
        stepper.doubleValue = current
        stepper.isEnabled = minimum < maximum
    }

    @objc private func stepped() {
        guard stepper.isEnabled, let minimum = number.minimum, let maximum = number.maximum,
              let value = StudioNumericValue.clamped(stepper.doubleValue, minimum: minimum, maximum: maximum,
                                                     step: nil) else { return }
        number.value = value
        number.text = StudioNumericValue.text(value)
        numberBox.show(number)
        stepper.doubleValue = value
        onChange?(.typed(number.text))
    }

    override func layout() {
        super.layout()
        let width: CGFloat = 19
        numberBox.frame = NSRect(x: 0, y: 0, width: max(bounds.width - width - 6, 1), height: bounds.height)
        stepper.frame = NSRect(x: bounds.width - width, y: (bounds.height - 24) / 2, width: width, height: 24)
    }
}
