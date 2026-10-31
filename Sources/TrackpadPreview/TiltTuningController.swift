import AppKit
import TrackpadCore

@MainActor
private final class TuningWindow: NSWindow {
    var onRightClick: ((TimeInterval) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown { onRightClick?(event.timestamp) }
        super.sendEvent(event)
    }
}

/// A one-time developer tuning session. Drafts affect only the selected device;
/// closing the window restores its saved settings, and Apply persists them.
@MainActor
final class TiltTuningController: NSObject, NSWindowDelegate {
    var onRightClick: ((UInt64?, TimeInterval) -> Void)?
    var onThresholdChange: ((UInt64, TimeInterval) -> Void)?
    private let window: NSWindow
    private let confidence = NSSlider(value: 0.7, minValue: 0.3, maxValue: 0.85, target: nil, action: nil)
    private let radial = NSSlider(value: 0.7, minValue: 0.2, maxValue: 1, target: nil, action: nil)
    private let persistence = NSSlider(value: 24, minValue: 8, maxValue: 40, target: nil, action: nil)
    private let values = (0..<3).map { _ in NSTextField(labelWithString: "") }
    private let status = NSTextField(wrappingLabelWithString: "Loading recorded gestures…")
    private let controlsStatus = NSTextField(wrappingLabelWithString: "")
    private let liveStatus = NSTextField(labelWithString: "Live · waiting for two contacts")
    private let visualization = TuningVisualizationView(frame: NSRect(x: 0, y: 0, width: 690, height: 520))
    private let baselineButton = NSButton(title: "Baseline", target: nil, action: nil)
    private let applyButton = NSButton(title: "Use Settings", target: nil, action: nil)
    private let preference = NSSlider(value: 0, minValue: 0, maxValue: 4, target: nil, action: nil)
    private let preferenceName = NSTextField(labelWithString: "")
    private let comparisonStatus = NSTextField(labelWithString: "")
    private let controlsReview = NSButton(title: "Other recordings", target: nil, action: nil)
    private let thresholdsButton = NSButton(checkboxWithTitle: "Thresholds", target: nil, action: nil)
    private var thresholdRows: [NSStackView] = []
    private var profiles: [(String, TiltThresholds)] = []
    private var cachedResults: [[ClassifierTuningDataset.Result]] = []
    private var savedThresholds = TiltThresholds.standard
    private var isEvaluating = false
    private var dataset: ClassifierTuningDataset?
    private var baseline: [ClassifierTuningDataset.Result] = []
    private var deviceID: UInt64?
    private var generation: UInt64 = 0
    private var evaluation: Task<Void, Never>?
    private var replayTask: Task<[ClassifierTuningDataset.Result], Never>?
    private var recording = false
    private var liveTransform = ContactTransform()
    private var devices: [TrackpadDevice] = []
    private var applied = false

    init(datasetURL: URL) {
        window = TuningWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        (window as? TuningWindow)?.onRightClick = { [weak self] time in
            guard let self else { return }
            if let onRightClick = self.onRightClick { onRightClick(self.deviceID, time) }
            else { self.interrupt(deviceID: self.deviceID) }
        }
        window.title = "Tune Tilt"
        window.minSize = NSSize(width: 610, height: 620)
        window.isReleasedWhenClosed = false; window.delegate = self
        let heading = NSTextField(labelWithString: "Tilt preference")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        preferenceName.font = .systemFont(ofSize: 13, weight: .medium)
        preferenceName.textColor = .secondaryLabelColor
        let headingRow = NSStackView(views: [heading, NSView(), preferenceName]); headingRow.spacing = 12
        preference.target = self; preference.action = #selector(changePreference)
        preference.isContinuous = true; preference.numberOfTickMarks = 5; preference.allowsTickMarkValuesOnly = true
        preference.setAccessibilityLabel("Tilt preference")
        let less = NSTextField(labelWithString: "Less"), more = NSTextField(labelWithString: "More")
        for label in [less, more] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor }
        let endpoints = NSStackView(views: [less, NSView(), more])
        let sliderRows = zip(["Turning evidence", "Angular / radial travel", "Sustained turning"], [confidence, radial, persistence]).enumerated().map { index, entry in
            let label = NSTextField(labelWithString: entry.0)
            label.font = .systemFont(ofSize: 12); label.widthAnchor.constraint(equalToConstant: 155).isActive = true
            let slider = entry.1; slider.target = self; slider.action = #selector(changeThresholds); slider.isContinuous = true
            slider.setAccessibilityLabel(entry.0)
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
            values[index].font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            values[index].alignment = .right; values[index].widthAnchor.constraint(equalToConstant: 60).isActive = true
            let row = NSStackView(views: [label, slider, values[index]])
            row.spacing = 12; row.distribution = .fill; return row
        }
        confidence.toolTip = "Minimum coordinated turning evidence."
        radial.toolTip = "Minimum angular travel as a fraction of radial travel."
        persistence.toolTip = "How long turning evidence must persist."
        thresholdRows = sliderRows
        thresholdsButton.title = "Advanced thresholds"
        thresholdsButton.target = self; thresholdsButton.action = #selector(toggleThresholds)
        baselineButton.title = "Original settings"
        baselineButton.target = self; baselineButton.action = #selector(resetToBaseline)
        baselineButton.toolTip = "Try the app’s original thresholds. Your saved settings remain available on the preference slider."
        baselineButton.isHidden = true
        status.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        comparisonStatus.font = .systemFont(ofSize: 12); comparisonStatus.textColor = .secondaryLabelColor
        controlsStatus.font = .systemFont(ofSize: 12); controlsStatus.textColor = .secondaryLabelColor
        controlsStatus.isHidden = true
        controlsReview.target = self; controlsReview.action = #selector(reviewControls)
        controlsReview.bezelStyle = .inline; controlsReview.contentTintColor = .secondaryLabelColor
        controlsReview.setAccessibilityLabel("Inspect changes to other recordings")
        let outcome = NSStackView(views: [status, NSView()]); outcome.spacing = 12
        liveStatus.font = .systemFont(ofSize: 11); liveStatus.textColor = .secondaryLabelColor
        liveStatus.stringValue = "Lift both fingers after changing the preference, then try a gesture."
        let scroll = TuningVisualizationScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.documentView = visualization
        applyButton.title = "Save preference"
        applyButton.target = self; applyButton.action = #selector(apply); applyButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [thresholdsButton, NSView(), cancel, applyButton]); buttons.spacing = 10
        let separator = NSBox(); separator.boxType = .separator
        let stack = NSStackView(views: [headingRow, preference, endpoints] + sliderRows + [baselineButton, separator, outcome, comparisonStatus, controlsReview, scroll, liveStatus, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(stack); window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            preference.heightAnchor.constraint(equalToConstant: 32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ] + ([headingRow, preference, endpoints, separator, outcome, comparisonStatus, scroll, liveStatus, buttons] + sliderRows).map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        for row in sliderRows { row.isHidden = true }
        updateValues(); setControlsEnabled(false)
        load(datasetURL)
    }

    private var thresholds: TiltThresholds {
        TiltThresholds(tangentialConfidence: confidence.doubleValue, angularToRadialRatio: radial.doubleValue,
                       persistence: persistence.doubleValue / 1000)
    }

    private func load(_ url: URL) {
        Task { [weak self] in
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    let data = try JSONDecoder().decode(ClassifierTuningDataset.self, from: Data(contentsOf: url))
                    let targets = data.examples.filter { $0.session == data.session }
                    guard let target = targets.first, !target.builtIn, UInt64(target.deviceID) != nil,
                          targets.allSatisfy({ $0.deviceID == target.deviceID && !$0.builtIn }) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    return (data, UInt64(target.deviceID)!)
                }.value
                guard let self, self.window.isVisible else { return }
                self.dataset = loaded.0; self.deviceID = loaded.1
                self.setDevices(self.devices)
                self.window.title = "Tune Tilt · \(loaded.0.session)"
                let saved = ClassifierTuningStore.shared.thresholds(for: loaded.1)
                self.savedThresholds = saved
                var choices: [(String, TiltThresholds)] = [
                    ("Original", .standard), ("Slight", .init(angularToRadialRatio: 0.55)),
                    ("More", .init(tangentialConfidence: 0.65, angularToRadialRatio: 0.40, persistence: 0.016)),
                    ("Strong", .init(tangentialConfidence: 0.35, angularToRadialRatio: 0.40, persistence: 0.008)),
                    ("Most", .init(tangentialConfidence: 0.33, angularToRadialRatio: 0.40, persistence: 0.008))]
                if !choices.contains(where: { $0.1 == saved }) { choices.append(("Saved", saved)) }
                let data = loaded.0, targetDevice = String(loaded.1), choicesToReplay = choices
                let replays = await Task.detached(priority: .userInitiated) {
                    choicesToReplay.map { data.evaluate($0.1, deviceID: targetDevice) }
                }.value
                guard self.window.isVisible else { return }
                let ordered = choices.indices.sorted {
                    let a = replays[$0].filter { $0.session == data.session && $0.decision == .rotation }.count
                    let b = replays[$1].filter { $0.session == data.session && $0.decision == .rotation }.count
                    return a == b ? $0 < $1 : a < b
                }
                self.profiles = ordered.map { choices[$0] }; self.cachedResults = ordered.map { replays[$0] }
                self.baseline = replays[choices.firstIndex { $0.1 == saved }!]
                self.preference.maxValue = Double(self.profiles.count - 1)
                self.preference.numberOfTickMarks = self.profiles.count
                self.setValues(saved)
                self.setControlsEnabled(!self.recording); self.changeThresholds()
            } catch {
                self?.status.stringValue = "Couldn’t load tuning examples: \(error.localizedDescription)"
            }
        }
    }

    private func setValues(_ value: TiltThresholds) {
        confidence.doubleValue = value.tangentialConfidence
        radial.doubleValue = value.angularToRadialRatio
        persistence.doubleValue = value.persistence * 1000
        updateValues()
    }

    private func updateValues() {
        values[0].stringValue = String(format: "%.3f", confidence.doubleValue)
        values[1].stringValue = String(format: "%.2f", radial.doubleValue)
        values[2].stringValue = String(format: "%.0f ms", persistence.doubleValue)
    }

    @objc private func changeThresholds() {
        guard let dataset, let deviceID, !recording else { return }
        visualization.stopPlayback()
        confidence.doubleValue = (confidence.doubleValue * 1000).rounded() / 1000
        radial.doubleValue = (radial.doubleValue * 100).rounded() / 100
        persistence.doubleValue = persistence.doubleValue.rounded()
        updateValues()
        let value = thresholds
        if let index = profiles.firstIndex(where: { $0.1 == value }) {
            preference.doubleValue = Double(index)
            preferenceName.stringValue = profiles[index].0 + (value == savedThresholds ? " · saved" : "")
        } else { preferenceName.stringValue = "Custom thresholds" }
        preference.setAccessibilityValueDescription(preferenceName.stringValue)
        let changed = ClassifierTuningStore.shared.thresholds(for: deviceID) != value
        ClassifierTuningStore.shared.preview(value, for: deviceID)
        _ = liveTransform.reconfigure(.init(tiltThresholds: value))
        if changed { onThresholdChange?(deviceID, ProcessInfo.processInfo.systemUptime) }
        liveStatus.stringValue = "Lift both fingers, then try a gesture with this preference."
        generation &+= 1; let revision = generation
        evaluation?.cancel(); replayTask?.cancel(); isEvaluating = true; applyButton.isEnabled = false
        visualization.setUpdating(true)
        if let index = profiles.firstIndex(where: { $0.1 == value }) {
            isEvaluating = false; showResults(cachedResults[index]); applyButton.isEnabled = !recording
            return
        }
        comparisonStatus.stringValue = "Updating recordings…"
        evaluation = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let replay = Task.detached(priority: .userInitiated) {
                dataset.evaluate(value, deviceID: String(deviceID), isCancelled: { Task.isCancelled })
            }
            self?.replayTask = replay
            let results = await replay.value
            guard let self, !Task.isCancelled, self.generation == revision else { return }
            self.isEvaluating = false; self.showResults(results); self.applyButton.isEnabled = !self.recording
        }
    }

    private func showResults(_ results: [ClassifierTuningDataset.Result]) {
        guard let dataset else { return }
        let pairs = Array(zip(baseline, results))
        let primary = pairs.filter { $0.0.session == dataset.session }
        let allControls = pairs.filter { $0.0.session != dataset.session }
        let controls = allControls.filter { $0.0.deviceID == String(deviceID ?? 0) }
        let losses = controls.filter { $0.0.isCorrect && !$0.1.isCorrect }
        let gains = controls.filter { !$0.0.isCorrect && $0.1.isCorrect }
        let delayed = controls.filter {
            guard let before = $0.0.time, let after = $0.1.time else { return false }
            return after > before + 1e-8
        }
        visualization.setUpdating(false)
        let recognized = primary.filter { $0.1.decision == .rotation }.count
        let savedCount = primary.filter { $0.0.decision == .rotation }.count
        status.stringValue = "\(recognized) of \(primary.count) recognized as Tilt"
        let difference = recognized - savedCount
        comparisonStatus.stringValue = difference == 0 ? "Same total as your saved settings · click a gesture to replay" :
            "\(abs(difference)) \(difference > 0 ? "more" : "fewer") than your saved settings · click a gesture to replay"
        let maximumDelay = delayed.map { (($0.1.time ?? 0) - ($0.0.time ?? 0)) * 1000 }.max() ?? 0
        let timing = delayed.isEmpty ? "0 delayed" : "\(delayed.count) delayed (up to +\(Int(maximumDelay.rounded())) ms)"
        controlsStatus.stringValue = "Compared with saved settings: \(losses.count) new mismatches · \(gains.count) corrections · \(timing)"
        controlsStatus.toolTip = "All \(allControls.count) other recordings replayed; \(controls.count) use this trackpad. Delays include corrected classifications when both settings decide."
        controlsReview.title = "Other gestures: \(losses.count) new misreads · \(delayed.count) slower ›"
        controlsReview.contentTintColor = losses.isEmpty ? .secondaryLabelColor : .systemRed
        controlsReview.toolTip = controlsStatus.stringValue + " · Compared with the recorded gesture labels. Click to inspect."
        visualization.configure(examples: dataset.examples, baseline: baseline, candidates: results,
            session: dataset.session, deviceID: String(deviceID ?? 0), thresholds: thresholds, sizeMM: sizeMM,
            baselineThresholds: savedThresholds, controlsSummary: controlsStatus.stringValue)
    }

    func receive(_ frame: ContactFrame, deviceID: UInt64, recognize: Bool, at time: TimeInterval, pointerOverTarget: Bool,
                 actionAvailability: GestureActionAvailability? = nil) {
        guard window.isVisible, self.deviceID == deviceID else { return }
        guard recognize else { _ = liveTransform.interrupt(); return }
        guard let sizeMM else { return }
        let contacts = frame.contacts.filter(\.isTouching).map {
            TransformContact(id: $0.id, positionMM: CGPoint(x: $0.position.x * sizeMM.width, y: $0.position.y * sizeMM.height),
                             orientation: Double($0.angle), radiiMM: $0.radiiMM, force: Double($0.force))
        }
        let previous = liveTransform.intent
        _ = liveTransform.receive(contacts, canBegin: true, at: time, sourceTimestamp: frame.sourceTimestamp,
                                  pointerOverTarget: pointerOverTarget, actionAvailability: actionAvailability)
        if liveTransform.intent != .undecided && previous == .undecided {
            liveStatus.stringValue = "Live preview · \(liveTransform.intent.title) · \(Int((liveTransform.elapsed * 1000).rounded())) ms"
        }
    }

    private var sizeMM: CGSize?
    func setDevices(_ devices: [TrackpadDevice]) {
        self.devices = devices; sizeMM = devices.first { $0.id == deviceID }?.sizeMM
        visualization.setDeviceSize(sizeMM)
    }
    func interrupt(deviceID: UInt64?) {
        guard deviceID == nil || deviceID == self.deviceID else { return }
        _ = liveTransform.interrupt(); liveStatus.stringValue = "Live preview · interrupted; lift both fingers"
    }
    func setRecordingActive(_ active: Bool) {
        recording = active; setControlsEnabled(!active && dataset != nil)
        if active { liveStatus.stringValue = "Stop recording to adjust thresholds" }
    }
    private func setControlsEnabled(_ enabled: Bool) {
        for control in [confidence, radial, persistence, baselineButton, preference, controlsReview] as [NSControl] { control.isEnabled = enabled }
        applyButton.isEnabled = enabled && !isEvaluating
    }
    @objc private func changePreference() {
        let index = Int(preference.doubleValue.rounded())
        guard profiles.indices.contains(index) else { return }
        setValues(profiles[index].1); changeThresholds()
    }
    @objc private func reviewControls() { visualization.showControls() }
    @objc private func toggleThresholds() {
        for row in thresholdRows { row.isHidden = thresholdsButton.state != .on }
        baselineButton.isHidden = thresholdsButton.state != .on
    }
    @objc private func resetToBaseline() { setValues(.standard); changeThresholds() }
    @objc private func apply() {
        guard let deviceID, !recording else { return }
        do { try ClassifierTuningStore.shared.apply(thresholds, for: deviceID); applied = true; window.close() }
        catch { status.stringValue = "Couldn’t save settings: \(error.localizedDescription)" }
    }
    @objc private func cancel() { window.close() }
    func windowWillClose(_ notification: Notification) {
        visualization.stopPlayback()
        generation &+= 1; evaluation?.cancel(); replayTask?.cancel()
        if let deviceID {
            ClassifierTuningStore.shared.discardPreview(for: deviceID)
            if !applied { onThresholdChange?(deviceID, ProcessInfo.processInfo.systemUptime) }
        }
    }
    func show() { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}
