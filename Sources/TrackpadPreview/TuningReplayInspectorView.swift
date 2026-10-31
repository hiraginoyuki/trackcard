import AppKit
import TrackpadCore

@MainActor
private final class TuningMotionView: NSView {
    var replay: TuningGestureReplay?
    var sampleIndex = 0
    var sizeMM: CGSize?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let replay, replay.samples.indices.contains(sampleIndex) else { return }
        let allPoints = replay.samples.flatMap { $0.contacts.map(\.positionMM) }
        let physical: CGRect
        if let sizeMM, sizeMM.width.isFinite, sizeMM.height.isFinite, sizeMM.width > 0, sizeMM.height > 0 {
            physical = CGRect(origin: .zero, size: sizeMM)
        } else {
            let minX = (allPoints.map(\.x).min() ?? 0) - 8
            let minY = (allPoints.map(\.y).min() ?? 0) - 8
            physical = CGRect(x: minX, y: minY,
                width: max(16, (allPoints.map(\.x).max() ?? 0) - minX + 8),
                height: max(16, (allPoints.map(\.y).max() ?? 0) - minY + 8))
        }
        let scale = min(max(1, bounds.width - 16) / physical.width, max(1, bounds.height - 20) / physical.height)
        let pad = CGRect(x: (bounds.width - physical.width * scale) / 2, y: 8,
                         width: physical.width * scale, height: physical.height * scale)
        let outline = NSBezierPath(roundedRect: pad, xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill(); outline.fill()
        NSColor.separatorColor.setStroke(); outline.lineWidth = 0.5; outline.stroke()
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: pad.minX + (p.x - physical.minX) * scale, y: pad.maxY - (p.y - physical.minY) * scale)
        }
        let ids = Set(replay.samples.flatMap { $0.contacts.map(\.id) }).sorted()
        let colors: [NSColor] = [.systemTeal, .systemPink, .systemPurple]
        func color(_ id: Int32) -> NSColor { colors[(ids.firstIndex(of: id) ?? 0) % colors.count] }
        NSGraphicsContext.saveGraphicsState(); outline.addClip()
        for id in ids {
            for afterCommit in [false, true] {
                let line = NSBezierPath(); var drawing = false
                for index in 1...max(1, sampleIndex) where index <= sampleIndex {
                    let before = replay.samples[index - 1], after = replay.samples[index]
                    let committed = replay.previewDecision.map { index > $0.sampleIndex } ?? false
                    guard before.segment == after.segment, committed == afterCommit,
                          let previous = before.contacts.first(where: { $0.id == id }),
                          let contact = after.contacts.first(where: { $0.id == id }) else { drawing = false; continue }
                    if !drawing { line.move(to: point(previous.positionMM)); drawing = true }
                    line.line(to: point(contact.positionMM))
                }
                color(id).setStroke(); line.lineWidth = 1.5; line.lineCapStyle = .round
                if afterCommit { line.setLineDash([3, 3], count: 2, phase: 0) }
                line.stroke()
            }
        }
        for (event, preview) in [(replay.baselineDecision, false), (replay.previewDecision, true)] {
            guard let event, event.sampleIndex <= sampleIndex else { continue }
            for contact in replay.samples[event.sampleIndex].contacts {
                let p = point(contact.positionMM)
                let marker = NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                if preview { color(contact.id).setFill(); marker.fill() }
                else { NSColor.labelColor.setStroke(); marker.lineWidth = 1; marker.stroke() }
            }
        }
        let current = replay.samples[sampleIndex]
        if current.contacts.count == 2 {
            let vector = NSBezierPath(); vector.move(to: point(current.contacts[0].positionMM)); vector.line(to: point(current.contacts[1].positionMM))
            NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke(); vector.lineWidth = 0.75; vector.stroke()
        }
        for contact in current.contacts {
            let p = point(contact.positionMM)
            color(contact.id).setFill(); NSBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill()
            NSColor.controlBackgroundColor.setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)); ring.lineWidth = 1; ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class TuningEvidenceChartView: NSView {
    var replay: TuningGestureReplay?
    var sampleIndex = 0
    var showsBaseline = false { didSet { needsDisplay = true } }
    var showsReadiness = false { didSet { needsDisplay = true } }
    var onScrub: ((TimeInterval) -> Void)?
    override var isFlipped: Bool { true }

    private func scrub(_ event: NSEvent) {
        guard let replay else { return }
        let p = convert(event.locationInWindow, from: nil)
        let fraction = min(1, max(0, (p.x - 82) / max(1, bounds.width - 94)))
        onScrub?(replay.startTime + fraction * (replay.endTime - replay.startTime))
    }
    override func mouseDown(with event: NSEvent) { scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }

    override func draw(_ dirtyRect: NSRect) {
        guard let replay, replay.samples.indices.contains(sampleIndex) else { return }
        let duration = max(0.001, replay.endTime - replay.startTime)
        let left: CGFloat = 82, width = max(1, bounds.width - 94)
        func x(_ time: Double) -> CGFloat { left + (time - replay.startTime) / duration * width }
        func text(_ value: String, _ rect: CGRect, color: NSColor = .secondaryLabelColor) {
            (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: color])
        }
        let current = replay.samples[sampleIndex]
        for (row, entry) in [("Spacing", "mm", \TuningGestureReplay.Sample.spacingChange, NSColor.systemTeal),
                             ("Turn", "°", \TuningGestureReplay.Sample.turnDegrees, NSColor.systemOrange)].enumerated() {
            let top = CGFloat(row) * 57 + 8
            let values = replay.samples.compactMap { $0[keyPath: entry.2] }
            let low = min(0, values.min() ?? 0), high = max(0.1, values.max() ?? 0)
            let span = max(0.1, high - low)
            func y(_ value: Double) -> CGFloat { top + 38 - (value - low) / span * 36 }
            text(entry.0, CGRect(x: 0, y: top, width: 78, height: 14))
            text(current[keyPath: entry.2].map { String(format: "%+.1f %@", $0, entry.1) } ?? "—", CGRect(x: 0, y: top + 16, width: 78, height: 14), color: .labelColor)
            NSColor.separatorColor.setStroke()
            let zero = NSBezierPath(); zero.move(to: CGPoint(x: left, y: y(0))); zero.line(to: CGPoint(x: left + width, y: y(0))); zero.lineWidth = 0.5; zero.stroke()
            var previous: TuningGestureReplay.Sample?
            for sample in replay.samples {
                if let previous, previous.segment == sample.segment,
                   let a = previous[keyPath: entry.2], let b = sample[keyPath: entry.2] {
                    let line = NSBezierPath(); line.move(to: CGPoint(x: x(previous.time), y: y(a))); line.line(to: CGPoint(x: x(sample.time), y: y(b)))
                    entry.3.withAlphaComponent(sample.time <= current.time ? 1 : 0.25).setStroke(); line.lineWidth = 1.5; line.stroke()
                }
                previous = sample
            }
        }
        if showsReadiness {
        for (row, intent) in [ContactTransform.Intent.pinch, .rotation].enumerated() {
            let y: CGFloat = 124 + CGFloat(row) * 16
            text(intent.title + " ready", CGRect(x: 0, y: y - 2, width: 80, height: 14))
            for index in replay.samples.indices where index + 1 < replay.samples.count {
                let sample = replay.samples[index]
                let state = showsBaseline ? sample.baseline : sample.preview
                guard state.checks.contains(where: { $0.classifier.intent == intent && $0.isReady }) else { continue }
                (intent == .pinch ? NSColor.systemTeal : .systemOrange).withAlphaComponent(0.65).setFill()
                CGRect(x: x(sample.time), y: y, width: max(1, x(replay.samples[index + 1].time) - x(sample.time)), height: 8).fill()
            }
        }
        }
        let bottom: CGFloat = showsReadiness ? 151 : 120
        for (event, color) in [(replay.baselineDecision, NSColor.secondaryLabelColor), (replay.previewDecision, .systemBlue)] {
            guard let event else { continue }
            color.setStroke(); let line = NSBezierPath(); line.move(to: CGPoint(x: x(event.time), y: 4)); line.line(to: CGPoint(x: x(event.time), y: bottom)); line.lineWidth = 1; line.setLineDash([3, 3], count: 2, phase: 0); line.stroke()
        }
        NSColor.labelColor.setStroke()
        let cursor = NSBezierPath(); cursor.move(to: CGPoint(x: x(current.time), y: 4)); cursor.line(to: CGPoint(x: x(current.time), y: bottom)); cursor.lineWidth = 1; cursor.stroke()
        text(String(format: "%.0f", replay.startTime * 1000), CGRect(x: left, y: bottom + 6, width: 70, height: 14))
        text(String(format: "%.0f ms", replay.endTime * 1000), CGRect(x: left + width - 52, y: bottom + 6, width: 65, height: 14))
    }
}

@MainActor
final class TuningReplayInspectorView: NSView {
    var onLayoutChange: (() -> Void)?
    private var usesSavedBaseline = false
    private let detailsButton = NSButton(checkboxWithTitle: "Recognition details", target: nil, action: nil)
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let speed = NSPopUpButton()
    private let cursor = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "")
    private let baselineButton = NSButton(title: "Baseline", target: nil, action: nil)
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let tiltButton = NSButton(title: "Tilt ready", target: nil, action: nil)
    private let motion = TuningMotionView()
    private let chart = TuningEvidenceChartView()
    private let legend = NSTextField(labelWithString: "Dashed: after commitment · Faint: later recording · ○ Baseline · ● Preview")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let evidenceMode = NSSegmentedControl(labels: ["Baseline rules", "Preview rules"], trackingMode: .selectOne, target: nil, action: nil)
    private let pinchPath = NSPopUpButton()
    private let tiltPath = NSPopUpButton()
    private let pinchRules = NSTextField(wrappingLabelWithString: "")
    private let tiltRules = NSTextField(wrappingLabelWithString: "")
    private(set) var replay: TuningGestureReplay?
    private(set) var sampleIndex = 0
    private var timer: Timer?
    private var playbackStart: TimeInterval = 0
    private var playbackTime: TimeInterval = 0
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        playButton.target = self; playButton.action = #selector(togglePlayback)
        for (index, title) in ["0.25×", "0.5×", "1×"].enumerated() { speed.addItem(withTitle: title); speed.lastItem?.tag = [25, 50, 100][index] }
        speed.selectItem(at: 1); speed.target = self; speed.action = #selector(stopPlayback)
        speed.setAccessibilityLabel("Replay speed")
        cursor.target = self; cursor.action = #selector(scrub); cursor.isContinuous = true; cursor.setAccessibilityLabel("Recorded gesture time")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); timeLabel.alignment = .right
        for (button, action) in [(baselineButton, #selector(jumpBaseline)), (previewButton, #selector(jumpPreview)), (tiltButton, #selector(jumpTilt))] {
            button.target = self; button.action = action; button.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        }
        chart.onScrub = { [weak self] time in self?.stopPlayback(); self?.seek(to: time) }
        legend.font = .systemFont(ofSize: 10); legend.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: 12, weight: .medium)
        evidenceMode.selectedSegment = 1; evidenceMode.target = self; evidenceMode.action = #selector(changeEvidence)
        for (picker, intent) in [(pinchPath, ContactTransform.Intent.pinch), (tiltPath, .rotation)] {
            picker.addItem(withTitle: intent.title + " · automatic")
            for path in GestureClassifier.allCases where path.intent == intent { picker.addItem(withTitle: path.title); picker.lastItem?.representedObject = path.rawValue }
            picker.target = self; picker.action = #selector(changeEvidence); picker.setAccessibilityLabel(intent.title + " recognition path")
        }
        for label in [pinchRules, tiltRules] { label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); label.isSelectable = true }
        motion.setAccessibilityElement(true); motion.setAccessibilityRole(.image); motion.setAccessibilityLabel("Recorded finger positions and observed paths")
        chart.setAccessibilityElement(true); chart.setAccessibilityRole(.image); chart.setAccessibilityLabel("Spacing, turning, and rule readiness over recorded time")
        detailsButton.target = self; detailsButton.action = #selector(toggleDetails)
        for view in [playButton, speed, cursor, timeLabel, baselineButton, previewButton, tiltButton, motion, chart,
                     legend, explanation, detailsButton, evidenceMode, pinchPath, tiltPath, pinchRules, tiltRules] { addSubview(view) }
        for view in [evidenceMode, pinchPath, tiltPath, pinchRules, tiltRules] as [NSView] { view.isHidden = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(example: ClassifierTuningDataset.Example, thresholds: TiltThresholds, sizeMM: CGSize?, preserveTime: Bool,
                   baselineThresholds: TiltThresholds = .standard, usesSavedBaseline: Bool = false) {
        self.usesSavedBaseline = usesSavedBaseline
        evidenceMode.setLabel(usesSavedBaseline ? "Saved rules" : "Baseline rules", forSegment: 0)
        evidenceMode.setLabel(usesSavedBaseline ? "Trying rules" : "Preview rules", forSegment: 1)
        legend.stringValue = usesSavedBaseline ? "○ Saved · ● Trying · Dashed path: after decision · Faint: later motion" :
            "○ Baseline · ● Preview · Dashed path: after decision · Faint: later motion"
        let time = preserveTime ? replay.flatMap { $0.samples.indices.contains(sampleIndex) ? $0.samples[sampleIndex].time : nil } : nil
        stopPlayback()
        let replay = TuningGestureReplay(example: example, thresholds: thresholds, baselineThresholds: baselineThresholds)
        self.replay = replay; motion.replay = replay; motion.sizeMM = sizeMM; chart.replay = replay
        cursor.minValue = replay.startTime; cursor.maxValue = max(replay.startTime + 0.001, replay.endTime)
        playButton.isEnabled = replay.samples.count > 1
        cursor.isEnabled = !replay.samples.isEmpty; speed.isEnabled = playButton.isEnabled
        for control in [evidenceMode, pinchPath, tiltPath] as [NSControl] { control.isEnabled = !replay.samples.isEmpty }
        func configure(_ button: NSButton, _ event: TuningGestureReplay.Event?, prefix: String) {
            button.isEnabled = event != nil
            button.title = prefix + (event.map { " · \($0.intent.title) \(milliseconds($0.time))" } ?? " · —")
            button.toolTip = event.map { "\($0.classifier?.title ?? "") · contact pair +\(milliseconds($0.elapsed))" }
        }
        configure(baselineButton, replay.baselineDecision, prefix: usesSavedBaseline ? "Saved" : "Baseline")
        configure(previewButton, replay.previewDecision, prefix: usesSavedBaseline ? "Trying" : "Preview")
        tiltButton.title = replay.firstTiltReady.map { "Turning qualifies · \(milliseconds($0.time))" } ?? "Turning stays below Tilt threshold"
        tiltButton.isEnabled = replay.firstTiltReady != nil; tiltButton.toolTip = replay.firstTiltReady?.classifier?.title
        if let decision = replay.previewDecision {
            if decision.intent != .rotation, let tilt = replay.firstTiltReady, tilt.time > decision.time + 1e-9 {
                explanation.stringValue = "\(decision.intent.title) chosen at \(milliseconds(decision.time)). Turning qualified for Tilt \(milliseconds(tilt.time - decision.time)) later."
            } else if decision.intent != .rotation, replay.firstTiltReady == nil {
                explanation.stringValue = "\(decision.intent.title) chosen at \(milliseconds(decision.time)). Turning stayed below the Tilt threshold for this pair."
            } else { explanation.stringValue = "\(decision.intent.title) recognized at \(milliseconds(decision.time))." }
        } else { explanation.stringValue = "This setting leaves the recording undecided." }
        if !preserveTime { pinchPath.selectItem(at: 0); tiltPath.selectItem(at: 0) }
        seek(to: time ?? replay.previewDecision?.time ?? replay.startTime)
    }

    func setDeviceSize(_ sizeMM: CGSize?) { motion.sizeMM = sizeMM; motion.needsDisplay = true }
    private func milliseconds(_ time: TimeInterval) -> String { String(format: "%.0f ms", time * 1000) }

    func seek(to time: TimeInterval) {
        guard let replay, let index = replay.index(at: time) else {
            sampleIndex = 0; cursor.doubleValue = cursor.minValue
            timeLabel.stringValue = "No captured frames"
            motion.sampleIndex = 0; chart.sampleIndex = 0
            motion.needsDisplay = true; chart.needsDisplay = true
            motion.setAccessibilityValue("No captured frames"); chart.setAccessibilityValue("No captured frames")
            updateRules(); needsLayout = true; superview?.needsLayout = true
            return
        }
        sampleIndex = index; cursor.doubleValue = replay.samples[index].time
        timeLabel.stringValue = "\(milliseconds(replay.samples[index].time)) / \(milliseconds(replay.endTime))"
        motion.sampleIndex = index; chart.sampleIndex = index; motion.needsDisplay = true; chart.needsDisplay = true
        let sample = replay.samples[index]
        let description = "\(milliseconds(sample.time)), \(sample.contacts.count) contacts" +
            (sample.spacingChange.map { String(format: ", spacing %+.1f mm", $0) } ?? "") +
            (sample.turnDegrees.map { String(format: ", turn %+.1f degrees", $0) } ?? "")
        motion.setAccessibilityValue(description); chart.setAccessibilityValue(description)
        updateRules(); needsLayout = true; superview?.needsLayout = true
    }

    @objc private func scrub() { stopPlayback(); seek(to: cursor.doubleValue) }
    @objc private func jumpBaseline() { stopPlayback(); if let event = replay?.baselineDecision { seek(to: event.time) } }
    @objc private func jumpPreview() { stopPlayback(); if let event = replay?.previewDecision { seek(to: event.time) } }
    @objc private func jumpTilt() { stopPlayback(); if let event = replay?.firstTiltReady { seek(to: event.time) } }
    @objc private func changeEvidence() { updateRules(); needsLayout = true; superview?.needsLayout = true }

    private func updateRules() {
        let baselineRules = evidenceMode.selectedSegment == 0
        chart.showsBaseline = baselineRules
        let profile = baselineRules ? (usesSavedBaseline ? "saved" : "baseline") : (usesSavedBaseline ? "trying" : "preview")
        chart.setAccessibilityLabel(detailsButton.state == .on ? "Spacing, turning, and \(profile) rule readiness over recorded time" : "Spacing and turning over recorded time")
        guard let replay, replay.samples.indices.contains(sampleIndex) else { pinchRules.stringValue = "No captured frames"; tiltRules.stringValue = ""; return }
        let state = baselineRules ? replay.samples[sampleIndex].baseline : replay.samples[sampleIndex].preview
        func description(_ picker: NSPopUpButton, intent: ContactTransform.Intent) -> String {
            let paths = state.checks.filter { $0.classifier.intent == intent }
            let explicit = (picker.selectedItem?.representedObject as? String).flatMap(GestureClassifier.init(rawValue:))
            if let explicit, !paths.contains(where: { $0.classifier == explicit }) { return state.isTracking ? "Path unavailable" : "Pair not active" }
            let segment = replay.samples[sampleIndex].segment
            let eventual = replay.samples.lazy.filter { $0.segment == segment }.compactMap { sample in
                (baselineRules ? sample.baseline : sample.preview).checks.first { $0.classifier.intent == intent && $0.isReady }?.classifier
            }.first
            let selected = paths.first { $0.classifier == (explicit ?? eventual) } ?? paths.max {
                $0.confidence == $1.confidence ? $0.progress < $1.progress : $0.confidence < $1.confidence
            }
            guard let selected else { return state.isTracking ? "Collecting motion…" : "Pair not active" }
            var lines = [selected.classifier.title]
            if selected.isReady { lines.append("Ready") }
            else if selected.checks.allSatisfy(\.passed) {
                if selected.persistenceRemaining > 1e-9 { lines.append("Sustain for \(milliseconds(selected.persistenceRemaining)) more") }
                if selected.observationRemaining > 1e-9 { lines.append("Observe for \(milliseconds(selected.observationRemaining)) more") }
            } else { lines.append("\(selected.checks.filter { !$0.passed }.count) conditions unmet") }
            let visible = selected.checks.filter { !$0.name.hasSuffix("enabled") }
            let shown = selected.isReady ? visible : visible.filter { !$0.passed }
            lines += shown.map { check in
                let label: String
                switch check.name {
                case "Tangential coordination after prior": label = "Turning coordination"
                case "Turn angle after prior": label = "Effective turn"
                case "Angular velocity agrees with turn direction": return (check.passed ? "✓ " : "· ") + "Turning in the same direction: " + (check.passed ? "yes" : "no")
                case "Radial velocity agrees with spacing direction": return (check.passed ? "✓ " : "· ") + "Moving in the spacing direction: " + (check.passed ? "yes" : "no")
                case "Spacing change":
                    return String(format: "%@Spacing change factor: %.3g (needs %@ %.3g)", check.passed ? "✓ " : "· ", exp(check.value), check.comparison.rawValue, exp(check.threshold))
                default: label = check.name
                }
                return (check.passed ? "✓ " : "· ") + String(format: "%@: %.3g (needs %@ %.3g%@)", label, check.value, check.comparison.rawValue, check.threshold, check.unit.isEmpty ? "" : " " + check.unit)
            }
            if !selected.isReady && selected.checks.allSatisfy(\.passed) { lines.append("All measured conditions met") }
            return lines.joined(separator: "\n")
        }
        pinchRules.stringValue = description(pinchPath, intent: .pinch)
        tiltRules.stringValue = description(tiltPath, intent: .rotation)
    }

    @objc private func togglePlayback() {
        guard let replay, replay.samples.count > 1 else { return }
        if timer != nil { stopPlayback(); return }
        if cursor.doubleValue >= replay.endTime - 1e-9 { seek(to: replay.startTime) }
        playbackTime = cursor.doubleValue; playbackStart = ProcessInfo.processInfo.systemUptime
        playButton.title = "Pause"
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advancePlayback() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func advancePlayback() {
        guard let replay else { stopPlayback(); return }
        let time = playbackTime + (ProcessInfo.processInfo.systemUptime - playbackStart) * Double(speed.selectedTag()) / 100
        seek(to: min(time, replay.endTime))
        if time >= replay.endTime { stopPlayback() }
    }
    @objc func stopPlayback() { timer?.invalidate(); timer = nil; playButton.title = "Play" }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { stopPlayback() }; super.viewWillMove(toWindow: newWindow) }

    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        ceil((label.stringValue as NSString).boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!]).height) + 4
    }
    func playFromStart() {
        stopPlayback()
        guard let replay, replay.samples.count > 1 else { return }
        seek(to: replay.startTime); togglePlayback()
    }
    @objc private func toggleDetails() {
        let expanded = detailsButton.state == .on
        for view in [evidenceMode, pinchPath, tiltPath, pinchRules, tiltRules] as [NSView] { view.isHidden = !expanded }
        chart.showsReadiness = expanded
        updateRules()
        needsLayout = true; onLayoutChange?()
    }
    func requiredHeight(width: CGFloat) -> CGFloat {
        let plots: CGFloat = width >= 650 ? 184 : 354
        let basic = 42 + plots + 24 + 34 + textHeight(explanation, width: width - 8) + 44
        return basic + (detailsButton.state == .on ? 70 +
            max(textHeight(pinchRules, width: (width - 28) / 2), textHeight(tiltRules, width: (width - 28) / 2)) + 8 : 0)
    }
    override func layout() {
        super.layout()
        let width = bounds.width, half = (width - 12) / 2
        playButton.frame = CGRect(x: 0, y: 0, width: 64, height: 32)
        speed.frame = CGRect(x: 72, y: 0, width: 72, height: 32)
        timeLabel.frame = CGRect(x: max(150, width - 132), y: 7, width: 132, height: 18)
        cursor.frame = CGRect(x: 154, y: 1, width: max(20, width - 298), height: 30)
        var y: CGFloat = 42
        if width >= 650 {
            motion.frame = CGRect(x: 0, y: y, width: half, height: 184)
            chart.frame = CGRect(x: half + 12, y: y, width: half, height: 184); y += 184
        } else {
            motion.frame = CGRect(x: 0, y: y, width: width, height: 174); y += 174
            chart.frame = CGRect(x: 0, y: y, width: width, height: 180); y += 180
        }
        legend.frame = CGRect(x: 4, y: y, width: width - 8, height: 18); y += 24
        let eventWidth = (width - 12) / 3
        for (index, button) in [baselineButton, previewButton, tiltButton].enumerated() {
            button.frame = CGRect(x: CGFloat(index) * (eventWidth + 6), y: y, width: eventWidth, height: 28)
        }
        y += 34
        explanation.frame = CGRect(x: 4, y: y, width: width - 8, height: textHeight(explanation, width: width - 8)); y = explanation.frame.maxY + 10
        detailsButton.frame = CGRect(x: 0, y: y, width: 200, height: 28); y += 34
        guard detailsButton.state == .on else { return }
        evidenceMode.frame = CGRect(x: 0, y: y, width: min(280, width), height: 25); y += 32
        pinchPath.frame = CGRect(x: 0, y: y, width: half, height: 26)
        tiltPath.frame = CGRect(x: half + 12, y: y, width: half, height: 26); y += 28
        pinchRules.frame = CGRect(x: 4, y: y, width: half - 8, height: textHeight(pinchRules, width: half - 8))
        tiltRules.frame = CGRect(x: half + 16, y: y, width: half - 8, height: textHeight(tiltRules, width: half - 8))
    }
}
