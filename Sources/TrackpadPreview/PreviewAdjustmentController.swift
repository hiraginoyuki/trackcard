import AppKit
import QuartzCore
import TrackpadCore

@MainActor
private final class AdjustmentMenuView: NSView {
    let scale = NSSlider(value: 0.5, minValue: 0.25, maxValue: 1.5, target: nil, action: nil)
    let opacity = NSSlider(value: 1, minValue: 0.15, maxValue: 1, target: nil, action: nil)
    private let scaleValue = NSTextField(labelWithString: "")
    private let opacityValue = NSTextField(labelWithString: "")
    var onScale: ((Double) -> Void)?
    var onOpacity: ((Double) -> Void)?

    init(scale value: Double, opacity alpha: Double) {
        super.init(frame: NSRect(x: 0, y: 0, width: 244, height: 190))
        let scaleTitle = NSTextField(labelWithString: "Scale")
        let opacityTitle = NSTextField(labelWithString: "Opacity")
        for label in [scaleValue, opacityValue] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.alignment = .right
        }
        for slider in [scale, opacity] {
            slider.isContinuous = true
            slider.target = self
            slider.controlSize = .large
        }
        scale.action = #selector(changeScale)
        opacity.action = #selector(changeOpacity)
        scale.setAccessibilityLabel("Preview scale")
        opacity.setAccessibilityLabel("Preview opacity")
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        let rule = NSBox(); rule.boxType = .separator
        let controls: [NSView] = [scaleTitle, scaleValue, scale, opacityTitle, opacityValue, opacity, rule, quit]
        for view in controls { addSubview(view) }
        scaleTitle.frame = NSRect(x: 14, y: 156, width: 120, height: 18)
        scaleValue.frame = NSRect(x: 148, y: 156, width: 82, height: 18)
        scale.frame = NSRect(x: 10, y: 116, width: 224, height: 40)
        opacityTitle.frame = NSRect(x: 14, y: 98, width: 120, height: 18)
        opacityValue.frame = NSRect(x: 148, y: 98, width: 82, height: 18)
        opacity.frame = NSRect(x: 10, y: 58, width: 224, height: 40)
        rule.frame = NSRect(x: 14, y: 51, width: 216, height: 1)
        quit.frame = NSRect(x: 10, y: 6, width: 224, height: 40)
        update(scale: value, opacity: alpha)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(scale value: Double, opacity alpha: Double) {
        scale.doubleValue = value; opacity.doubleValue = alpha
        scaleValue.stringValue = String(format: "%.0f%%", value * 100)
        opacityValue.stringValue = String(format: "%.0f%%", alpha * 100)
    }
    @objc private func changeScale() { onScale?(scale.doubleValue) }
    @objc private func changeOpacity() { onOpacity?(opacity.doubleValue) }
}

@MainActor
private final class AdjustmentRingView: NSView {
    var value = 1.0
    var fraction = 1.0
    var symbol = "circle.lefthalf.filled"
    var steps = 17
    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
        for (amount, color) in [(1.0, NSColor.secondaryLabelColor.withAlphaComponent(0.2)),
                                (min(1, max(0, fraction)), NSColor.controlAccentColor)] {
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: 32, startAngle: 225,
                           endAngle: 225 - 270 * amount, clockwise: true)
            path.lineWidth = 4; path.lineCapStyle = .round
            color.setStroke(); path.stroke()
        }
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
        for index in 0...steps {
            let angle = (225 - 270 * Double(index) / Double(steps)) * .pi / 180
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: center.x + 37 * cos(angle), y: center.y + 37 * sin(angle)))
            tick.line(to: NSPoint(x: center.x + 39 * cos(angle), y: center.y + 39 * sin(angle)))
            tick.lineWidth = 1; tick.stroke()
        }
        let text = String(format: "%.0f%%", value * 100)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - 5), withAttributes: attributes)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))?.draw(in: NSRect(x: center.x - 7, y: center.y + 15, width: 14, height: 14))
    }
}

/// Shares menu content with right click, but uses a nonmodal presentation while
/// sensing a physical gesture so menu tracking cannot stall capture callbacks.
@MainActor
final class PreviewAdjustmentController {
    enum Kind {
        case scale, opacity
        var range: ClosedRange<Double> { self == .scale ? 0.25...1.5 : 0.15...1 }
    }
    var onScale: ((Double) -> Void)?
    var onOpacity: ((Double) -> Void)?
    private let menuPanel: NSPanel
    private let ringPanel: NSPanel
    private let ring = AdjustmentRingView(frame: NSRect(x: 0, y: 0, width: 88, height: 88))
    private weak var manualMenuView: AdjustmentMenuView?
    private var gestureMenuView: AdjustmentMenuView?
    private(set) var activeKind: Kind?
    private(set) var isProvisional = false
    private(set) var cursorHidden = false
    private var detents = AdjustmentDetents()
    private var confidenceFeedback = GestureConfidenceFeedback()
    private var snapFeedbackPending = false
    private var presentationOpacity = OpacityMotion(value: 0)
    var hapticDeviceID: UInt64?
    var hapticContactTime: TimeInterval = -.infinity
    private lazy var fineHaptics = TrackpadHaptics()
    private var sliderKind: Kind?
    private var sliderValues = (scale: 0.5, opacity: 1.0)
    private let hapticFeedback: ((AdjustmentDetents.Strength) -> Void)?
    private let cursorVisibility: (Bool) -> Bool
    private let presentsWindows: Bool
    private let reduceMotion: () -> Bool

    init(presentsWindows: Bool = true,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         hapticFeedback: ((AdjustmentDetents.Strength) -> Void)? = nil,
         cursorVisibility: @escaping (Bool) -> Bool = { visible in
        (visible ? CGDisplayShowCursor(CGMainDisplayID()) : CGDisplayHideCursor(CGMainDisplayID())) == .success
    }) {
        self.hapticFeedback = hapticFeedback; self.cursorVisibility = cursorVisibility
        self.presentsWindows = presentsWindows
        self.reduceMotion = reduceMotion
        menuPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 244, height: 190), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ringPanel = NSPanel(contentRect: ring.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for panel in [menuPanel, ringPanel] {
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.animationBehavior = .none
        }
        menuPanel.hasShadow = true; menuPanel.ignoresMouseEvents = true
        ringPanel.hasShadow = false; ringPanel.ignoresMouseEvents = true
        ringPanel.contentView = ring
    }

    private func content(scale: Double, opacity: Double) -> AdjustmentMenuView {
        let view = AdjustmentMenuView(scale: scale, opacity: opacity)
        view.onScale = { [weak self] value in
            self?.sliderFeedback(.scale, value: value); self?.onScale?(value)
        }
        view.onOpacity = { [weak self] value in
            self?.sliderFeedback(.opacity, value: value); self?.onOpacity?(value)
        }
        return view
    }

    func contextMenu(scale: Double, opacity: Double, enabled: Bool = true) -> NSMenu {
        end()
        sliderKind = nil
        sliderValues = (scale, opacity)
        let view = content(scale: scale, opacity: opacity)
        view.scale.isEnabled = enabled; view.opacity.isEnabled = enabled
        manualMenuView = view
        let item = NSMenuItem(); item.view = view
        let menu = NSMenu(); menu.addItem(item)
        return menu
    }

    func begin(_ kind: Kind, scale: Double, opacity: Double, at point: NSPoint) {
        let promoting = isProvisional
        if !promoting { end() }
        isProvisional = false
        activeKind = kind
        confidenceFeedback = GestureConfidenceFeedback()
        detents = AdjustmentDetents(range: kind.range)
        detents.reset(to: kind == .scale ? scale : opacity)
        if !promoting { installGestureMenu(scale: scale, opacity: opacity) }
        update(scale: scale, opacity: opacity, at: point)
        snapFeedbackPending = true
        showPanels(opacity: 1, from: promoting ? nil : 0, animated: true)
    }

    func preview(scale: Double, opacity: Double, confidence: Double, at point: NSPoint,
                 time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard activeKind == nil else { return }
        let starting = !isProvisional
        if starting {
            isProvisional = true
            confidenceFeedback = GestureConfidenceFeedback()
            installGestureMenu(scale: scale, opacity: opacity)
        }
        update(scale: scale, opacity: opacity, at: point)
        if starting { showPanels(opacity: 0.25, from: nil, animated: false) }
        if let strength = confidenceFeedback.update(confidence, at: time) {
            emitFeedback(strength, amplitude: 0.025 + 0.1 * confidenceFeedback.confidence)
        }
    }

    func resolveMovement() {
        if isProvisional { emitFeedback(.medium) }
        end()
    }

    private func installGestureMenu(scale: Double, opacity: Double) {
        let view = content(scale: scale, opacity: opacity)
        gestureMenuView = view
        let material = NSVisualEffectView(frame: view.bounds)
        material.material = .menu; material.state = .active; material.blendingMode = .behindWindow
        material.wantsLayer = true; material.layer?.cornerRadius = 10; material.layer?.masksToBounds = true
        material.addSubview(view); menuPanel.contentView = material
    }

    private func showPanels(opacity: Double, from initialOpacity: Double?, animated: Bool) {
        let animate = animated && presentsWindows && !reduceMotion()
        if animate {
            if let initialOpacity, !ringPanel.isVisible { presentationOpacity.reset(to: initialOpacity) }
            presentationOpacity.retarget(to: opacity)
        } else { presentationOpacity.reset(to: opacity) }
        for panel in [ringPanel, menuPanel] {
            panel.alphaValue = presentationOpacity.value
            if presentsWindows { panel.orderFrontRegardless() }
        }
        if !cursorHidden { cursorHidden = cursorVisibility(false) }
    }

    func update(scale: Double, opacity: Double, at point: NSPoint) {
        presentationOpacity.advance(at: ProcessInfo.processInfo.systemUptime, reduceMotion: reduceMotion())
        ringPanel.alphaValue = presentationOpacity.value
        menuPanel.alphaValue = presentationOpacity.value
        manualMenuView?.update(scale: scale, opacity: opacity)
        gestureMenuView?.update(scale: scale, opacity: opacity)
        guard let kind = activeKind ?? (isProvisional ? .scale : nil) else { return }
        let value = kind == .scale ? scale : opacity
        ring.value = value
        ring.fraction = kind == .scale ? (value - 0.25) / 1.25 : (value - 0.15) / 0.85
        ring.steps = kind == .scale ? 25 : 17
        ring.symbol = kind == .scale ? "arrow.up.left.and.arrow.down.right" : "circle.lefthalf.filled"
        ring.needsDisplay = true
        let visible = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let ringFrame = NSRect(x: point.x - 44, y: point.y - 44, width: 88, height: 88)
        ringPanel.setFrame(clamped(ringFrame, to: visible), display: false)
        var menuFrame = NSRect(x: point.x + 58, y: point.y - 95, width: 244, height: 190)
        if menuFrame.maxX > visible.maxX { menuFrame.origin.x = point.x - 58 - menuFrame.width }
        menuPanel.setFrame(clamped(menuFrame, to: visible), display: false)
        if !isProvisional {
            var strength = detents.update(value, at: ProcessInfo.processInfo.systemUptime)
            if snapFeedbackPending {
                if strength != .strong { strength = .medium }
                snapFeedbackPending = false
            }
            if let strength { emitFeedback(strength) }
        }
    }

    private func clamped(_ rect: NSRect, to bounds: NSRect) -> NSRect {
        NSRect(x: min(max(rect.minX, bounds.minX), max(bounds.minX, bounds.maxX - rect.width)),
               y: min(max(rect.minY, bounds.minY), max(bounds.minY, bounds.maxY - rect.height)), width: rect.width, height: rect.height)
    }

    private func sliderFeedback(_ kind: Kind, value: Double) {
        if sliderKind != kind {
            sliderKind = kind
            detents = AdjustmentDetents(range: kind.range)
            detents.reset(to: kind == .scale ? sliderValues.scale : sliderValues.opacity)
        }
        if kind == .scale { sliderValues.scale = value } else { sliderValues.opacity = value }
        if let strength = detents.update(value, at: ProcessInfo.processInfo.systemUptime) { emitFeedback(strength) }
    }

    private func emitFeedback(_ strength: AdjustmentDetents.Strength, amplitude: Double? = nil) {
        if let hapticFeedback { hapticFeedback(strength); return }
        if strength == .tiny || amplitude != nil {
            guard ProcessInfo.processInfo.systemUptime - hapticContactTime < 0.15 else { return }
            _ = fineHaptics?.pulse(deviceID: hapticDeviceID, amplitude: amplitude ?? 0.12)
        } else {
            NSHapticFeedbackManager.defaultPerformer.perform(strength == .strong ? .generic : .levelChange, performanceTime: .now)
        }
    }

    func end() {
        activeKind = nil; gestureMenuView = nil
        isProvisional = false
        confidenceFeedback = GestureConfidenceFeedback()
        snapFeedbackPending = false
        presentationOpacity.reset(to: 0)
        ringPanel.orderOut(nil); menuPanel.orderOut(nil)
        if cursorHidden { _ = cursorVisibility(true); cursorHidden = false }
    }

    func close() { end(); fineHaptics?.close(); ringPanel.close(); menuPanel.close() }
}
