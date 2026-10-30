import AppKit
import QuartzCore
import TrackpadCore

enum RadialAutomaticAction {
    case advanced, retrying
    var title: String { self == .advanced ? "Auto-advanced" : "Auto-retrying" }
    var symbol: String { self == .advanced ? "checkmark.circle.fill" : "arrow.counterclockwise" }
}

@MainActor
private final class RadialActionMessageView: NSView {
    override var wantsUpdateLayer: Bool { true }
    private let symbol = NSImageView()
    private let text = NSTextField(labelWithString: "")
    private var messageID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.opacity = 0
        isHidden = true
        text.font = .systemFont(ofSize: 12, weight: .semibold)
        let row = NSStackView(views: [symbol, text]); row.alignment = .centerY; row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            symbol.widthAnchor.constraint(equalToConstant: 16), symbol.heightAnchor.constraint(equalToConstant: 16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() { layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.96).cgColor }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ action: RadialAutomaticAction) {
        let id = UUID()
        messageID = id
        text.stringValue = action.title
        symbol.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        symbol.contentTintColor = action == .advanced ? .systemGreen : .controlAccentColor
        setAccessibilityLabel(action.title)
        isHidden = false
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.45, 1]
        fade.duration = 1
        fade.timingFunctions = Array(repeating: PreviewAnimation.timingFunction, count: 3)
        layer?.add(fade, forKey: "automaticAction")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.messageID == id else { return }
            self.clear()
        }
    }

    func clear() {
        messageID = nil
        layer?.removeAnimation(forKey: "automaticAction")
        isHidden = true
    }
}

@MainActor
private final class RadialTargetView: NSView {
    var configuration: RadialTrialConfiguration?
    var measurement: RadialMeasurement?
    var revealed = false
    var progress = 0.0
    var preparationPoints: [CGPoint] = []
    let automaticMessage = RadialActionMessageView()
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 220) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        automaticMessage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(automaticMessage)
        NSLayoutConstraint.activate([
            automaticMessage.centerXAnchor.constraint(equalTo: centerXAnchor),
            automaticMessage.centerYAnchor.constraint(equalTo: centerYAnchor),
            automaticMessage.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 22
        func point(_ degrees: Double, _ scale: Double = 1) -> CGPoint {
            let radians = (degrees + 90) * .pi / 180
            return CGPoint(x: center.x + radius * scale * cos(radians), y: center.y + radius * scale * sin(radians))
        }
        func circle(_ at: CGPoint, _ r: Double, _ color: NSColor, fill: Bool = false, width: Double = 2) {
            color.set()
            let p = NSBezierPath(ovalIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2))
            p.lineWidth = width
            if fill { p.fill() } else { p.stroke() }
        }
        func line(_ from: CGPoint, _ to: CGPoint, _ color: NSColor, width: Double = 2) {
            color.setStroke()
            let p = NSBezierPath(); p.move(to: from); p.line(to: to); p.lineWidth = width; p.lineCapStyle = .round; p.stroke()
        }
        guard let c = configuration else {
            circle(CGPoint(x: center.x - 25, y: center.y), 7, .secondaryLabelColor, fill: true)
            circle(CGPoint(x: center.x + 25, y: center.y), 7, .secondaryLabelColor, fill: true)
            return
        }
        guard revealed else {
            let surface = NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 24), xRadius: 12, yRadius: 12)
            NSColor.separatorColor.setStroke(); surface.lineWidth = 1; surface.stroke()
            let hasPair = preparationPoints.count == 2
            let vector = hasPair ? CGPoint(x: preparationPoints[1].x - preparationPoints[0].x,
                                           y: preparationPoints[1].y - preparationPoints[0].y) : CGPoint(x: 1, y: 0)
            let span = hasPair ? hypot(vector.x, vector.y) : 0
            let unit = CGPoint(x: vector.x / max(0.001, hypot(vector.x, vector.y)),
                               y: vector.y / max(0.001, hypot(vector.x, vector.y)))
            // Both the live pair and its target use the same physical scale.
            let gain = (radius - 12) * 2 / max(80, max(span, c.spanMM ?? 40) + 16)
            let ready = hasPair && (c.spanMM.map { abs(span - $0) <= c.spanToleranceMM } ?? true)
            let accent = ready ? NSColor.systemGreen : .controlAccentColor
            func endpoint(_ distance: Double, _ sign: Double) -> CGPoint {
                CGPoint(x: center.x + unit.x * distance * sign * gain / 2,
                        y: center.y + unit.y * distance * sign * gain / 2)
            }
            if let wanted = c.spanMM {
                for sign in [-1.0, 1.0] {
                    let target = endpoint(wanted, sign)
                    line(endpoint(wanted - c.spanToleranceMM, sign), endpoint(wanted + c.spanToleranceMM, sign),
                         accent.withAlphaComponent(0.18), width: 20)
                    circle(target, 9, accent, width: 2)
                    if hasPair, !ready {
                        let actual = endpoint(span, sign)
                        let dx = target.x - actual.x, dy = target.y - actual.y
                        let length = hypot(dx, dy)
                        if length > 18 {
                            let ux = dx / length, uy = dy / length
                            let tip = CGPoint(x: target.x - ux * 11, y: target.y - uy * 11)
                            line(CGPoint(x: actual.x + ux * 8, y: actual.y + uy * 8), tip, accent, width: 2)
                            for side in [-1.0, 1.0] {
                                line(tip, CGPoint(x: tip.x - ux * 5 - uy * side * 4,
                                                  y: tip.y - uy * 5 + ux * side * 4), accent, width: 2)
                            }
                        }
                    }
                }
            }
            if hasPair {
                line(endpoint(span, -1), endpoint(span, 1), .secondaryLabelColor, width: 1)
                for sign in [-1.0, 1.0] { circle(endpoint(span, sign), 6, ready ? .systemGreen : .labelColor, fill: true) }
            } else if c.spanMM == nil {
                for sign in [-1.0, 1.0] { circle(endpoint(30, sign), 6, .secondaryLabelColor, fill: true) }
            }
            return
        }
        circle(center, radius, .separatorColor, width: 1)
        for angle in stride(from: 0.0, to: 360, by: 30) { line(point(angle, 0.94), point(angle), .tertiaryLabelColor, width: 1) }
        let inTarget = (measurement?.absoluteError ?? .infinity) <= c.tolerance
        let accent = inTarget ? NSColor.systemGreen : .controlAccentColor
        if c.task == .rotation {
            let band = NSBezierPath()
            band.move(to: center)
            band.appendArc(withCenter: center, radius: radius * 0.88,
                           startAngle: c.target + 90 - c.tolerance, endAngle: c.target + 90 + c.tolerance)
            band.close(); accent.withAlphaComponent(0.2).setFill(); band.fill()
            line(center, point(c.target, 0.88), accent, width: 3)
            line(center, point(measurement?.rotation ?? 0, 0.74), .labelColor, width: 2.5)
            circle(point(measurement?.rotation ?? 0, 0.74), 4, .labelColor, fill: true)
        } else if c.task == .pinch {
            circle(center, radius * 0.6, .tertiaryLabelColor, width: 1)
            circle(center, radius * 0.6 * (1 + c.target / 100), accent, width: 4)
            circle(center, max(2, radius * 0.6 * (1 + (measurement?.spacingPercent ?? 0) / 100)), .labelColor)
        } else if c.task == .translation {
            let gain = radius * 0.075
            let target = CGPoint(x: center.x + c.target * cos(c.direction) * gain, y: center.y + c.target * sin(c.direction) * gain)
            circle(target, c.tolerance * gain, accent.withAlphaComponent(0.25), fill: true)
            circle(target, c.tolerance * gain, accent)
            let actual = measurement?.translation ?? .zero
            let p = CGPoint(x: center.x + actual.x * gain, y: center.y + actual.y * gain)
            line(center, p, .secondaryLabelColor, width: 1)
            circle(p, 4, .labelColor, fill: true)
        } else {
            circle(center, radius * 0.32, accent.withAlphaComponent(0.16), fill: true)
            circle(center, radius * 0.32, accent)
            circle(center, min(radius * 0.9, radius * 0.32 * (measurement?.value ?? 0) / c.tolerance), .labelColor)
        }
        circle(center, 3, .secondaryLabelColor, fill: true)
        if progress > 0 {
            let p = NSBezierPath()
            p.appendArc(withCenter: center, radius: radius + 9, startAngle: 90, endAngle: 90 + 360 * progress)
            p.lineWidth = 4; p.lineCapStyle = .round; NSColor.systemGreen.setStroke(); p.stroke()
        }
    }
}

@MainActor
final class RadialExperimentView: NSView {
    override var wantsUpdateLayer: Bool { true }
    var onStart: ((RadialPreset, Bool) -> Void)?
    var onNext: (() -> Void)?
    var onRetry: (() -> Void)?
    var onStop: (() -> Void)?
    var onFinish: (() -> Void)?
    var onClose: (() -> Void)?
    private let dial = RadialTargetView()
    private let presets = NSPopUpButton()
    private let practice = NSButton(checkboxWithTitle: "Practice ×3", target: nil, action: nil)
    private let title = NSTextField(labelWithString: "Radial experiment")
    private let instruction = NSTextField(wrappingLabelWithString: "Targets appear after two fingers are ready.")
    private let condition = NSTextField(wrappingLabelWithString: "")
    private let value = NSTextField(labelWithString: "—")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton(title: "Start Block", target: nil, action: nil)
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private let finish = NSButton(title: "End Block", target: nil, action: nil)
    private var running = false
    private var hasBlock = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        presets.addItems(withTitles: RadialPreset.current.map(\.rawValue))
        presets.setAccessibilityLabel("Experiment cases")
        practice.state = .on
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        value.font = .monospacedDigitSystemFont(ofSize: 27, weight: .medium)
        condition.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        condition.textColor = .secondaryLabelColor; detail.textColor = .secondaryLabelColor
        for button in [primary, retry, finish] { button.bezelStyle = .rounded; button.target = self; button.controlSize = .large }
        primary.action = #selector(performPrimary)
        retry.action = #selector(performRetry)
        finish.action = #selector(performFinish)
        let close = NSButton(title: "Close", target: self, action: #selector(performClose))
        close.bezelStyle = .rounded
        let setup = NSStackView(views: [presets, practice, NSView(), close]); setup.spacing = 12
        let actions = NSStackView(views: [primary, retry, finish]); actions.spacing = 10
        let right = NSStackView(views: [setup, title, instruction, condition, value, detail, actions])
        right.orientation = .vertical; right.alignment = .leading; right.spacing = 10
        setup.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [dial, right]); row.alignment = .centerY; row.spacing = 20
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            dial.widthAnchor.constraint(equalToConstant: 220), dial.heightAnchor.constraint(equalToConstant: 220),
            setup.widthAnchor.constraint(equalTo: right.widthAnchor), instruction.widthAnchor.constraint(equalTo: right.widthAnchor),
            condition.widthAnchor.constraint(equalTo: right.widthAnchor),
            detail.widthAnchor.constraint(equalTo: right.widthAnchor)
        ])
        dial.setContentHuggingPriority(.required, for: .horizontal)
        right.setContentHuggingPriority(.defaultLow, for: .horizontal)
        update(engine: nil, hasBlock: false, next: nil, recording: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() { layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor }

    func update(engine: RadialTrialEngine?, hasBlock: Bool, next: RadialTrialConfiguration?, recording: Bool,
                canStart: Bool = true, awaitingRelease: Bool = false, awaitingContact: Bool = false, retryPending: Bool = false) {
        self.running = recording; self.hasBlock = hasBlock
        presets.isEnabled = !hasBlock && !recording; practice.isEnabled = presets.isEnabled
        primary.title = recording ? "Stop Trial" : hasBlock ? (next == nil ? "Block Complete" : "Next Trial") : "Start Block"
        primary.isEnabled = (recording || canStart) && (!hasBlock || recording || next != nil)
        retry.isEnabled = hasBlock && !recording && engine != nil
        finish.isEnabled = hasBlock
        guard hasBlock, let engine else {
            title.stringValue = "Radial experiment"
            instruction.stringValue = "Adjust the gap, lift both fingers, then land and gesture."
            condition.stringValue = "V2 · Fresh landing · turns and controls"
            value.stringValue = "—"; detail.stringValue = "Each trial saves a session · Space advances or stops"
            dial.configuration = nil; dial.measurement = nil; dial.progress = 0
            dial.preparationPoints = []; dial.revealed = false; dial.needsDisplay = true
            return
        }
        let c = engine.record.configuration
        if hasBlock, let preset = c.preset { presets.selectItem(withTitle: preset) }
        let revealed = engine.phase == .landing || engine.record.cue != nil || engine.record.preparation?.targetTime != nil
        title.stringValue = "\(c.practice ? "Practice" : "Trial") \(c.number) / \(c.count)\(revealed ? " · " + c.title : "")"
        let span = c.spanMM.map { String(format: "%.0f mm span", $0) } ?? "Comfortable span"
        let pace = c.pace == .quick ? "Quick · aim under 0.7 s" : c.pace == .careful ? "Careful · take 2–4 s" : "Natural pace"
        condition.stringValue = "\(c.protocolTitle) · \(span) · \(c.landingStyle?.title ?? c.start.rawValue.capitalized + " start") · \(pace)"
        switch engine.phase {
        case .waiting, .settling:
            if let wanted = c.spanMM, let actual = engine.currentSpan, abs(wanted - actual) > c.spanToleranceMM {
                instruction.stringValue = actual < wanted ? "Spread your fingers toward the rings" : "Bring your fingers closer toward the rings"
            } else if engine.currentSpan == nil, let wanted = c.spanMM {
                instruction.stringValue = String(format: "Place two fingers %.0f mm apart", wanted)
            } else { instruction.stringValue = c.landingStyle != nil ? "Hold the gap briefly, then lift both fingers" : c.start == .settled ? "Hold both fingers still for the cue" : "Place two fingers for an immediate cue" }
            value.stringValue = engine.currentSpan.map { String(format: "%.0f mm", $0) } ?? "—"
            detail.stringValue = c.spanMM == nil ? "One-finger cursor movement cancels · Space stops" : "Dots: your fingers · Rings: target spacing"
        case .awaitingLift:
            instruction.stringValue = "Lift both fingers once"
            value.stringValue = engine.currentSpan.map { String(format: "%.0f mm", $0) } ?? "—"
            detail.stringValue = "Gap set · the target appears after release"
        case .landing:
            instruction.stringValue = c.landingStyle == .staggered ? "Land one finger, add the other, and \(c.title.lowercased())" : "Land both fingers and \(c.title.lowercased())"
            value.stringValue = "Ready"
            detail.stringValue = "Second finger within 100 ms · gesture as you land"
        case .active:
            instruction.stringValue = c.task == .hold ? "Keep both fingers still until the ring fills" : "\(c.title) · hold in the target until the ring fills"
            value.stringValue = engine.measurement.map { String(format: "%+.1f%@", $0.value, c.unit) } ?? "0\(c.unit)"
            detail.stringValue = "Target \(String(format: "%g", c.target))\(c.unit) · tolerance ±\(String(format: "%g", c.tolerance))\(c.unit)"
        case .finished:
            let result = engine.record.result
            let outcome = result?.outcome
            instruction.stringValue = outcome == .abruptMovement ? "Abrupt movement · trial saved" : outcome == .incompleteLanding ? "Second finger not detected within 100 ms · trial saved" : outcome == .invalidLanding ? "Invalid landing · keep the fingers at least 10 mm apart" : outcome == .cancelled ? "Cancelled by cursor movement · trial saved" : outcome == .acquired ? "Target held" : outcome == .lifted ? "Lifted before holding the target" : outcome == .timedOut ? "Time limit reached" : outcome == .stopped ? "Stopped · partial trial saved" : "Contact stream interrupted · trial saved"
            if awaitingContact { instruction.stringValue += retryPending ? " · place two fingers to retry" : " · place two fingers for next trial" }
            else if awaitingRelease { instruction.stringValue += retryPending ? " · lift all fingers, then place two to retry" : " · lift all fingers, then place two" }
            else if hasBlock, next == nil { instruction.stringValue += " · block complete" }
            value.stringValue = result?.final.map { String(format: "Error %.2f%@", $0.absoluteError, c.unit) } ?? "No target sample"
            let first = result?.firstTargetTime.map { String(format: "First target %.3f s", $0) }
            let settled = result?.settlingTime.map { String(format: "Settled %.3f s", $0) }
            let peak = result?.final.map { _ in String(format: "Overshoot %.2f%@", result?.peakOvershoot ?? 0, c.unit) }
            detail.stringValue = [first, settled, peak].compactMap { $0 }.joined(separator: " · ")
            if detail.stringValue.isEmpty { detail.stringValue = "Space: next · Retry repeats this case" }
        }
        value.textColor = (engine.measurement?.absoluteError ?? .infinity) <= c.tolerance && revealed ? .systemGreen : .labelColor
        dial.configuration = c; dial.measurement = engine.measurement; dial.revealed = revealed; dial.progress = engine.holdProgress
        dial.preparationPoints = engine.currentPointsMM
        dial.setAccessibilityLabel(revealed ? c.title : instruction.stringValue)
        dial.needsDisplay = true
    }

    func advance() { performPrimary() }

    func showAutomaticAction(_ action: RadialAutomaticAction) { dial.automaticMessage.show(action) }
    func clearAutomaticAction() { dial.automaticMessage.clear() }

    func showReplay(_ record: RadialTrialRecord, measurement: RadialMeasurement?, time: TimeInterval) {
        clearAutomaticAction()
        let c = record.configuration
        let revealed = (record.preparation?.targetTime ?? record.cue?.time).map { time >= $0 } ?? false
        title.stringValue = "Replay · \(c.protocolTitle) · \(c.title)"
        condition.stringValue = "\(c.protocolTitle) · \(c.landingStyle?.title ?? c.start.rawValue.capitalized + " start")"
        instruction.stringValue = revealed ? "Recorded target and contact geometry" : "Before target cue"
        value.stringValue = measurement.map { String(format: "%+.1f%@", $0.value, c.unit) } ?? "—"
        detail.stringValue = measurement.map { String(format: "Error %.2f%@ · target %g%@", $0.absoluteError, c.unit, c.target, c.unit) } ?? ""
        dial.configuration = c; dial.measurement = measurement; dial.revealed = revealed; dial.progress = 0
        dial.preparationPoints = []; dial.needsDisplay = true
    }

    @objc private func performPrimary() {
        if running { onStop?() }
        else if hasBlock { onNext?() }
        else { onStart?(RadialPreset.current[max(0, presets.indexOfSelectedItem)], practice.state == .on) }
    }
    @objc private func performRetry() { onRetry?() }
    @objc private func performFinish() { onFinish?() }
    @objc private func performClose() { onClose?() }
}
