import AppKit
import TrackpadCore

private final class RecorderWindow: NSWindow {
    var pressSpace: ((Bool) -> Void)?
    var recordGesture: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 49,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if !event.isARepeat { pressSpace?(event.modifierFlags.contains(.shift)) }
            return
        }
        if recordGesture?(event) == true { return }
        super.sendEvent(event)
    }
}

private final class RecordingRow: NSObject {
    struct ContactSummary {
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var samples = 0
        var deviceCount = 0
    }
    var group: GestureContactGroup?
    var contact: GestureContactIdentity?
    var attempt: GestureAttempt?
    var interval: GestureInterval?
    weak var parent: RecordingRow?
    var children: [RecordingRow] = []
    var contactSummary = ContactSummary()
    var saving = false
    var id: String { group?.id.uuidString ?? attempt?.id.uuidString ?? interval?.id.uuidString ?? "\(containingAttempt!.id)/\(contact!.id)" }
    var containingGroup: GestureContactGroup? { group ?? parent?.containingGroup }
    var containingAttempt: GestureAttempt? { attempt ?? parent?.containingAttempt }
    var sessionRow: RecordingRow? { attempt != nil ? self : parent?.sessionRow }
    var contactIDs: Set<String> { contact.map { [$0.id] } ?? (group.map { Set($0.contactIDs) } ?? []) }
    var start: TimeInterval { interval?.start ?? contact?.start ?? (group != nil ? contactSummary.start : children.map(\.start).min() ?? 0) }
    var end: TimeInterval { interval?.end ?? contact?.end ?? (group != nil ? contactSummary.end : children.map(\.end).max() ?? 0) }
    init(group: GestureContactGroup) { self.group = group }
    init(contact: GestureContactIdentity) { self.contact = contact }
    init(attempt: GestureAttempt) { self.attempt = attempt }
    init(interval: GestureInterval) { self.interval = interval }
    func update(_ attempt: GestureAttempt) {
        self.attempt = attempt
    }
    func updateContactSummary() {
        let contacts = children.compactMap(\.contact)
        contactSummary = ContactSummary(start: contacts.map(\.start).min() ?? 0,
                                        end: contacts.map(\.end).max() ?? 0,
                                        samples: contacts.reduce(0) { $0 + $1.samples },
                                        deviceCount: Set(contacts.map(\.deviceID)).count)
    }
}

private final class RecordingOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0, !selectedRowIndexes.contains(index) {
            selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }

    private func groupIndent(at row: Int) -> CGFloat {
        (item(atRow: row) as? RecordingRow)?.parent?.group == nil ? 0 : indentationPerLevel
    }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        if column == tableColumns.firstIndex(where: { $0 === outlineTableColumn }) {
            let indent = groupIndent(at: row)
            frame.origin.x -= indent; frame.size.width += indent
        }
        return frame
    }
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x -= groupIndent(at: row)
        return frame
    }
}

private final class CategoryPopUp: NSPopUpButton {
    weak var row: RecordingRow?
    var isCounterexample = false
}

private final class SessionStateSymbolView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class SessionStateButton: NSButton {
    weak var row: RecordingRow?
    var marking = GestureSessionState.unmarked
    let symbolView = SessionStateSymbolView()
}

private final class SessionStateCellView: NSTableCellView {
    var buttons: [SessionStateButton] = []
    override var backgroundStyle: NSView.BackgroundStyle {
        get { super.backgroundStyle }
        set { super.backgroundStyle = .normal }
    }
}

private final class RecordingTextCellView: NSTableCellView {
    // Keep the fixed-size replay marker separate from AppKit's image layout.
    var replayDot: NSView?
}

private final class RecordingTableRowView: NSTableRowView {
    var pill: (() -> (NSColor, CGRect)?)?
    private func drawPill() {
        guard let (color, rect) = pill?() else { return }
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func drawBackground(in dirtyRect: NSRect) { super.drawBackground(in: dirtyRect); drawPill() }
    override func drawSelection(in dirtyRect: NSRect) { super.drawSelection(in: dirtyRect); drawPill() }
}

@MainActor
final class GestureRecorderController: NSObject, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {
    var setCaptureEnabled: ((Bool) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onReplayStarted: (([RecordedDevice]) -> Void)?
    var onReplayFrame: ((RecordedContactFrame) -> Void)?
    var onReplayTime: ((TimeInterval) -> Void)?
    var onReplaySelectionActive: ((Bool) -> Void)?
    var onReplayEnded: (() -> Void)?
    var capturePreview: (() -> RecordedPreviewState)?
    var pointerOverPreview: (() -> Bool)?
    var onReplayPreview: ((RecordedPreviewState) -> Void)?
    var isRecording: Bool { session != nil }
    var isReplaying: Bool { replayRequest != nil }
    var hasPendingSaves: Bool { pendingSaves > 0 }
    private var pendingSaves = 0
    private var saveCompletion: (() -> Void)?
    private let window: RecorderWindow
    private let segments = NSSegmentedControl(labels: GestureLabel.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private let table = RecordingOutlineView()
    private let status = NSTextField(labelWithString: "Shift-Space to record · Space to replay")
    private let recordButton = NSButton(title: "Start Recording", target: nil, action: nil)
    private let replayButton = NSButton(title: "Replay", target: nil, action: nil)
    private let radialButton = NSButton(title: "Radial Experiment", target: nil, action: nil)
    private let comparisonButton = NSButton(title: "Compare Classifiers", target: nil, action: nil)
    private var classifierComparison: ClassifierComparisonController?
    private var lastRightClick: TimeInterval = -.infinity
    private let radialView = RadialExperimentView()
    private var contentStack: NSStackView?
    private var radialVisible = false
    private var radialTrials: [RadialTrialConfiguration] = []
    private var radialNextIndex = 0
    private var radialEngine: RadialTrialEngine?
    private var radialOriginalHeight: CGFloat?
    private var radialWidthConstraint: NSLayoutConstraint?
    private var radialReplay: RadialTrialPlayback?
    private var radialReplayInitial: RadialTrialPlayback?
    private var radialContacts: [UInt64: (time: TimeInterval, count: Int, frame: ContactFrame)] = [:]
    private var radialContinuation: RadialContinuationGate?
    private var radialPointer: CGPoint?
    private var radialPausedByCursor = false
    private let groupButton = NSButton(title: "Group", target: nil, action: nil)
    private let ungroupButton = NSButton(title: "Ungroup", target: nil, action: nil)
    private let counterexamplesButton = NSButton(checkboxWithTitle: "Counterexamples", target: nil, action: nil)
    private let directory: URL
    private let annotationStore: GestureAnnotationStore
    private let loader = GestureRecordingLoader()
    private var annotations = GestureAnnotations()
    private var annotationLoadError: String?
    private var saveError: String?
    private var devices: [RecordedDevice] = []
    private var session: GestureRecordingSession?
    private var writer: GestureRecordingWriter?
    private var rows: [RecordingRow] = []
    private var reloadingOutline = false
    private var attemptRows: [RecordingRow] = []
    private var activeRow: RecordingRow?
    private var lastRefresh: TimeInterval = 0
    private var dropped: UInt64 = 0
    private var expandedLiveRow = false
    private struct ReplaySelection: Sendable {
        var attempt: GestureAttempt
        var region: ClosedRange<TimeInterval>?
        var contactIDs: Set<String> = []
        var intervals: [ClosedRange<TimeInterval>] = []
    }
    private enum CopyReferences: Int {
        case selected, groups, contacts
    }
    private var replayRequest: UUID?
    private var replayPlaylist: [ReplaySelection] = []
    private var replayQueue: [ReplaySelection] = []
    private var replaySelection: ReplaySelection?
    private var replayCursor: GestureReplayCursor?
    private var replayInitialCursor: GestureReplayCursor?
    private var replayMotion = PreviewReplayTimeline([])
    private var replayStarted: TimeInterval = 0
    private var comparisonRightClickTimes: [TimeInterval] = []
    private var nextComparisonRightClick = 0
    private var replayCleared = false
    private var replayActiveContacts: Set<String> = []
    private let clock: DateFormatter = { let formatter = DateFormatter(); formatter.timeStyle = .medium; return formatter }()

    init(directory: URL = GestureRecordingWriter.defaultDirectory) {
        self.directory = directory
        annotationStore = GestureAnnotationStore(directory: directory)
        window = RecorderWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 600),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Gesture Recorder"
        window.minSize = CGSize(width: 820, height: 500)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("GestureRecorder")
        window.delegate = self
        window.pressSpace = { [weak self] shift in
            guard let self else { return }
            if self.isRecording || self.isReplaying || self.radialContinuation != nil { self.stop() }
            else if self.radialVisible { self.radialView.advance() }
            else if shift { self.toggle() }
            else { self.toggleReplay() }
        }
        window.recordGesture = { [weak self] event in self?.receive(event) ?? false }
        do { annotations = try annotationStore.load() }
        catch { annotationLoadError = error.localizedDescription }
        attemptRows = GestureRecordingWriter.attempts(in: directory).map { attempt in
            let row = RecordingRow(attempt: attempt); row.update(attempt); return row
        }
        buildContent()
        for row in attemptRows {
            guard let attempt = row.attempt else { continue }
            if attempt.contactIndex != nil {
                if annotations.initializeContactGroups(for: attempt), annotationLoadError == nil { saveAnnotations() }
            } else {
                loader.load(attempt, from: directory, includeFrames: false) { [weak self, weak row] result in
                    guard let self, let row else { return }
                    switch result {
                    case .success(let recording):
                        row.update(recording.attempt)
                        if self.annotations.initializeContactGroups(for: recording.attempt), self.annotationLoadError == nil { self.saveAnnotations() }
                        self.rebuildRows(for: row)
                    case .failure(let error):
                        self.saveError = "Could not load contacts: \(error.localizedDescription)"
                        self.updateControls()
                    }
                }
            }
        }
        rebuildRows()
    }

    private func buildContent() {
        let content = NSView()
        window.contentView = content
        segments.selectedSegment = 2
        segments.segmentStyle = .rounded
        if #available(macOS 26.0, *) { segments.controlSize = .extraLarge }
        else { segments.controlSize = .large }
        segments.segmentDistribution = .fillEqually
        segments.setAccessibilityLabel("Gesture to record")
        for index in 0..<segments.segmentCount { segments.setWidth(0, forSegment: index) }
        recordButton.target = self
        recordButton.action = #selector(toggle)
        recordButton.bezelStyle = .rounded
        recordButton.toolTip = "Shift-Space starts recording. Space or Shift-Space stops."
        replayButton.target = self; replayButton.action = #selector(toggleReplay)
        replayButton.bezelStyle = .rounded
        replayButton.toolTip = "Selection loops with one second of context and a one-second pause. Space or Shift-Space stops."
        status.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        status.textColor = .secondaryLabelColor
        radialButton.bezelStyle = .rounded
        radialButton.target = self; radialButton.action = #selector(toggleRadialPane)
        radialView.onStart = { [weak self] preset, practice in self?.startRadialBlock(preset, practice: practice) }
        radialView.onNext = { [weak self] in self?.startNextRadialTrial() }
        radialView.onRetry = { [weak self] in self?.retryRadialTrial() }
        radialView.onStop = { [weak self] in self?.stop() }
        radialView.onFinish = { [weak self] in self?.finishRadialBlock(includingLastAttempt: true) }
        radialView.onClose = { [weak self] in self?.toggleRadialPane() }
        comparisonButton.bezelStyle = .rounded
        comparisonButton.target = self; comparisonButton.action = #selector(showClassifierComparison)
        let controls = NSStackView(views: [recordButton, replayButton, radialButton, comparisonButton])
        controls.spacing = 12
        controls.alignment = .centerY
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .medium
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.intercellSpacing.height = 0
        let contextMenu = NSMenu()
        for (title, kind) in [("Copy Selected", CopyReferences.selected), ("Copy Selected Groups", .groups), ("Copy Selected Contacts", .contacts)] {
            let item = NSMenuItem(title: title, action: #selector(copyReferences(_:)), keyEquivalent: "")
            item.target = self
            item.tag = kind.rawValue
            contextMenu.addItem(item)
        }
        contextMenu.addItem(.separator())
        for (title, state) in [("Mark Ready", GestureSessionState.ready), ("Mark Exclude", .exclude), ("Unmark", .unmarked)] {
            let item = NSMenuItem(title: title, action: #selector(markSelectedSessions(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = state.rawValue
            contextMenu.addItem(item)
        }
        table.menu = contextMenu
        for (id, title, width) in [("gesture", "Session / contact group / contact", 280.0), ("state", "State", 70.0), ("category", "Category", 140.0),
                                   ("counterexample", "Similar to, but not", 145.0), ("device", "Trackpad", 155.0),
                                   ("start", "Start", 85.0), ("end", "End", 85.0), ("duration", "Duration", 85.0), ("samples", "Samples", 70.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = 60
            table.addTableColumn(column)
            if id == "counterexample" { column.isHidden = !annotations.showsCounterexamples }
        }
        table.outlineTableColumn = table.tableColumns.first
        scroll.documentView = table
        let reveal = NSButton(title: "Show Recordings in Finder", target: self, action: #selector(revealFiles))
        reveal.bezelStyle = .rounded
        groupButton.target = self; groupButton.action = #selector(groupSelected)
        groupButton.bezelStyle = .rounded
        groupButton.toolTip = "Group two or more selected contacts from the same session."
        ungroupButton.target = self; ungroupButton.action = #selector(ungroupSelected)
        ungroupButton.bezelStyle = .rounded
        counterexamplesButton.target = self; counterexamplesButton.action = #selector(toggleCounterexamples)
        counterexamplesButton.state = annotations.showsCounterexamples ? .on : .off
        let footer = NSStackView(views: [groupButton, ungroupButton, counterexamplesButton, NSView(), reveal])
        footer.spacing = 12
        let stack = NSStackView(views: [segments, controls, status, scroll, footer])
        contentStack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            segments.widthAnchor.constraint(equalTo: stack.widthAnchor),
            segments.heightAnchor.constraint(equalToConstant: 48),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        updateControls()
    }

    @objc private func toggleRadialPane() {
        if radialVisible {
            finishRadialBlock()
            radialVisible = false
            contentStack?.removeArrangedSubview(radialView)
            radialView.removeFromSuperview()
            radialWidthConstraint?.isActive = false
            window.minSize.height = 500
            if let original = radialOriginalHeight {
                var frame = window.frame; frame.origin.y += frame.height - original; frame.size.height = original
                window.setFrame(frame, display: true)
            }
        } else {
            guard !isRecording else { return }
            radialVisible = true
            radialOriginalHeight = window.frame.height
            contentStack?.insertArrangedSubview(radialView, at: 3)
            if radialWidthConstraint == nil { radialWidthConstraint = radialView.widthAnchor.constraint(equalTo: contentStack!.widthAnchor) }
            radialWidthConstraint?.isActive = true
            window.minSize.height = 760
            if window.frame.height < 820 {
                var frame = window.frame
                let height = min(820, window.screen?.visibleFrame.height ?? 820)
                frame.origin.y -= height - frame.height; frame.size.height = height
                if let visible = window.screen?.visibleFrame { frame.origin.y = max(visible.minY, frame.origin.y) }
                window.setFrame(frame, display: true)
            }
        }
        updateControls()
    }

    private func startRadialBlock(_ preset: RadialPreset, practice: Bool) {
        guard !isRecording, !devices.isEmpty else { return }
        stopReplay()
        radialTrials = RadialTrialPlan.make(preset, practice: practice, seed: UInt64.random(in: 0...UInt64.max))
        radialNextIndex = 0
        radialEngine = nil
        startNextRadialTrial()
    }

    private func startNextRadialTrial(automatically: Bool = false, startingContact: (deviceID: UInt64, frame: ContactFrame)? = nil) {
        guard !isRecording, radialNextIndex < radialTrials.count else { return }
        let completedTrialID = radialEngine?.record.configuration.id
        radialContinuation = nil
        stopReplay()
        if startRadialTrial(radialTrials[radialNextIndex], startingContact: startingContact) {
            radialNextIndex += 1
            if automatically {
                if annotationLoadError == nil, let completedTrialID,
                   let row = attemptRows.first(where: { $0.attempt?.radialTrial?.configuration.id == completedTrialID }) {
                    applySessionState(.ready, to: row)
                    saveAnnotations()
                }
                radialView.showAutomaticAction(.advanced)
            }
        }
        updateControls()
    }

    private func startRadialTrial(_ configuration: RadialTrialConfiguration, startingContact: (deviceID: UInt64, frame: ContactFrame)? = nil) -> Bool {
        guard !devices.isEmpty else { return false }
        let engine = RadialTrialEngine(configuration)
        let previous = radialEngine
        radialEngine = engine
        guard beginRecording(label: configuration.label, radialTrial: engine.record, at: startingContact?.frame.receivedAt) else { radialEngine = previous; return false }
        radialContinuation = nil
        radialPausedByCursor = false
        radialPointer = NSEvent.mouseLocation
        radialView.clearAutomaticAction()
        if let startingContact { receive(startingContact.frame, deviceID: startingContact.deviceID, dropped: 0) }
        updateRadialView()
        return true
    }

    private func retryRadialTrial(automatically: Bool = false, startingContact: (deviceID: UInt64, frame: ContactFrame)? = nil) {
        guard !isRecording, var configuration = radialEngine?.record.configuration else { return }
        stopReplay()
        if annotationLoadError == nil,
           let row = attemptRows.first(where: { $0.attempt?.radialTrial?.configuration.id == configuration.id }),
           let attempt = row.attempt, annotations.sessionState(for: attempt) != .exclude {
            applySessionState(.exclude, to: row)
            saveAnnotations()
        }
        configuration.retryOf = configuration.id; configuration.id = UUID()
        if startRadialTrial(configuration, startingContact: startingContact), automatically { radialView.showAutomaticAction(.retrying) }
        updateControls()
    }

    private func awaitRadialContinuation(_ action: RadialContinuationGate.Action, engine: RadialTrialEngine, started: TimeInterval) {
        guard let deviceID = engine.deviceID, let result = engine.record.result else { return }
        var gate = RadialContinuationGate(action: action, deviceID: deviceID, after: started + result.endedAt)
        if let contacts = radialContacts[deviceID] { gate.receive(deviceID: deviceID, time: contacts.time, count: contacts.count) }
        radialContinuation = gate
        updateControls()
    }

    private func finishRadialBlock(includingLastAttempt: Bool = false) {
        let lastTrialID = includingLastAttempt && !radialTrials.isEmpty ? radialEngine?.record.configuration.id : nil
        radialView.clearAutomaticAction()
        radialContinuation = nil
        if radialEngine != nil, isRecording { stop() }
        if annotationLoadError == nil, let lastTrialID,
           let row = attemptRows.first(where: { $0.attempt?.radialTrial?.configuration.id == lastTrialID }) {
            applySessionState(.ready, to: row)
            saveAnnotations()
        }
        radialTrials = []; radialNextIndex = 0
        updateControls()
    }

    private func saveRadialUpdates() {
        guard var engine = radialEngine, session?.attempt.radialTrial != nil else { return }
        session?.updateRadialTrial(engine.record)
        for event in engine.takeEvents() { writer?.append(RecordingLogEntry(kind: "radial", radial: event)) }
        radialEngine = engine
    }

    private func updateRadialView() {
        guard radialVisible else { return }
        radialView.update(engine: radialEngine, hasBlock: !radialTrials.isEmpty,
            next: radialTrials.indices.contains(radialNextIndex) ? radialTrials[radialNextIndex] : nil, recording: isRecording,
            canStart: !devices.isEmpty, awaitingRelease: radialContinuation?.awaitingRelease == true,
            awaitingContact: radialContinuation?.awaitingContact == true, retryPending: radialContinuation?.action == .retry)
        if isReplaying, let record = replaySelection?.attempt.radialTrial {
            radialView.showReplay(record, measurement: radialReplay?.measurement, time: replayCursor?.position ?? 0)
        }
    }

    private var selectedRows: [RecordingRow] {
        table.selectedRowIndexes.compactMap { table.item(atRow: $0) as? RecordingRow }
    }

    private var selectedSessionRows: [RecordingRow] {
        let ids = Set(selectedRows.compactMap { $0.containingAttempt?.id })
        return attemptRows.filter { $0.attempt.map { ids.contains($0.id) } ?? false }
    }

    private var selectedContactAttempt: GestureAttempt? {
        let selected = selectedRows.filter { !$0.contactIDs.isEmpty }
        let ids = Set(selected.compactMap { $0.containingAttempt?.id })
        return ids.count == 1 ? selected.first?.containingAttempt : nil
    }

    private var selectedContactIDs: Set<String> {
        Set(selectedRows.flatMap { $0.contactIDs })
    }

    private func selectedReferences(_ kind: CopyReferences) -> [String] {
        var references: [String] = []
        for row in selectedRows {
            guard let attempt = row.containingAttempt else { continue }
            if kind == .selected, row.attempt != nil, let reference = annotations.referenceID(for: attempt) {
                references.append(reference)
            }
            if kind != .contacts, let group = row.group, let reference = annotations.referenceID(for: group) {
                references.append(reference)
            }
            if kind != .groups {
                let contacts = row.contact.map { [$0] } ?? (kind == .contacts && row.group != nil ? row.children.compactMap(\.contact) : [])
                references.append(contentsOf: contacts.compactMap { annotations.referenceID(for: $0, in: attempt) })
            }
        }
        var seen: Set<String> = []
        return references.filter { seen.insert($0).inserted }
    }

    @objc private func copyReferences(_ sender: NSMenuItem) {
        guard let kind = CopyReferences(rawValue: sender.tag) else { return }
        let references = selectedReferences(kind)
        guard !references.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(references.joined(separator: "\n"), forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(markSelectedSessions(_:)) {
            return annotationLoadError == nil && !selectedSessionRows.isEmpty
        }
        guard menuItem.action == #selector(copyReferences(_:)), let kind = CopyReferences(rawValue: menuItem.tag) else { return true }
        return !selectedReferences(kind).isEmpty
    }

    private func reloadOutline(expanding groupID: UUID? = nil, selecting selectedID: String? = nil,
                               rebuild: Bool = false, root: RecordingRow? = nil) {
        let wasReloading = reloadingOutline
        reloadingOutline = true
        defer { reloadingOutline = wasReloading }
        let expanded = Set((0..<table.numberOfRows).compactMap { index -> String? in
            guard let row = table.item(atRow: index) as? RecordingRow, table.isItemExpanded(row) else { return nil }
            return row.id
        })
        let selected = selectedID.map { Set([$0]) } ?? Set(selectedRows.map(\.id))
        let roots = root.map { [$0] } ?? attemptRows
        if rebuild {
            var referencesChanged = false
            let groupsByAttempt = Dictionary(grouping: annotations.contactGroups, by: \.attemptID)
            for root in roots {
                guard let attempt = root.attempt else { continue }
                if annotationLoadError == nil, annotations.initializeReferenceIDs(for: attempt) { referencesChanged = true }
                // Build membership once instead of searching every session's
                // groups for each individual contact.
                var memberships: [String: GestureContactGroup] = [:]
                for group in groupsByAttempt[attempt.id] ?? [] {
                    for id in group.contactIDs where memberships[id] == nil { memberships[id] = group }
                }
                let descendants = root.children.flatMap { [$0] + $0.children }
                let contacts = Dictionary(uniqueKeysWithValues: descendants.compactMap { row in row.contact.map { ($0.id, row) } })
                var groups = Dictionary(uniqueKeysWithValues: descendants.compactMap { row in row.group.map { ($0.id, row) } })
                let intervals = Dictionary(uniqueKeysWithValues: descendants.compactMap { row in row.interval.map { ($0.id, row) } })
                root.children = []
                var seen: Set<UUID> = []
                for contact in attempt.contactIndex?.contacts ?? [] {
                    let row = contacts[contact.id] ?? RecordingRow(contact: contact)
                    row.contact = contact; row.parent = root
                    if let group = memberships[contact.id] {
                        let groupRow = groups[group.id] ?? RecordingRow(group: group)
                        if seen.insert(group.id).inserted {
                            groupRow.group = group; groupRow.parent = root; groupRow.children = []
                            groups[group.id] = groupRow
                            root.children.append(groupRow)
                        }
                        row.parent = groupRow
                        groupRow.children.append(row)
                    } else { root.children.append(row) }
                }
                for group in root.children where group.group != nil { group.updateContactSummary() }
                for interval in attempt.intervals where interval.kind != "Contacts" || attempt.contactIndex == nil {
                    let row = intervals[interval.id] ?? RecordingRow(interval: interval)
                    row.interval = interval; row.parent = root
                    root.children.append(row)
                }
                // Keep detector/AppKit intervals beside the contact groups
                // they overlap, with stable ordering for simultaneous starts.
                root.children = root.children.enumerated().sorted {
                    $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
                }.map(\.element)
            }
            rows = attemptRows
            if referencesChanged { saveAnnotations() }
        }
        if let root { table.reloadItem(root, reloadChildren: true) }
        else { table.reloadData() }
        func expand(_ row: RecordingRow) {
            if expanded.contains(row.id) || (groupID != nil && row.group?.id == groupID) { table.expandItem(row) }
            if table.isItemExpanded(row) { row.children.forEach(expand) }
        }
        roots.forEach(expand)
        table.selectRowIndexes(IndexSet((0..<table.numberOfRows).filter {
            (table.item(atRow: $0) as? RecordingRow).map { selected.contains($0.id) } == true
        }), byExtendingSelection: false)
        redrawPills()
        updateControls()
    }

    private func rebuildRows(for root: RecordingRow? = nil, expanding groupID: UUID? = nil, selecting selectedID: String? = nil) {
        reloadOutline(expanding: groupID, selecting: selectedID, rebuild: true, root: root)
    }

    @objc private func groupSelected() {
        guard annotationLoadError == nil, let attempt = selectedContactAttempt,
              attempt.id != activeRow?.attempt?.id, selectedContactIDs.count >= 2 else { return }
        let selectedGroups = selectedRows.compactMap(\.group)
        let target = selectedGroups.count == 1 ? selectedGroups.first?.id : nil
        guard let id = annotations.groupContacts(selectedContactIDs, in: attempt, into: target) else { return }
        saveAnnotations()
        rebuildRows(for: attemptRows.first { $0.attempt?.id == attempt.id }, expanding: id, selecting: id.uuidString)
    }

    @objc private func ungroupSelected() {
        guard annotationLoadError == nil, let attempt = selectedContactAttempt, attempt.id != activeRow?.attempt?.id else { return }
        let first = selectedRows.first { $0.contact != nil }?.id
        annotations.ungroupContacts(selectedContactIDs, in: attempt)
        saveAnnotations()
        rebuildRows(for: attemptRows.first { $0.attempt?.id == attempt.id }, selecting: first)
    }

    @objc private func toggleCounterexamples() {
        guard annotationLoadError == nil else { return }
        annotations.showsCounterexamples = counterexamplesButton.state == .on
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("counterexample"))?.isHidden = !annotations.showsCounterexamples
        saveAnnotations()
    }

    @objc private func changeCategory(_ sender: CategoryPopUp) {
        guard annotationLoadError == nil, let row = sender.row, let attempt = row.containingAttempt,
              attempt.id != activeRow?.attempt?.id else { return }
        let affected = row.attempt != nil ? Set(annotations.group(containing: attempt.id)?.attemptIDs ?? [attempt.id]) : [attempt.id]
        if !sender.isCounterexample, sender.selectedTag() == -2 {
            if let group = row.group { annotations.inheritContactCategory(groupID: group.id, in: attempt) }
            else if let contact = row.contact { annotations.inheritCategory(for: contact, in: attempt) }
            else if row.attempt != nil { annotations.inheritCategory(for: attempt) }
        } else {
            var category = row.group?.category ?? row.contact.map { annotations.category(for: $0, in: attempt) } ?? annotations.category(for: attempt)
            let label = GestureLabel.allCases.indices.contains(sender.selectedTag()) ? GestureLabel.allCases[sender.selectedTag()] : nil
            if sender.isCounterexample { category.counterexampleTo = label }
            else if let label { category.label = label }
            if let group = row.group { annotations.setContactCategory(category, groupID: group.id) }
            else if let contact = row.contact { annotations.setCategory(category, for: contact, in: attempt) }
            else if row.attempt != nil { annotations.setCategory(category, for: attempt) }
        }
        saveAnnotations()
        updateVisibleCategories(in: affected)
    }

    private func updateVisibleCategories(in sessionIDs: Set<UUID>) {
        let groups = Dictionary(uniqueKeysWithValues: annotations.contactGroups
            .filter { sessionIDs.contains($0.attemptID) }.map { ($0.id, $0) })
        for root in attemptRows where root.attempt.map({ sessionIDs.contains($0.id) }) == true {
            for row in root.children {
                if let id = row.group?.id { row.group = groups[id] }
            }
        }
        let columns = table.tableColumns.enumerated().filter {
            !$0.element.isHidden && ["category", "counterexample"].contains($0.element.identifier.rawValue)
        }
        table.enumerateAvailableRowViews { [self] _, index in
            guard let row = table.item(atRow: index) as? RecordingRow,
                  let id = row.containingAttempt?.id, sessionIDs.contains(id) else { return }
            for (column, definition) in columns {
                guard let cell = table.view(atColumn: column, row: index, makeIfNecessary: false),
                      let popup = cell.subviews.first as? CategoryPopUp else { continue }
                updateCategoryPopUp(popup, for: row, counterexample: definition.identifier.rawValue == "counterexample")
            }
        }
    }

    @objc private func changeSessionState(_ sender: SessionStateButton) {
        guard annotationLoadError == nil, let row = sender.row, let attempt = row.attempt else { return }
        let state: GestureSessionState = annotations.sessionState(for: attempt) == sender.marking ? .unmarked : sender.marking
        applySessionState(state, to: row)
        saveAnnotations()
    }

    @objc private func markSelectedSessions(_ sender: NSMenuItem) {
        guard annotationLoadError == nil, let raw = sender.representedObject as? String,
              let state = GestureSessionState(rawValue: raw) else { return }
        let rows = selectedSessionRows
        guard !rows.isEmpty else { return }
        for row in rows { applySessionState(state, to: row) }
        saveAnnotations()
    }

    private func applySessionState(_ state: GestureSessionState, to row: RecordingRow) {
        guard let attempt = row.attempt else { return }
        annotations.setSessionState(state, for: attempt)
        let index = table.row(forItem: row)
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("state"))
        if index >= 0, column >= 0,
           let cell = table.view(atColumn: column, row: index, makeIfNecessary: false) as? SessionStateCellView {
            updateSessionStateCell(cell, for: row)
        }
    }

    private func updateVisibleTextCells(in root: RecordingRow) {
        table.enumerateAvailableRowViews { [self] _, index in
            guard let row = table.item(atRow: index) as? RecordingRow, row.sessionRow === root else { return }
            for (column, definition) in table.tableColumns.enumerated() where !definition.isHidden {
                guard let cell = table.view(atColumn: column, row: index, makeIfNecessary: false) as? RecordingTextCellView else { continue }
                updateTextCell(cell, for: row, column: definition.identifier.rawValue)
            }
        }
    }

    private func saveAnnotations() {
        pendingSaves += 1
        annotationStore.save(annotations) { [weak self] error in self?.saveFinished(error) }
    }

    private func saveFinished(_ error: Error?) {
        if let error { showFailure(error) }
        pendingSaves -= 1
        updateControls()
        if pendingSaves == 0 { let completion = saveCompletion; saveCompletion = nil; completion?() }
    }

    private func redrawPills() {
        table.enumerateAvailableRowViews { view, _ in view.needsDisplay = true }
    }

    func show() {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showClassifierComparison() {
        if classifierComparison == nil {
            classifierComparison = ClassifierComparisonController()
            classifierComparison?.onRightClick = { [weak self] deviceID in
                self?.receiveRightClick(deviceID: deviceID, at: ProcessInfo.processInfo.systemUptime)
            }
            classifierComparison?.setDevices(devices)
            classifierComparison?.pointerOverPreview = pointerOverPreview
            if let selection = replaySelection, isReplaying {
                classifierComparison?.beginReplay(devices: selection.attempt.devices, title: selection.attempt.label.rawValue)
            }
        }
        classifierComparison?.show()
    }

    func setDevices(_ devices: [TrackpadDevice]) {
        self.devices = devices.map { RecordedDevice(id: $0.id, name: $0.name, sizeMM: $0.sizeMM) }
        classifierComparison?.setDevices(self.devices)
        let ids = Set(devices.map(\.id))
        radialContacts = radialContacts.filter { ids.contains($0.key) }
        if let advance = radialContinuation, !ids.contains(advance.deviceID) { radialContinuation = nil }
        session?.updateDevices(self.devices)
        updateControls()
    }

    private var replaySelections: [ReplaySelection] {
        var whole: Set<UUID> = []
        var regions: [UUID: ClosedRange<TimeInterval>] = [:]
        var contactIDs: [UUID: Set<String>] = [:]
        var intervals: [UUID: [ClosedRange<TimeInterval>]] = [:]
        for row in selectedRows {
            guard let attempt = row.containingAttempt, attempt.id != activeRow?.attempt?.id,
                  row.sessionRow?.saving == false else { continue }
            if row.attempt != nil { whole.insert(attempt.id) }
            else {
                let region = regions[attempt.id]
                regions[attempt.id] = min(row.start, region?.lowerBound ?? row.start)...max(row.end, region?.upperBound ?? row.end)
                contactIDs[attempt.id, default: []].formUnion(row.contactIDs)
                if let interval = row.interval { intervals[attempt.id, default: []].append(interval.start...interval.end) }
            }
        }
        return attemptRows.compactMap { row in
            guard let attempt = row.attempt else { return nil }
            if whole.contains(attempt.id) { return ReplaySelection(attempt: attempt, region: nil) }
            guard let region = regions[attempt.id] else { return nil }
            return ReplaySelection(attempt: attempt, region: region, contactIDs: contactIDs[attempt.id] ?? [],
                                   intervals: intervals[attempt.id] ?? [])
        }
    }

    @objc private func toggleReplay() {
        if isReplaying { stopReplay(); return }
        guard !isRecording else { return }
        let selections = replaySelections
        guard !selections.isEmpty else {
            saveError = "Select a session, contact group, contacts, or gesture interval to replay"
            updateControls(); return
        }
        startReplay(selections)
    }

    private func startReplay(_ selections: [ReplaySelection]) {
        radialContinuation = nil
        stopReplay()
        guard !isRecording, !selections.isEmpty else { return }
        saveError = nil
        replayPlaylist = selections
        replayQueue = selections
        replayRequest = UUID()
        loadNextReplay()
    }

    private func loadNextReplay(at time: TimeInterval? = nil) {
        guard let request = replayRequest else { return }
        if replayQueue.isEmpty { replayQueue = replayPlaylist }
        guard !replayQueue.isEmpty else { stopReplay(); return }
        let selection = replayQueue.removeFirst()
        if replaySelection?.attempt.id == selection.attempt.id,
           replaySelection?.region == selection.region, replaySelection?.contactIDs == selection.contactIDs,
           replaySelection?.intervals == selection.intervals, replayInitialCursor != nil {
            beginReplay(at: time ?? ProcessInfo.processInfo.systemUptime)
            return
        }
        replaySelection = selection
        replayCursor = nil
        replayInitialCursor = nil
        radialReplay = nil; radialReplayInitial = nil
        replayCleared = false
        replayActiveContacts.removeAll()
        onReplaySelectionActive?(false)
        updateReplayDots()
        updateControls()
        loader.load(selection.attempt, from: directory, includeFrames: true) { [weak self] result in
            guard let self, self.replayRequest == request else { return }
            switch result {
            case .success(let recording):
                if let row = self.attemptRows.first(where: { $0.attempt?.id == recording.attempt.id }) {
                    let contactsChanged = row.attempt?.contactIndex?.contacts != recording.attempt.contactIndex?.contacts
                    row.update(recording.attempt)
                    let groupsChanged = self.annotations.initializeContactGroups(for: recording.attempt)
                    if groupsChanged, self.annotationLoadError == nil { self.saveAnnotations() }
                    if contactsChanged || groupsChanged { self.rebuildRows(for: row) }
                    else { self.updateVisibleTextCells(in: row) }
                }
                let duration = recording.attempt.duration
                let start = max(0, min(duration, (selection.region?.lowerBound ?? 0) - 1))
                let end = max(start, min(duration, (selection.region?.upperBound ?? duration) + 1))
                self.replaySelection = ReplaySelection(attempt: recording.attempt, region: selection.region,
                    contactIDs: selection.contactIDs, intervals: selection.intervals)
                self.replayInitialCursor = GestureReplayCursor(frames: recording.frames, start: start, end: end)
                self.radialReplayInitial = recording.attempt.radialTrial.map { record in
                    var playback = RadialTrialPlayback(record)
                    for frame in recording.frames where frame.time < start {
                        if let device = recording.attempt.devices.first(where: { $0.id == frame.deviceID }) {
                            playback.receive(frame, sizeMM: device.sizeMM)
                        }
                    }
                    return playback
                }
                self.replayMotion = PreviewReplayTimeline(recording.previewStates)
                self.beginReplay(at: ProcessInfo.processInfo.systemUptime)
            case .failure(let error):
                self.stopReplay()
                self.saveError = "Replay failed: \(error.localizedDescription)"
                self.updateControls()
            }
        }
    }

    private func beginReplay(at time: TimeInterval) {
        guard let selection = replaySelection, let cursor = replayInitialCursor else { return }
        replayCursor = cursor
        radialReplay = radialReplayInitial
        if selection.attempt.radialTrial != nil, !radialVisible { toggleRadialPane() }
        replayStarted = time
        comparisonRightClickTimes = selection.attempt.intervals.filter { $0.kind == "AppKit Right Click" && $0.start >= cursor.start && $0.start <= cursor.end }.map(\.start).sorted()
        nextComparisonRightClick = 0
        replayCleared = false
        replayActiveContacts.removeAll()
        onReplayStarted?(selection.attempt.devices)
        classifierComparison?.beginReplay(devices: selection.attempt.devices, title: selection.attempt.label.rawValue)
        advanceReplay(at: time)
        updateControls()
    }

    private func advanceReplay(at time: TimeInterval) {
        guard var cursor = replayCursor, let selection = replaySelection else { return }
        let elapsed = max(0, time - replayStarted)
        if replayCleared {
            if elapsed >= cursor.duration + 1 { loadNextReplay(at: time) }
            return
        }
        let due = cursor.advance(to: elapsed)
        replayCursor = cursor
        onReplayTime?(cursor.position)
        let contacts = selection.attempt.contactIndex?.contacts ?? []
        // Replay the surrounding activity too, including other devices and
        // earlier/later lifetimes that reuse a selected contact's path ID.
        for frame in due {
            onReplayFrame?(frame)
            while comparisonRightClickTimes.indices.contains(nextComparisonRightClick), comparisonRightClickTimes[nextComparisonRightClick] <= frame.time {
                classifierComparison?.receiveRightClick(deviceID: nil, at: comparisonRightClickTimes[nextComparisonRightClick])
                nextComparisonRightClick += 1
            }
            classifierComparison?.receive(frame)
            if let device = selection.attempt.devices.first(where: { $0.id == frame.deviceID }) {
                radialReplay?.receive(frame, sizeMM: device.sizeMM)
            }
        }
        updateRadialView()
        if let state = replayMotion.state(at: cursor.position) { onReplayPreview?(state) }
        replayActiveContacts = Set(contacts.filter {
            $0.isActive(at: cursor.position)
        }.map(\.id))
        if elapsed >= cursor.duration, !replayCleared {
            replayCleared = true
            replayActiveContacts.removeAll()
            for device in selection.attempt.devices {
                let released = RecordedContactFrame(deviceID: device.id, sequence: 0, time: cursor.end, contacts: [])
                onReplayFrame?(released)
                classifierComparison?.receive(released)
            }
        }
        // Membership uses each contact's lifetime, so surrounding activity
        // and later contacts reusing its sensor path cannot brighten the glow.
        let selectedIsActive = !replayActiveContacts.isEmpty && (selection.region == nil
            || !selection.contactIDs.isDisjoint(with: replayActiveContacts)
            || selection.intervals.contains { cursor.position >= $0.lowerBound && cursor.position < $0.upperBound })
        onReplaySelectionActive?(selectedIsActive)
        updateReplayDots()
        if elapsed >= cursor.duration + 1 { loadNextReplay(at: time) }
    }

    private func stopReplay() {
        guard isReplaying else { return }
        replayRequest = nil
        replayPlaylist = []
        replayQueue = []
        replaySelection = nil
        replayCursor = nil
        replayInitialCursor = nil
        replayMotion = PreviewReplayTimeline([])
        radialReplay = nil; radialReplayInitial = nil
        replayActiveContacts.removeAll()
        onReplaySelectionActive?(false)
        onReplayEnded?()
        classifierComparison?.endReplay()
        updateReplayDots()
        updateControls()
    }

    private func isRowReplaying(_ row: RecordingRow) -> Bool {
        guard isReplaying, !replayCleared, let selection = replaySelection, let cursor = replayCursor,
              row.containingAttempt?.id == selection.attempt.id else { return false }
        if let contact = row.contact { return replayActiveContacts.contains(contact.id) }
        if let group = row.group { return group.contactIDs.contains { replayActiveContacts.contains($0) } }
        if let interval = row.interval { return cursor.position >= interval.start && cursor.position < interval.end }
        return true
    }

    private func updateReplayDots() {
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("gesture"))
        guard column >= 0 else { return }
        table.enumerateAvailableRowViews { [self] _, index in
            guard let row = table.item(atRow: index) as? RecordingRow,
                  let cell = table.view(atColumn: column, row: index, makeIfNecessary: false) as? RecordingTextCellView else { return }
            let hidden = !isRowReplaying(row)
            if cell.replayDot?.isHidden != hidden { cell.replayDot?.isHidden = hidden }
        }
    }

    @objc func toggle() {
        if isReplaying { stopReplay(); return }
        if isRecording { stop(); return }
        if radialVisible { radialView.advance(); return }
        guard !devices.isEmpty else { status.stringValue = "No trackpads connected"; return }
        let label = GestureLabel.allCases[max(0, segments.selectedSegment)]
        _ = beginRecording(label: label)
    }

    @discardableResult
    private func beginRecording(label: GestureLabel, radialTrial: RadialTrialRecord? = nil, at time: TimeInterval? = nil) -> Bool {
        guard !isRecording, !isReplaying, !devices.isEmpty else { return false }
        var session = GestureRecordingSession(label: label, devices: devices, at: time ?? ProcessInfo.processInfo.systemUptime)
        if let radialTrial { session.updateRadialTrial(radialTrial) }
        do {
            writer = try GestureRecordingWriter(directory: directory, attempt: session.attempt)
        } catch { showFailure(error); return false }
        self.session = session
        if annotationLoadError == nil { annotations.initializeReferenceIDs(for: session.attempt) }
        if radialTrial != nil, annotationLoadError == nil {
            annotations.setSessionState(.exclude, for: session.attempt)
            saveAnnotations()
        }
        dropped = 0
        let row = RecordingRow(attempt: session.attempt)
        attemptRows.insert(row, at: 0); activeRow = row
        expandedLiveRow = false
        setCaptureEnabled?(true)
        onRecordingChanged?(true)
        if let state = capturePreview?() { receivePreview(state) }
        rows = attemptRows
        table.insertItems(at: IndexSet(integer: 0), inParent: nil, withAnimation: [])
        table.expandItem(row)
        table.scrollRowToVisible(0)
        refresh(force: true)
        updateControls()
        return true
    }

    func stop() {
        radialView.clearAutomaticAction()
        let wasAwaitingAdvance = radialContinuation != nil
        radialContinuation = nil
        stopReplay()
        guard session != nil else {
            if wasAwaitingAdvance { updateControls() }
            return
        }
        if let state = capturePreview?() { receivePreview(state) }
        // Disable callbacks first, then the owner drains every queued frame
        // before this attempt is finalized.
        setCaptureEnabled?(false)
        if let started = session?.startedUptime, session?.attempt.radialTrial != nil {
            radialEngine?.finish(.stopped, at: ProcessInfo.processInfo.systemUptime - started)
            saveRadialUpdates()
        }
        guard var session, let writer, let row = activeRow else { return }
        session.tick(at: ProcessInfo.processInfo.systemUptime - session.startedUptime, droppedFrames: dropped)
        let attempt = session.finish(at: ProcessInfo.processInfo.systemUptime - session.startedUptime)
        row.update(attempt); row.saving = true
        if annotations.initializeContactGroups(for: attempt), annotationLoadError == nil { saveAnnotations() }
        pendingSaves += 1
        self.session = nil; self.writer = nil; activeRow = nil
        onRecordingChanged?(false)
        rebuildRows(for: row)
        updateControls()
        writer.finish(attempt) { [weak self, weak row] result in
            guard let self else { return }
            if let row {
                row.saving = false
                self.updateVisibleTextCells(in: row)
            }
            let error: Error?
            if case .failure(let failure) = result { error = failure } else { error = nil }
            self.saveFinished(error)
        }
    }

    func whenSavesFinish(_ completion: @escaping () -> Void) {
        if pendingSaves == 0 { completion() } else { saveCompletion = completion }
    }

    func receive(_ frame: ContactFrame, deviceID: UInt64, dropped: UInt64) {
        observeContacts(frame, deviceID: deviceID)
        guard let started = session?.startedUptime else { return }
        self.dropped = max(self.dropped, dropped)
        let contacts = frame.contacts.map { contact in
            var sample = RecordedContact(id: contact.id, stage: contact.stage, position: contact.position,
                                         radiiMM: contact.radiiMM, angle: contact.angle)
            sample.force = contact.force; sample.velocity = contact.velocity; sample.proximity = contact.proximity
            sample.tilt = contact.tilt; sample.density = contact.density; sample.classification = contact.classification
            return sample
        }
        let sample = RecordedContactFrame(deviceID: deviceID, sequence: frame.sequence, time: frame.receivedAt - started,
                                          sourceTimestamp: frame.sourceTimestamp, sourceFrame: frame.sourceFrame, contacts: contacts,
                                          pointerOverPreview: pointerOverPreview?())
        guard sample.time >= 0 else { return }
        session?.receive(sample)
        writer?.append(RecordingLogEntry(kind: "contacts", frame: sample))
        if session?.attempt.radialTrial != nil, let device = devices.first(where: { $0.id == deviceID }) {
            radialEngine?.receive(sample, sizeMM: device.sizeMM)
            saveRadialUpdates()
        }
    }

    // Live preview frames keep the release gate working after the recording
    // queue is disabled. A different device or an older queued frame cannot
    // release the pair that performed this trial.
    func observeContacts(_ frame: ContactFrame, deviceID: UInt64) {
        guard frame.receivedAt.isFinite,
              frame.receivedAt >= (radialContacts[deviceID]?.time ?? -.infinity) else { return }
        let count = frame.contacts.filter(\.isTouching).count
        radialContacts[deviceID] = (frame.receivedAt, count, frame)
        if !isReplaying { classifierComparison?.receive(frame, deviceID: deviceID) }
        let wasAwaitingRelease = radialContinuation?.awaitingRelease
        radialContinuation?.receive(deviceID: deviceID, time: frame.receivedAt, count: count)
        if radialContinuation?.awaitingRelease != wasAwaitingRelease { updateControls() }
    }

    func observeCursor(_ position: CGPoint, at time: TimeInterval) {
        let previous = radialPointer
        radialPointer = position
        guard radialVisible, !isReplaying, !radialTrials.isEmpty,
              session?.attempt.radialTrial != nil || radialContinuation != nil,
              let previous, hypot(position.x - previous.x, position.y - previous.y) > 0 else { return }
        let movingOneFinger = radialContacts.filter { _, state in
            state.count == 1 && time >= state.time && time - state.time <= 0.1
        }
        guard !movingOneFinger.isEmpty else { return }
        let expectedLanding = radialEngine?.phase == .landing || radialEngine?.phase == .awaitingLift
        let shouldCancel = movingOneFinger.contains { deviceID, _ in
            if radialContinuation?.deferCursorMovement(deviceID: deviceID, at: time) == true { return false }
            if session?.attempt.radialTrial != nil, expectedLanding, radialEngine?.deviceID == deviceID { return false }
            return true
        }
        guard shouldCancel else { return }
        radialPausedByCursor = true
        if let started = session?.startedUptime, session?.attempt.radialTrial != nil {
            radialEngine?.finish(.cancelled, at: max(0, time - started))
            saveRadialUpdates()
        }
        stop()
        updateControls()
    }

    func receivePreview(_ state: RecordedPreviewState) {
        guard let started = session?.startedUptime else { return }
        var relative = state
        relative.time = max(0, state.time - started)
        guard relative.time.isFinite else { return }
        session?.tick(at: relative.time, droppedFrames: dropped)
        writer?.append(RecordingLogEntry(kind: "preview", preview: relative))
    }

    private func receive(_ event: NSEvent) -> Bool {
        if event.type == .rightMouseDown || event.type == .rightMouseUp {
            let time = ProcessInfo.processInfo.systemUptime
            let deviceID = radialContacts.filter { $0.value.count == 2 && time - $0.value.time < 0.15 }.max { $0.value.time < $1.value.time }?.key
            receiveRightClick(deviceID: deviceID, at: time, ending: event.type == .rightMouseUp)
            return false
        }
        guard let started = session?.startedUptime else { return false }
        let kind: String
        var x = 0.0, y = 0.0, value = 0.0
        switch event.type {
        case .scrollWheel: kind = "Scroll"; x = event.scrollingDeltaX; y = event.scrollingDeltaY
        case .magnify: kind = "Pinch"; value = event.magnification
        case .rotate: kind = "Tilt"; value = Double(event.rotation)
        case .swipe: kind = "Swipe"; x = event.deltaX; y = event.deltaY
        default: return false
        }
        let phase: String
        if event.phase.contains(.cancelled) { phase = "cancelled" }
        else if event.phase.contains(.ended) { phase = "ended" }
        else if event.phase.contains(.began) { phase = "began" }
        else { phase = "changed" }
        let sample = RecordedGestureEvent(kind: kind, time: ProcessInfo.processInfo.systemUptime - started,
                                          phase: phase, x: x, y: y, value: value)
        session?.receive(sample)
        writer?.append(RecordingLogEntry(kind: "appKit", gesture: sample))
        return true
    }

    func receiveRightClick(deviceID: UInt64?, at time: TimeInterval, ending: Bool = false) {
        if !ending {
            guard time - lastRightClick > 0.05 else { return }
            lastRightClick = time
        }
        if !ending { classifierComparison?.receiveRightClick(deviceID: deviceID, at: time) }
        guard let started = session?.startedUptime else { return }
        let sample = RecordedGestureEvent(kind: "Right Click", time: max(0, time - started), phase: ending ? "ended" : "began")
        session?.receive(sample)
        writer?.append(RecordingLogEntry(kind: "appKit", gesture: sample))
    }

    func tick(at time: TimeInterval) {
        classifierComparison?.tick(at: time)
        observeCursor(NSEvent.mouseLocation, at: time)
        if isReplaying {
            advanceReplay(at: time)
            if time - lastRefresh >= 0.1 { lastRefresh = time; updateStatus() }
            return
        }
        if let gate = radialContinuation {
            switch gate.decision(at: time) {
            case .start:
                guard let contacts = radialContacts[gate.deviceID] else { return }
                if gate.action == .retry {
                    retryRadialTrial(automatically: true, startingContact: (gate.deviceID, contacts.frame))
                } else {
                    startNextRadialTrial(automatically: true, startingContact: (gate.deviceID, contacts.frame))
                }
                return
            case .cancel:
                radialPausedByCursor = true
                stop()
                return
            case .wait:
                break
            }
        }
        guard let started = session?.startedUptime else { return }
        if session?.attempt.radialTrial != nil {
            radialEngine?.tick(at: time - started)
            saveRadialUpdates()
            updateRadialView()
            if let engine = radialEngine, engine.phase == .finished {
                let autoRetry = radialVisible && !radialTrials.isEmpty && engine.record.result?.outcome == .abruptMovement
                if autoRetry, annotationLoadError == nil, let row = activeRow, let attempt = row.attempt,
                   annotations.sessionState(for: attempt) != .exclude {
                    applySessionState(.exclude, to: row)
                    saveAnnotations()
                }
                stop()
                if autoRetry {
                    awaitRadialContinuation(.retry, engine: engine, started: started)
                    return
                }
                if radialVisible, radialNextIndex < radialTrials.count,
                   let result = engine.record.result, result.outcome == .acquired {
                    awaitRadialContinuation(.advance, engine: engine, started: started)
                }
                return
            }
        }
        session?.tick(at: time - started, droppedFrames: dropped)
        refresh(force: false)
    }

    private func refresh(force: Bool) {
        let time = ProcessInfo.processInfo.systemUptime
        guard force || time - lastRefresh >= 0.1 else { return }
        lastRefresh = time
        guard let session, let root = activeRow else { return }
        root.update(session.attempt)
        let oldIDs = Set(root.children.map(\.id))
        let contacts = Dictionary(uniqueKeysWithValues: root.children.compactMap { row in row.contact.map { ($0.id, row) } })
        let intervals = Dictionary(uniqueKeysWithValues: root.children.compactMap { row in row.interval.map { ($0.id, row) } })
        let recordedContacts = session.attempt.contactIndex?.contacts ?? []
        if recordedContacts.count != contacts.count, annotationLoadError == nil {
            // Persist these with the completed attempt, rather than queuing
            // annotation writes and full-table refreshes during capture.
            annotations.initializeReferenceIDs(for: session.attempt)
        }
        root.children = recordedContacts.map { contact in
            let row = contacts[contact.id] ?? RecordingRow(contact: contact)
            row.contact = contact; row.parent = root
            return row
        }
        for interval in session.attempt.intervals where interval.kind != "Contacts" || session.attempt.contactIndex == nil {
            let row = intervals[interval.id] ?? RecordingRow(interval: interval)
            row.interval = interval; row.parent = root
            root.children.append(row)
        }
        root.children = root.children.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        let inserted = IndexSet(root.children.indices.filter { !oldIDs.contains(root.children[$0].id) })
        if !inserted.isEmpty { table.insertItems(at: inserted, inParent: root, withAnimation: []) }
        if !expandedLiveRow, let row = activeRow, !row.children.isEmpty {
            table.expandItem(row)
            expandedLiveRow = true
        }
        // Existing rows, menus, selection and button tracking stay intact.
        // Only visible text in the live session changes on the recorder clock.
        updateVisibleTextCells(in: root)
        updateStatus()
    }

    private func updateControls() {
        let canChooseLabel = !isRecording && !isReplaying && !radialVisible
        if segments.isEnabled != canChooseLabel { segments.isEnabled = canChooseLabel }
        let recordTitle = radialVisible ? (isRecording ? "Stop Trial" : "Start Trial") : (isRecording ? "Stop Recording" : "Start Recording")
        if recordButton.title != recordTitle { recordButton.title = recordTitle }
        let canRecord = !isReplaying && (isRecording || !devices.isEmpty)
        if recordButton.isEnabled != canRecord { recordButton.isEnabled = canRecord }
        let replayTitle = isReplaying ? "Stop Replay" : "Replay"
        if replayButton.title != replayTitle { replayButton.title = replayTitle }
        let canReplay = !isRecording && (isReplaying || !replaySelections.isEmpty)
        if replayButton.isEnabled != canReplay { replayButton.isEnabled = canReplay }
        let contactRows = selectedRows.filter { !$0.contactIDs.isEmpty }
        let attemptIDs = Set(contactRows.compactMap { $0.containingAttempt?.id })
        let attempt = attemptIDs.count == 1 ? contactRows.first?.containingAttempt : nil
        let contactIDs = Set(contactRows.flatMap(\.contactIDs))
        let canAnnotate = annotationLoadError == nil && attempt != nil && attempt?.id != activeRow?.attempt?.id
        let canGroup = canAnnotate && contactIDs.count >= 2
        let canUngroup = canAnnotate && contactRows.contains { $0.containingGroup != nil }
        if groupButton.isEnabled != canGroup { groupButton.isEnabled = canGroup }
        if ungroupButton.isEnabled != canUngroup { ungroupButton.isEnabled = canUngroup }
        if contactIDs.count < 2 { groupButton.toolTip = "Select at least two contact rows within the same session." }
        else if attempt == nil { groupButton.toolTip = "Contacts must belong to the same session." }
        else if attempt?.id == activeRow?.attempt?.id { groupButton.toolTip = "Stop this recording before grouping its contacts." }
        else { groupButton.toolTip = "Group the selected contacts. Select a group and more contacts to add them." }
        ungroupButton.toolTip = "Select a contact group or any of its member contacts."
        counterexamplesButton.isEnabled = annotationLoadError == nil
        radialButton.isEnabled = radialVisible || (!isRecording && !isReplaying)
        updateRadialView()
        updateStatus()
    }

    private func updateStatus() {
        let message: String
        if let session {
            message = String(format: "● Recording · %.1f s · %d frames%@ · Space / Shift-Space to stop", session.attempt.duration,
                                        session.attempt.frameCount, dropped > 0 ? " · \(dropped) dropped" : "")
        } else if isReplaying {
            if replayCleared {
                message = "↻ Repeat pause · Space / Shift-Space to stop"
            } else if let cursor = replayCursor {
                message = String(format: "▶ Replaying · %.1f / %.1f s · Space / Shift-Space to stop", cursor.position - cursor.start, cursor.duration)
            } else { message = "Loading replay… · Space / Shift-Space to stop" }
        } else if let annotationLoadError { message = "Could not load annotations: \(annotationLoadError)" }
        else if let saveError { message = saveError }
        else if radialVisible {
            message = radialTrials.isEmpty ? "Space starts the selected block" : radialContinuation?.awaitingContact == true
                ? "Place two fingers to \(radialContinuation?.action == .retry ? "retry" : "advance") · Space cancels"
                : radialContinuation != nil
                ? "Lift all fingers, then place two to \(radialContinuation?.action == .retry ? "retry" : "advance") · Space cancels"
                : radialNextIndex < radialTrials.count
                ? "\(radialPausedByCursor ? "Paused by cursor movement · " : "")Space starts the next trial"
                : "Block complete · End Block to choose another plan"
        }
        else { message = "\(attemptRows.count) sessions · Shift-Space to record · Space to replay" }
        if status.stringValue != message { status.stringValue = message }
    }

    private func showFailure(_ error: Error) { saveError = "Save failed: \(error.localizedDescription)"; updateControls() }

    @objc private func revealFiles() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch { showFailure(error) }
    }

    func windowWillClose(_ notification: Notification) { stop() }
    func close() { stop(); classifierComparison?.close(); window.close() }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? RecordingRow)?.children.count ?? rows.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? RecordingRow)?.children[index] ?? rows[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let row = item as? RecordingRow else { return false }
        return row.attempt != nil || row.group != nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateControls()
        guard !reloadingOutline, !isRecording else { return }
        startReplay(replaySelections)
    }
    func outlineViewItemDidExpand(_ notification: Notification) { redrawPills() }
    func outlineViewItemDidCollapse(_ notification: Notification) { redrawPills() }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let row = item as? RecordingRow else { return nil }
        let view = RecordingTableRowView()
        view.pill = { [weak self, weak row, weak view] in
            guard let self, let row, let view, let group = row.containingGroup else { return nil }
            guard let groupRow = row.group != nil ? row : row.parent else { return nil }
            let first = self.table.row(forItem: groupRow)
            guard first >= 0 else { return nil }
            let last = first + (self.table.isItemExpanded(groupRow) ? groupRow.children.count : 0)
            var rect = self.table.rect(ofRow: first).union(self.table.rect(ofRow: last))
            rect = view.convert(rect, from: self.table)
            rect = CGRect(x: 3, y: rect.minY + 3, width: 3, height: max(3, rect.height - 6))
            return (NSColor(calibratedHue: group.hue, saturation: 0.55, brightness: 0.82, alpha: 1), rect)
        }
        return view
    }

    private func sessionStateCell(for row: RecordingRow, column: NSTableColumn) -> NSView? {
        guard row.attempt != nil else { return nil }
        let cell = table.makeView(withIdentifier: column.identifier, owner: self) as? SessionStateCellView ?? SessionStateCellView()
        if cell.buttons.isEmpty {
            cell.identifier = column.identifier
            for (state, symbol) in [(GestureSessionState.exclude, "nosign"), (.ready, "checkmark.circle.fill")] {
                let button = SessionStateButton(title: "", target: self, action: #selector(changeSessionState(_:)))
                button.marking = state
                button.identifier = NSUserInterfaceItemIdentifier(state.rawValue)
                button.setButtonType(.toggle)
                button.isBordered = false
                // Render in a separate image view so the toggle button's off
                // appearance cannot add opacity changes to the symbol.
                let symbolView = button.symbolView
                symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                symbolView.imageScaling = .scaleProportionallyUpOrDown
                symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                symbolView.setAccessibilityElement(false)
                symbolView.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(symbolView)
                NSLayoutConstraint.activate([
                    symbolView.widthAnchor.constraint(equalToConstant: 18), symbolView.heightAnchor.constraint(equalToConstant: 18),
                    symbolView.centerXAnchor.constraint(equalTo: button.centerXAnchor), symbolView.centerYAnchor.constraint(equalTo: button.centerYAnchor)
                ])
                button.toolTip = state.rawValue
                button.setAccessibilityLabel(state.rawValue)
                button.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 24), button.heightAnchor.constraint(equalToConstant: 22)])
                cell.buttons.append(button)
            }
            let stack = NSStackView(views: cell.buttons)
            stack.spacing = 6
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: cell.centerXAnchor), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        updateSessionStateCell(cell, for: row)
        return cell
    }

    private func updateSessionStateCell(_ cell: SessionStateCellView, for row: RecordingRow) {
        guard let attempt = row.attempt else { return }
        let state = annotations.sessionState(for: attempt)
        for button in cell.buttons {
            let selected = state == button.marking
            let color = (button.marking == .ready ? NSColor.systemGreen : .systemRed).usingColorSpace(.sRGB)!
            // HSV value is the maximum RGB component. Fully desaturate the
            // inactive symbol while preserving that value and full opacity.
            let value = max(color.redComponent, color.greenComponent, color.blueComponent)
            button.contentTintColor = selected ? color : NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
            button.symbolView.contentTintColor = button.contentTintColor
            button.state = selected ? .on : .off
            button.row = row
            button.isEnabled = annotationLoadError == nil
        }
    }

    private func categoryCell(for row: RecordingRow, column: NSTableColumn) -> NSView? {
        guard row.containingAttempt != nil else { return nil }
        let counterexample = column.identifier.rawValue == "counterexample"
        let cell = table.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        let popup: CategoryPopUp
        if let existing = cell.subviews.first as? CategoryPopUp { popup = existing }
        else {
            popup = CategoryPopUp(frame: .zero, pullsDown: false)
            popup.isBordered = false
            popup.controlSize = .small
            popup.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(popup); cell.identifier = column.identifier
            NSLayoutConstraint.activate([
                popup.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                popup.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                popup.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            popup.addItem(withTitle: counterexample ? "—" : "")
            popup.lastItem?.tag = counterexample ? -1 : -2
            for (index, label) in GestureLabel.allCases.enumerated() where !counterexample || label != .none {
                popup.addItem(withTitle: label.rawValue)
                popup.lastItem?.tag = index
            }
            popup.menu?.autoenablesItems = false
            popup.isCounterexample = counterexample
            popup.target = self; popup.action = #selector(changeCategory(_:))
            popup.setAccessibilityLabel(counterexample ? "Similar to, but not" : "Category")
        }
        updateCategoryPopUp(popup, for: row, counterexample: counterexample)
        return cell
    }

    private func updateCategoryPopUp(_ popup: CategoryPopUp, for row: RecordingRow, counterexample: Bool) {
        guard let attempt = row.containingAttempt else { return }
        let sessionCategory = annotations.category(for: attempt)
        let group = row.containingGroup
        let contactKey = row.contact.map { attempt.id.uuidString + "/" + $0.id }
        let category = group?.category ?? contactKey.map { annotations.categories[$0] ?? GestureCategory(label: .none) } ?? sessionCategory
        let inherited = group != nil ? sessionCategory
            : row.contact != nil ? GestureCategory(label: .none) : annotations.inheritedCategory(for: attempt)
        let inherits = group.map { annotations.inheritsCategory(for: $0, in: attempt) }
            ?? contactKey.map { annotations.categories[$0] == nil } ?? annotations.inheritsCategory(for: attempt)
        if !counterexample {
            let title = "\(inherited.label.rawValue) (Inherit)"
            if popup.item(at: 0)?.title != title {
                popup.item(at: 0)?.title = title
                popup.item(at: 0)?.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.secondaryLabelColor])
            }
        } else {
            for item in popup.itemArray where item.tag >= 0 {
                item.isEnabled = GestureLabel.allCases[item.tag] != category.label
            }
        }
        let selected = counterexample ? category.counterexampleTo : category.label
        let tag = !counterexample && inherits ? -2 : selected.flatMap { GestureLabel.allCases.firstIndex(of: $0) } ?? -1
        if popup.selectedTag() != tag { popup.selectItem(withTag: tag) }
        let tint: NSColor? = inherits ? .secondaryLabelColor : nil
        if popup.contentTintColor != tint { popup.contentTintColor = tint }
        popup.row = row
        let enabled = attempt.id != activeRow?.attempt?.id && annotationLoadError == nil
        if popup.isEnabled != enabled { popup.isEnabled = enabled }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? RecordingRow, let column = tableColumn else { return nil }
        if column.identifier.rawValue == "state" { return sessionStateCell(for: row, column: column) }
        let categoryColumn = ["category", "counterexample"].contains(column.identifier.rawValue)
        if categoryColumn, row.attempt != nil || row.contact != nil || row.group != nil { return categoryCell(for: row, column: column) }
        let identifier = categoryColumn ? NSUserInterfaceItemIdentifier(column.identifier.rawValue + ".summary") : column.identifier
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? RecordingTextCellView ?? RecordingTextCellView()
        if cell.textField == nil {
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail; text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text); cell.textField = text; cell.identifier = identifier
            let showsDot = column.identifier.rawValue == "gesture"
            if showsDot {
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
                dot.layer?.cornerRadius = 7.5
                dot.identifier = NSUserInterfaceItemIdentifier("replayDot")
                dot.setAccessibilityElement(true)
                dot.setAccessibilityRole(.image)
                dot.setAccessibilityLabel("Active in replay")
                dot.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(dot); cell.replayDot = dot
                NSLayoutConstraint.activate([
                    dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                    dot.widthAnchor.constraint(equalToConstant: 15), dot.heightAnchor.constraint(equalToConstant: 15),
                    dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: showsDot ? 26 : 4),
                                         text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                                         text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        updateTextCell(cell, for: row, column: column.identifier.rawValue)
        cell.replayDot?.isHidden = !isRowReplaying(row)
        cell.textField?.textColor = row.interval == nil ? .labelColor : .secondaryLabelColor
        cell.textField?.font = ["start", "end", "duration", "samples"].contains(column.identifier.rawValue)
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize, weight: row.group == nil ? .regular : .medium)
        return cell
    }

    private func updateTextCell(_ cell: RecordingTextCellView, for row: RecordingRow, column: String) {
        let interval = row.interval
        let attempt = row.attempt
        let start = interval?.start ?? row.contact?.start ?? (row.group != nil ? row.contactSummary.start : 0)
        let end = attempt?.duration ?? interval?.end ?? row.contact?.end ?? row.contactSummary.end
        let text: String
        switch column {
        case "gesture":
            text = row.group.map { group in
                "\(annotations.referenceID(for: group).map { $0 + " · " } ?? "")Group · \(row.children.count) contacts"
            }
                ?? row.contact.map { contact in
                    let reference = row.containingAttempt.flatMap { annotations.referenceID(for: contact, in: $0) }
                    return "\(reference.map { $0 + " · " } ?? "")Contact #\(contact.pathID)"
                }
                ?? attempt.map { "\(annotations.referenceID(for: $0).map { $0 + " · " } ?? "")\($0.radialTrial.map { "Radial \($0.configuration.protocolTitle) · \($0.configuration.practice ? "practice" : String($0.configuration.number)) · \(row === activeRow && radialEngine?.record.cue == nil && radialEngine?.record.preparation?.targetTime == nil ? "Preparing" : $0.configuration.title)" } ?? "Session · " + clock.string(from: $0.startedAt))\(row === activeRow ? " · Recording" : (row.saving ? " · Saving" : ""))\($0.contactIndex == nil ? " · Loading contacts" : "")" }
                ?? interval?.kind ?? ""
        case "category": text = attempt.map { annotations.category(for: $0).label.rawValue } ?? ""
        case "counterexample": text = attempt.flatMap { annotations.category(for: $0).counterexampleTo?.rawValue } ?? ""
        case "device":
            if interval != nil || row.contact != nil {
                text = (interval?.deviceID ?? row.contact?.deviceID).flatMap { id in row.containingAttempt?.devices.first { $0.id == id }?.name } ?? "AppKit"
            } else {
                let count = attempt?.devices.count ?? row.contactSummary.deviceCount
                text = "\(count) trackpad\(count == 1 ? "" : "s")"
            }
        case "start": text = String(format: "%.3f s", start)
        case "end": text = String(format: "%.3f s", end)
        case "duration": text = String(format: "%.3f s", max(0, end - start))
        case "samples": text = String(attempt?.frameCount ?? interval?.samples ?? row.contact?.samples ?? row.contactSummary.samples)
        default: text = ""
        }
        if cell.textField?.stringValue != text { cell.textField?.stringValue = text }
    }
}
