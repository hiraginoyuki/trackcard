import AppKit
import TrackpadCore

@MainActor
final class TuningVisualizationScrollView: NSScrollView {
    override func tile() {
        super.tile()
        if let documentView, abs(documentView.frame.width - contentView.bounds.width) > 0.5 {
            documentView.setFrameSize(NSSize(width: contentView.bounds.width, height: documentView.frame.height))
        }
    }
}

/// Whole-motion thumbnails identify recordings; the inspector provides causal playback.
@MainActor
private final class TuningGestureTile: NSButton {
    let example: ClassifierTuningDataset.Example
    var result: ClassifierTuningDataset.Result
    var saved: ClassifierTuningDataset.Result
    var number: Int
    var selected = false { didSet { needsDisplay = true } }
    var ambiguous = false { didSet { needsDisplay = true; updateAccessibility() } }
    override var isFlipped: Bool { true }

    init(example: ClassifierTuningDataset.Example, saved: ClassifierTuningDataset.Result,
         result: ClassifierTuningDataset.Result, number: Int) {
        self.example = example; self.saved = saved; self.result = result; self.number = number
        super.init(frame: .zero)
        isBordered = false; title = ""; setButtonType(.momentaryChange)
        toolTip = example.ref + " · whole recorded motion · click to replay"
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateAccessibility() {
        setAccessibilityLabel("Gesture \(number), \(example.ref), \(result.decision == .undecided ? "no decision" : result.decision.title). Saved: \(saved.decision.title)." + (ambiguous ? " Either seems reasonable." : ""))
    }
    override func draw(_ dirtyRect: NSRect) {
        let tint: NSColor = result.decision == .rotation ? .systemOrange : .secondaryLabelColor
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.12) :
            result.decision == .rotation ? tint.withAlphaComponent(0.10) : NSColor.controlBackgroundColor).setFill()
        outline.fill()
        (selected ? NSColor.controlAccentColor : tint.withAlphaComponent(0.25)).setStroke()
        outline.lineWidth = selected ? 2 : 0.7; outline.stroke()
        func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, font: NSFont, color: NSColor) {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (value as NSString).draw(in: CGRect(x: x, y: y, width: width, height: 20), withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        text(String(number), x: 12, y: 10, width: 24, font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
        text(result.decision == .undecided ? "No decision" : result.decision.title,
             x: 38, y: 8, width: bounds.width - 48, font: .systemFont(ofSize: 14, weight: .semibold), color: tint)
        let points = example.frames.flatMap { $0.contacts.map(\.positionMM) }
        if let first = points.first {
            let minX = points.map(\.x).min() ?? first.x, maxX = points.map(\.x).max() ?? first.x
            let minY = points.map(\.y).min() ?? first.y, maxY = points.map(\.y).max() ?? first.y
            let area = CGRect(x: 18, y: 34, width: max(1, bounds.width - 36), height: 38)
            let scale = min(area.width / max(8, maxX - minX), area.height / max(8, maxY - minY))
            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: area.midX + (p.x - (minX + maxX) / 2) * scale,
                        y: area.midY - (p.y - (minY + maxY) / 2) * scale)
            }
            let ids = Set(example.frames.flatMap { $0.contacts.map(\.id) }).sorted()
            for (offset, id) in ids.enumerated() {
                let line = NSBezierPath(); var last: CGPoint?
                for frame in example.frames {
                    guard frame.contacts.count == 2, let contact = frame.contacts.first(where: { $0.id == id }) else { last = nil; continue }
                    let p = point(contact.positionMM)
                    if let last { line.move(to: last); line.line(to: p) }
                    last = p
                }
                let color: NSColor = offset.isMultiple(of: 2) ? .systemTeal : .systemPink
                color.setStroke(); line.lineWidth = 1.8; line.lineCapStyle = .round; line.stroke()
            }
        }
        let changed = saved.decision != result.decision
        text(changed ? "was \(saved.decision.title)" : example.ref, x: 12, y: 82, width: bounds.width - (ambiguous ? 62 : 24),
             font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
        if ambiguous {
            text("Either", x: bounds.width - 46, y: 82, width: 40, font: .systemFont(ofSize: 10, weight: .medium), color: .secondaryLabelColor)
        }
    }
}

/// The session is an overview first. Replays and other recordings open on demand.
@MainActor
final class TuningVisualizationView: NSView {
    private let scope = NSPopUpButton()
    private let gesture = NSPopUpButton()
    private let previous = NSButton(title: "‹", target: nil, action: nil)
    private let next = NSButton(title: "›", target: nil, action: nil)
    private let back = NSButton(title: "‹ Your Tilts", target: nil, action: nil)
    private let close = NSButton(title: "Close replay", target: nil, action: nil)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let controlsDetail = NSTextField(wrappingLabelWithString: "")
    private let judgment = NSButton(checkboxWithTitle: "Either seems reasonable", target: nil, action: nil)
    private let inspector = TuningReplayInspectorView()
    private var tiles: [TuningGestureTile] = []
    private var examples: [ClassifierTuningDataset.Example] = []
    private var baseline: [ClassifierTuningDataset.Result] = []
    private var candidates: [ClassifierTuningDataset.Result] = []
    private var session = ""
    private var deviceID = ""
    private var thresholds = TiltThresholds.standard
    private var baselineThresholds = TiltThresholds.standard
    private var sizeMM: CGSize?
    private var visibleIndices: [Int] = []
    private(set) var selectedIndex: Int?
    private var inspectingControls = false
    private var updating = false
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        scope.addItems(withTitles: ["Changed recordings", "Recorded Pinches", "Recorded Tilts", "Recorded Swipes"])
        scope.target = self; scope.action = #selector(changeScope); scope.setAccessibilityLabel("Other recordings to inspect")
        gesture.target = self; gesture.action = #selector(selectGesture); gesture.setAccessibilityLabel("Recorded gesture")
        previous.target = self; previous.action = #selector(selectPrevious); previous.setAccessibilityLabel("Previous gesture")
        next.target = self; next.action = #selector(selectNext); next.setAccessibilityLabel("Next gesture")
        back.target = self; back.action = #selector(showSession)
        close.target = self; close.action = #selector(closeReplay); close.bezelStyle = .inline
        detail.font = .systemFont(ofSize: 14, weight: .semibold); detail.isSelectable = true
        controlsDetail.font = .systemFont(ofSize: 12); controlsDetail.textColor = .secondaryLabelColor
        judgment.target = self; judgment.action = #selector(changeJudgment)
        inspector.onLayoutChange = { [weak self] in self?.needsLayout = true }
        for view in [scope, gesture, previous, next, back, close, detail, controlsDetail, judgment, inspector] { addSubview(view) }
        refreshVisibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(examples: [ClassifierTuningDataset.Example], baseline: [ClassifierTuningDataset.Result],
                   candidates: [ClassifierTuningDataset.Result], session: String, deviceID: String,
                   thresholds: TiltThresholds, sizeMM: CGSize?, baselineThresholds: TiltThresholds = .standard,
                   controlsSummary: String = "") {
        guard examples.count == baseline.count, examples.count == candidates.count else { return }
        let reference = selectedIndex.flatMap { self.examples.indices.contains($0) ? self.examples[$0].ref : nil }
        let selectedSession = selectedIndex.flatMap { self.examples.indices.contains($0) ? self.examples[$0].session : nil }
        self.examples = examples; self.baseline = baseline; self.candidates = candidates
        self.session = session; self.deviceID = deviceID; self.thresholds = thresholds
        self.baselineThresholds = baselineThresholds; self.sizeMM = sizeMM
        selectedIndex = examples.indices.first { examples[$0].ref == reference && examples[$0].session == selectedSession }
        controlsDetail.stringValue = controlsSummary
        for tile in tiles { tile.removeFromSuperview() }; tiles.removeAll()
        for (number, index) in examples.indices.filter({ examples[$0].session == session }).enumerated() {
            let tile = TuningGestureTile(example: examples[index], saved: baseline[index], result: candidates[index], number: number + 1)
            tile.tag = index; tile.target = self; tile.action = #selector(selectTile(_:))
            tile.ambiguous = UserDefaults.standard.bool(forKey: reviewKey(index))
            tile.isEnabled = !updating; tiles.append(tile); addSubview(tile)
        }
        rebuildMenu(preserveTime: reference != nil)
    }

    func setUpdating(_ value: Bool) {
        updating = value
        for tile in tiles { tile.isEnabled = !value }
        gesture.isEnabled = !value && !visibleIndices.isEmpty
        if value { stopPlayback() }
    }
    func showControls() {
        inspectingControls = true; selectedIndex = nil; scope.selectItem(at: 0)
        rebuildMenu(preserveTime: false); scroll(NSPoint.zero)
    }
    @objc private func showSession() {
        stopPlayback(); inspectingControls = false; selectedIndex = nil
        rebuildMenu(preserveTime: false); scroll(NSPoint.zero)
    }
    private func changed(_ index: Int) -> Bool {
        let a = baseline[index], b = candidates[index]
        return a.decision != b.decision || a.classifier != b.classifier ||
            (a.time == nil) != (b.time == nil) || abs((a.time ?? 0) - (b.time ?? 0)) > 1e-8
    }
    private func outcomeNote(_ index: Int) -> String {
        if baseline[index].isCorrect && !candidates[index].isCorrect { return " · New misread" }
        if !baseline[index].isCorrect && candidates[index].isCorrect { return " · Correction" }
        return ""
    }
    private func indices() -> [Int] {
        guard inspectingControls else { return examples.indices.filter { examples[$0].session == session } }
        let controls = examples.indices.filter { examples[$0].session != session && examples[$0].deviceID == deviceID }
        switch scope.indexOfSelectedItem {
        case 1: return controls.filter { examples[$0].label == "Pinch" }
        case 2: return controls.filter { examples[$0].label == "Tilt" }
        case 3: return controls.filter { examples[$0].label == "Swipe" }
        default:
            return controls.filter { changed($0) }.sorted {
                let lossA = baseline[$0].isCorrect && !candidates[$0].isCorrect
                let lossB = baseline[$1].isCorrect && !candidates[$1].isCorrect
                if lossA != lossB { return lossA }
                let delayA = (candidates[$0].time ?? 0) - (baseline[$0].time ?? 0)
                let delayB = (candidates[$1].time ?? 0) - (baseline[$1].time ?? 0)
                return abs(delayA - delayB) > 1e-8 ? delayA > delayB : examples[$0].ref < examples[$1].ref
            }
        }
    }
    private func rebuildMenu(preserveTime: Bool) {
        visibleIndices = indices()
        let oldSelection = selectedIndex
        if selectedIndex.map({ visibleIndices.contains($0) }) != true { selectedIndex = inspectingControls ? visibleIndices.first : nil }
        gesture.removeAllItems()
        for index in visibleIndices {
            let before = baseline[index], after = candidates[index]
            let decision = before.decision == after.decision ? after.decision.title : before.decision.title + " → " + after.decision.title
            let title = inspectingControls ?
                examples[index].ref + " · recorded " + examples[index].label + " · trying " + after.decision.title + outcomeNote(index) :
                examples[index].ref + " · " + decision
            gesture.addItem(withTitle: title)
            gesture.lastItem?.tag = index
        }
        updateSelection(preserveTime: preserveTime && oldSelection == selectedIndex)
    }
    func setDeviceSize(_ sizeMM: CGSize?) { self.sizeMM = sizeMM; inspector.setDeviceSize(sizeMM) }
    func stopPlayback() { inspector.stopPlayback() }
    @objc private func changeScope() { stopPlayback(); selectedIndex = nil; rebuildMenu(preserveTime: false) }
    @objc private func selectGesture() { selectedIndex = gesture.selectedItem?.tag; updateSelection(preserveTime: false) }
    @objc private func selectPrevious() { moveSelection(-1) }
    @objc private func selectNext() { moveSelection(1) }
    private func moveSelection(_ offset: Int) {
        guard let selectedIndex, let position = visibleIndices.firstIndex(of: selectedIndex), visibleIndices.indices.contains(position + offset) else { return }
        self.selectedIndex = visibleIndices[position + offset]; updateSelection(preserveTime: false)
    }
    @objc private func selectTile(_ sender: NSButton) {
        guard !updating else { return }
        selectedIndex = sender.tag; updateSelection(preserveTime: false)
        layoutSubtreeIfNeeded(); scrollToVisible(inspector.frame.insetBy(dx: 0, dy: -42))
        inspector.playFromStart()
    }
    @objc private func closeReplay() {
        stopPlayback(); selectedIndex = nil; updateSelection(preserveTime: false)
        layoutSubtreeIfNeeded(); scroll(NSPoint.zero)
    }
    private func reviewKey(_ index: Int) -> String { "tuning.review." + examples[index].session + "." + examples[index].deviceID + "." + examples[index].ref }
    @objc private func changeJudgment() {
        guard let selectedIndex else { return }
        UserDefaults.standard.set(judgment.state == .on, forKey: reviewKey(selectedIndex))
        tiles.first { $0.tag == selectedIndex }?.ambiguous = judgment.state == .on
    }
    private func refreshVisibility() {
        for tile in tiles { tile.isHidden = inspectingControls }
        for view in [scope, gesture, back, controlsDetail] as [NSView] { view.isHidden = !inspectingControls }
        let hasSelection = selectedIndex != nil
        inspector.isHidden = !hasSelection
        detail.isHidden = !hasSelection && !inspectingControls
        for view in [previous, next, close] { view.isHidden = !hasSelection }
        close.isHidden = !hasSelection || inspectingControls
        judgment.isHidden = !hasSelection || inspectingControls
    }
    private func updateSelection(preserveTime: Bool) {
        refreshVisibility()
        for tile in tiles { tile.selected = tile.tag == selectedIndex }
        guard let selectedIndex else {
            detail.stringValue = "No changes to other recordings with this preference."
            inspector.stopPlayback(); gesture.isEnabled = false; previous.isEnabled = false; next.isEnabled = false
            needsLayout = true; return
        }
        gesture.isEnabled = !updating; gesture.selectItem(withTag: selectedIndex)
        let position = visibleIndices.firstIndex(of: selectedIndex) ?? 0
        previous.isEnabled = position > 0; next.isEnabled = position + 1 < visibleIndices.count
        let example = examples[selectedIndex], result = candidates[selectedIndex], before = baseline[selectedIndex]
        judgment.state = UserDefaults.standard.bool(forKey: reviewKey(selectedIndex)) ? .on : .off
        inspector.configure(example: example, thresholds: thresholds, sizeMM: sizeMM, preserveTime: preserveTime,
                            baselineThresholds: baselineThresholds, usesSavedBaseline: true)
        let number = tiles.first { $0.tag == selectedIndex }?.number
        if inspectingControls {
            detail.stringValue = "Recorded \(example.label) · trying \(result.decision.title)" + outcomeNote(selectedIndex) +
                "\nSaved \(before.decision.title) · \(example.ref)"
        } else {
            detail.stringValue = (number.map { "Gesture \($0)" } ?? example.ref) + " · saved \(before.decision.title) → trying \(result.decision.title)"
        }
        needsLayout = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }
        var y: CGFloat = 0
        if inspectingControls {
            back.frame = CGRect(x: 0, y: 0, width: 128, height: 32)
            scope.frame = CGRect(x: 140, y: 0, width: max(160, width - 140), height: 32)
            controlsDetail.frame = CGRect(x: 4, y: 40, width: width - 8, height: 36)
            gesture.frame = CGRect(x: 0, y: 80, width: width, height: 32)
            y = 124
        } else {
            let columns = max(2, min(5, Int((width + 10) / 145)))
            let tileWidth = (width - CGFloat(columns - 1) * 10) / CGFloat(columns)
            for (offset, tile) in tiles.enumerated() {
                tile.frame = CGRect(x: CGFloat(offset % columns) * (tileWidth + 10), y: CGFloat(offset / columns) * 114,
                                    width: tileWidth, height: 104)
            }
            y = CGFloat((tiles.count + columns - 1) / columns) * 114
        }
        if !detail.isHidden {
            let detailHeight: CGFloat = inspectingControls ? 48 : 28
            detail.frame = CGRect(x: 4, y: y, width: max(1, width - 100), height: detailHeight)
            previous.frame = CGRect(x: width - 88, y: y - 2, width: 40, height: 32)
            next.frame = CGRect(x: width - 40, y: y - 2, width: 40, height: 32)
            y += detailHeight + 6
            if !judgment.isHidden {
                judgment.frame = CGRect(x: 4, y: y, width: 230, height: 28)
                close.frame = CGRect(x: width - 100, y: y, width: 100, height: 28)
                y += 34
            }
        }
        let height = inspector.isHidden ? 0 : inspector.requiredHeight(width: width)
        inspector.frame = CGRect(x: 0, y: y, width: width, height: height)
        let documentHeight = max(1, y + height)
        if abs(frame.height - documentHeight) > 0.5 { setFrameSize(CGSize(width: width, height: documentHeight)) }
    }
}
