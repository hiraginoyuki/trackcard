import AppKit
import TrackpadCore

@MainActor
private final class ConfidenceWindow: NSWindow {
    var onRightClick: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown { onRightClick?() }
        super.sendEvent(event)
    }
}

@MainActor
private final class ConfidenceScrollView: NSScrollView {
    override func tile() {
        super.tile()
        if let documentView {
            documentView.setFrameSize(NSSize(width: contentView.bounds.width, height: documentView.frame.height))
        }
    }
}

@MainActor
private final class ConfidenceChartsView: NSView {
    var onInspect: ((ClassifierComparison.Inspection) -> Void)?
    var traces: [ClassifierComparison.Trace] = [] { didSet { needsDisplay = true; inspect() } }
    private var hover: Double?
    override var isFlipped: Bool { true }
    private let colors: [NSColor] = [.systemTeal, .systemOrange, .systemPurple, .labelColor]
    private var duration: Double {
        max(0.25, traces.flatMap { [$0.samples.last?.time ?? 0, $0.decisionTime ?? 0, $0.rightClickTime ?? 0] }.max() ?? 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    private func inspect() {
        guard let trace = traces.first(where: { $0.variant.isCurrent }) else { return }
        onInspect?(trace.inspection(at: hover))
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let columnWidth = (bounds.width - 42) / 2
        let localX = (point.x - 14).truncatingRemainder(dividingBy: columnWidth + 14)
        hover = min(1, max(0, (localX - 38) / (columnWidth - 54))) * duration
        let index = max(0, Int((point.y - 12) / 176)) * 2 + (point.x >= 28 + columnWidth ? 1 : 0)
        if traces.indices.contains(index), let hover,
           let sample = traces[index].samples.min(by: { abs($0.time - hover) < abs($1.time - hover) }), !sample.classifiers.isEmpty {
            toolTip = sample.classifiers.map {
                "\($0.classifier.title): \(Int(($0.confidence * 100).rounded()))% · " +
                    ($0.isReady ? "Ready" : $0.blockers.joined(separator: "; "))
            }.joined(separator: "\n")
        } else { toolTip = nil }
        inspect()
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hover = nil; toolTip = nil; inspect(); needsDisplay = true }

    private func text(_ value: String, _ rect: NSRect, color: NSColor = .labelColor, size: CGFloat = 11, bold: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular),
                                                         .foregroundColor: color, .paragraphStyle: paragraph])
    }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 80 else { return }
        let width = (bounds.width - 42) / 2
        for (index, trace) in traces.enumerated() {
            let card = NSRect(x: 14 + CGFloat(index % 2) * (width + 14), y: 12 + CGFloat(index / 2) * 176, width: width, height: 162)
            guard dirtyRect.intersects(card) else { continue }
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10).fill()
            text(trace.variant.title + (trace.variant.isCurrent ? " · Current" : ""), NSRect(x: card.minX + 12, y: card.minY + 9, width: width - 24, height: 18), size: 12, bold: true)
            let decision: String
            if let time = trace.rightClickTime { decision = "Right click veto · \(Int((time * 1000).rounded())) ms" }
            else if let time = trace.decisionTime {
                let classifier = trace.committedClassifier.map { " · \($0.title)" } ?? ""
                decision = "\(trace.decision.title)\(classifier) · \(Int((time * 1000).rounded())) ms"
            }
            else if let time = trace.pressCueTime { decision = "Press cue at \(Int((time * 1000).rounded())) ms" }
            else { decision = "Undecided" }
            text(decision, NSRect(x: card.minX + 12, y: card.minY + 29, width: width - 24, height: 15), color: .secondaryLabelColor)
            if trace.variant.configuration.usesIndependentClassifiers {
                let sample = hover.flatMap { time in trace.samples.min { abs($0.time - time) < abs($1.time - time) } } ?? trace.samples.last
                let leaders = [("P", ContactTransform.Intent.pinch), ("T", .rotation), ("S", .movement)].map { label, intent in
                    let strongest = sample?.classifiers.filter { $0.classifier.intent == intent }.max { $0.confidence < $1.confidence }
                    return strongest.map { String(format: "%@ %@ %.0f", label, $0.classifier.shortTitle, $0.confidence * 100) } ?? "\(label) —"
                }
                text(leaders.joined(separator: " · "), NSRect(x: card.minX + 12, y: card.minY + 45, width: width - 24, height: 14),
                     color: .secondaryLabelColor, size: 10)
            } else if trace.variant.configuration.usesEarlyIntent, let f = trace.samples.last?.features {
                text(String(format: "shared %.0f mm/s · align %.2f · press %.0f · T×%.2f", f.commonSpeed,
                            f.velocityAlignment ?? 0, (trace.samples.last?.pressScore ?? 0) * 100,
                            trace.samples.last?.tiltPrior ?? 1),
                     NSRect(x: card.minX + 12, y: card.minY + 45, width: width - 24, height: 14),
                     color: .secondaryLabelColor, size: 10)
            } else if trace.variant.configuration.tiltModel == .paths, let f = trace.samples.last?.features {
                let bend = f.path?.relativeBend.map { String(format: "%.0f°", $0 * 180 / .pi) } ?? "—"
                let curvature = f.path?.relativeCurvature.map { String(format: "%.3f/mm", $0) } ?? "—"
                text("κ \(curvature) · bend \(bend)",
                     NSRect(x: card.minX + 12, y: card.minY + 45, width: width - 24, height: 14),
                     color: .secondaryLabelColor, size: 10)
            } else if trace.variant.configuration.usesRelativeMotion, let f = trace.samples.last?.features {
                text(String(format: "vᵣ %.0f · vₜ %.0f mm/s · radial %.0f%%", f.radialVelocity,
                            f.tangentialVelocity, f.pinchConfidence * 100),
                     NSRect(x: card.minX + 12, y: card.minY + 45, width: width - 24, height: 14),
                     color: .secondaryLabelColor, size: 10)
            } else if trace.variant.configuration.tiltModel != .geometry, let f = trace.samples.last?.features {
                let axis = f.thumbRelativeAngle.map { String(format: "%.0f°", $0 * 180 / .pi) } ?? "—"
                let rate = f.thumbAxisVelocity.map { String(format: "%.0f°/s", $0 * 180 / .pi) } ?? "—"
                text(String(format: "ω %.0f°/s · axis %@ · d(axis) %@", f.angularVelocity * 180 / .pi, axis, rate), NSRect(x: card.minX + 12, y: card.minY + 45, width: width - 24, height: 14), color: .secondaryLabelColor, size: 10)
            }
            let plot = NSRect(x: card.minX + 38, y: card.minY + 62, width: width - 54, height: 72)
            for fraction in [0.0, 0.5, 1.0] {
                let y = plot.maxY - fraction * plot.height
                NSColor.separatorColor.setStroke()
                let grid = NSBezierPath(); grid.move(to: NSPoint(x: plot.minX, y: y)); grid.line(to: NSPoint(x: plot.maxX, y: y)); grid.stroke()
                text("\(Int(fraction * 100))", NSRect(x: card.minX + 6, y: y - 7, width: 29, height: 14), color: .tertiaryLabelColor, size: 9)
            }
            let sampleStride = max(1, trace.samples.count / max(1, Int(plot.width * 1.5)))
            var plotted = stride(from: 0, to: trace.samples.count, by: sampleStride).map { trace.samples[$0] }
            if let last = trace.samples.last, plotted.last?.time != last.time { plotted.append(last) }
            if trace.variant.configuration.usesIndependentClassifiers {
                for classifier in GestureClassifier.allCases {
                    let path = NSBezierPath()
                    var started = false
                    for sample in plotted {
                        guard let evidence = sample.classifiers.first(where: { $0.classifier == classifier }) else { continue }
                        let point = NSPoint(x: plot.minX + sample.time / duration * plot.width,
                                            y: plot.maxY - evidence.confidence * plot.height)
                        if started { path.line(to: point) } else { path.move(to: point); started = true }
                    }
                    let color = colors[classifier.intent == .pinch ? 0 : classifier.intent == .rotation ? 1 : 2]
                    color.withAlphaComponent(0.3).setStroke(); path.lineWidth = 0.75; path.stroke()
                }
            }
            for series in 0..<4 {
                let path = NSBezierPath()
                for (sampleIndex, sample) in plotted.enumerated() {
                    let value: Double = switch series {
                    case 0: sample.scores.pinch
                    case 1: sample.scores.rotation
                    case 2: sample.scores.movement
                    default: sample.confidence
                    }
                    let point = NSPoint(x: plot.minX + sample.time / duration * plot.width,
                                        y: plot.maxY - min(1, max(0, value)) * plot.height)
                    if sampleIndex == 0 { path.move(to: point) } else { path.line(to: point) }
                }
                path.lineWidth = series == 3 ? 1 : 1.7
                if series == 3 { path.setLineDash([3, 3], count: 2, phase: 0) }
                colors[series].withAlphaComponent(series == 3 ? 0.6 : 1).setStroke(); path.stroke()
            }
            if let time = trace.decisionTime {
                let x = plot.minX + time / duration * plot.width
                NSColor.secondaryLabelColor.setStroke()
                let marker = NSBezierPath(); marker.move(to: NSPoint(x: x, y: plot.minY)); marker.line(to: NSPoint(x: x, y: plot.maxY)); marker.stroke()
            }
            if let time = trace.rightClickTime {
                let x = plot.minX + time / duration * plot.width
                NSColor.systemRed.setStroke()
                let marker = NSBezierPath(); marker.move(to: NSPoint(x: x, y: plot.minY)); marker.line(to: NSPoint(x: x, y: plot.maxY)); marker.stroke()
            }
            if let time = trace.pressCueTime {
                let x = plot.minX + time / duration * plot.width
                NSColor.systemRed.withAlphaComponent(0.6).setStroke()
                let marker = NSBezierPath(); marker.setLineDash([2, 3], count: 2, phase: 0)
                marker.move(to: NSPoint(x: x, y: plot.minY)); marker.line(to: NSPoint(x: x, y: plot.maxY)); marker.stroke()
            }
            text("0", NSRect(x: plot.minX, y: plot.maxY + 5, width: 70, height: 15), color: .tertiaryLabelColor, size: 9)
            text(String(format: "%.2f s", duration), NSRect(x: plot.maxX - 55, y: plot.maxY + 5, width: 55, height: 15), color: .tertiaryLabelColor, size: 9)
            if let hover, let sample = trace.samples.min(by: { abs($0.time - hover) < abs($1.time - hover) }) {
                let x = plot.minX + hover / duration * plot.width
                NSColor.labelColor.withAlphaComponent(0.35).setStroke()
                let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: plot.minY)); line.line(to: NSPoint(x: x, y: plot.maxY)); line.stroke()
                text(String(format: "%.0f ms  P %.0f  T %.0f  S %.0f  C %.0f", sample.time * 1000, sample.scores.pinch * 100, sample.scores.rotation * 100,
                            sample.scores.movement * 100, sample.confidence * 100), NSRect(x: card.minX + 12, y: card.minY + 29, width: width - 24, height: 15))
            }
        }
    }
}

@MainActor
final class ClassifierComparisonController: NSObject {
    var onRightClick: ((UInt64?) -> Void)?
    var pointerOverPreview: (() -> Bool)?
    private let window: NSWindow
    private let charts = ConfidenceChartsView()
    private let devicePicker = NSPopUpButton()
    private let freeze = NSButton(checkboxWithTitle: "Freeze", target: nil, action: nil)
    private let sourceLabel = NSTextField(labelWithString: "Live · waiting for two contacts")
    private let rulesLabel = NSTextField(labelWithString: "Current classifier rules")
    private let rulesText = NSTextView()
    private var devices: [RecordedDevice] = []
    private var liveDevices: [RecordedDevice] = []
    private var selectedDeviceID: UInt64?
    private var replaying = false
    private var sourceTitle = "Live"
    private var comparison = ClassifierComparison()
    private var lastRevision: UInt64?
    private var lastDraw: TimeInterval = 0

    override init() {
        window = ConfidenceWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 830),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        (window as? ConfidenceWindow)?.onRightClick = { [weak self] in
            guard let self, !self.replaying else { return }
            if let onRightClick = self.onRightClick { onRightClick(self.selectedDeviceID) }
            else { self.comparison.receiveRightClick() }
        }
        window.title = "Classifier Comparison"
        window.minSize = NSSize(width: 840, height: 500)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ClassifierComparison")
        devicePicker.target = self; devicePicker.action = #selector(changeDevice)
        devicePicker.setAccessibilityLabel("Trackpad to compare")
        freeze.target = self; freeze.action = #selector(toggleFreeze)
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearTraces))
        clear.bezelStyle = .rounded
        let controls = NSStackView(views: [devicePicker, NSView(), freeze, clear]); controls.spacing = 12
        sourceLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let legend = NSStackView()
        for (name, color) in [("● Pinch", NSColor.systemTeal), ("● Tilt", .systemOrange), ("● Swipe", .systemPurple), ("┄ Confidence", .secondaryLabelColor)] {
            let label = NSTextField(labelWithString: name); label.textColor = color; legend.addArrangedSubview(label)
        }
        legend.spacing = 16
        let note = NSTextField(labelWithString: "Geometry scores, not calibrated probabilities · Vertical line: commitment · Hover to inspect")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let scroll = ConfidenceScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        charts.frame = NSRect(x: 0, y: 0, width: 1010, height: CGFloat((ClassifierVariant.comparisons.count + 1) / 2) * 176 + 12)
        charts.setAccessibilityLabel("Classifier confidence charts; Pinch, Tilt, Swipe, confidence and decision time")
        scroll.documentView = charts
        rulesLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        rulesText.isEditable = false; rulesText.isRichText = false
        rulesText.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        rulesText.textColor = .labelColor; rulesText.drawsBackground = false
        rulesText.textContainerInset = NSSize(width: 4, height: 4)
        rulesText.autoresizingMask = [.width]; rulesText.isHorizontallyResizable = false
        rulesText.textContainer?.widthTracksTextView = true
        rulesText.setAccessibilityLabel("Independent classifier evidence and suppression reasons")
        let rulesScroll = NSScrollView(); rulesScroll.hasVerticalScroller = true; rulesScroll.autohidesScrollers = true
        rulesScroll.drawsBackground = false; rulesScroll.documentView = rulesText
        charts.onInspect = { [weak self] inspection in self?.inspectRules(inspection) }
        let stack = NSStackView(views: [controls, sourceLabel, legend, note, scroll, rulesLabel, rulesScroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(stack); window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rulesLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            rulesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rulesScroll.heightAnchor.constraint(equalToConstant: 150)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        charts.traces = comparison.traces
    }

    private func inspectRules(_ inspection: ClassifierComparison.Inspection) {
        guard let sample = inspection.sample, !sample.classifiers.isEmpty else {
            rulesLabel.stringValue = "Current classifier rules"
            rulesText.string = "Waiting for two contacts"
            return
        }
        let committed = inspection.committedClassifier
        let decision = inspection.isVetoed ? " · Native right click veto" : committed.map { " · Locked: \($0.intent.title) / \($0.title)" } ?? ""
        let prior = sample.tiltPrior < 1 ? String(format: " · Tilt ×%.2f: held contact after cursor entry", sample.tiltPrior) : ""
        rulesLabel.stringValue = String(format: "Current classifier rules · %.0f ms", inspection.time * 1000) + decision + prior
        rulesText.string = sample.classifiers.map { evidence in
            let status: String
            if inspection.isVetoed { status = "Stopped by native right click" }
            else if evidence.isReady, let committed, committed != evidence.classifier {
                status = inspection.isCommitFrame ? "Ready; \(committed.title) takes priority" : "Ready; decision held by \(committed.title)"
            } else if evidence.isReady { status = "Ready" }
            else { status = evidence.blockers.joined(separator: "; ") }
            let name = "\(evidence.classifier.intent.title) / \(evidence.classifier.title)".padding(toLength: 40, withPad: " ", startingAt: 0)
            return String(format: "%@ %3.0f%%  %@", name, evidence.confidence * 100, status)
        }.joined(separator: "\n")
    }

    func show() {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func setDevices(_ devices: [RecordedDevice]) {
        liveDevices = devices
        if !replaying { updateDevices(devices) }
    }
    private func updateDevices(_ devices: [RecordedDevice]) {
        guard self.devices.count != devices.count || !zip(self.devices, devices).allSatisfy({ $0.id == $1.id && $0.name == $1.name && $0.sizeMM == $1.sizeMM }) else { return }
        self.devices = devices
        devicePicker.removeAllItems()
        for device in devices { devicePicker.addItem(withTitle: device.name) }
        if let selectedDeviceID, let index = devices.firstIndex(where: { $0.id == selectedDeviceID }) { devicePicker.selectItem(at: index) }
        else { selectedDeviceID = devices.first?.id; clearTraces() }
    }
    func beginReplay(devices: [RecordedDevice], title: String) {
        replaying = true; sourceTitle = "Replay · \(title)"; updateDevices(devices); clearTraces()
    }
    func endReplay() {
        replaying = false; sourceTitle += " · stopped"; updateDevices(liveDevices)
        comparison.finish(); lastRevision = nil
    }
    func receive(_ frame: ContactFrame, deviceID: UInt64) {
        guard !replaying else { return }
        if frame.contacts.filter(\.isTouching).count == 2 { sourceTitle = "Live" }
        ingest(deviceID: deviceID, time: frame.receivedAt, source: frame.sourceTimestamp,
               contacts: frame.contacts.filter(\.isTouching).map { ($0.id, $0.position, Double($0.angle), $0.radiiMM, Double($0.force)) }, pointerOverTarget: pointerOverPreview?())
    }
    func receive(_ frame: RecordedContactFrame) {
        guard replaying else { return }
        ingest(deviceID: frame.deviceID, time: frame.time, source: frame.sourceTimestamp,
               contacts: frame.contacts.filter { $0.stage == 3 || $0.stage == 4 }.map { ($0.id, $0.position, Double($0.angle), $0.radiiMM, Double($0.force)) }, pointerOverTarget: frame.pointerOverPreview)
    }
    func receiveRightClick(deviceID: UInt64?, at time: TimeInterval? = nil) {
        guard deviceID == nil || selectedDeviceID == deviceID else { return }
        comparison.receiveRightClick(at: time)
    }
    private func ingest(deviceID: UInt64, time: TimeInterval, source: TimeInterval,
                        contacts: [(Int32, CGPoint, Double, CGSize, Double)], pointerOverTarget: Bool?) {
        guard window.isVisible, deviceID == selectedDeviceID, let device = devices.first(where: { $0.id == deviceID }) else { return }
        comparison.receive(contacts.map { TransformContact(id: $0.0, positionMM: CGPoint(x: $0.1.x * device.sizeMM.width, y: $0.1.y * device.sizeMM.height), orientation: $0.2, radiiMM: $0.3, force: $0.4) },
                           at: time, sourceTimestamp: source, pointerOverTarget: pointerOverTarget)
    }
    func tick(at time: TimeInterval) {
        guard window.isVisible, freeze.state != .on, time - lastDraw >= 0.05, lastRevision != comparison.revision else { return }
        lastDraw = time; lastRevision = comparison.revision
        charts.traces = comparison.traces
        let decided = comparison.traces.filter { $0.decisionTime != nil }.count
        sourceLabel.stringValue = "\(sourceTitle) · \(comparison.isCollecting ? "Pair active" : decided > 0 ? "Last gesture" : "Waiting for two contacts") · \(decided)/\(comparison.traces.count) decided"
    }
    @objc private func changeDevice() {
        selectedDeviceID = devices.indices.contains(devicePicker.indexOfSelectedItem) ? devices[devicePicker.indexOfSelectedItem].id : nil
        clearTraces()
    }
    @objc private func toggleFreeze() { if freeze.state != .on { lastRevision = nil } }
    @objc private func clearTraces() {
        comparison.reset(); lastRevision = nil
        if freeze.state != .on { charts.traces = comparison.traces }
    }
    func close() { window.close() }
}
