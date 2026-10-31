import AppKit
import TrackpadCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var capture: TrackpadCapture?
    private let overlay: OverlayController
    private var statusItem: NSStatusItem!
    private let frameLoop = DisplayFrameLoop()
    private var discoveryTimer: DispatchSourceTimer?
    private var devices: [TrackpadDevice] = []
    private var sleeping = false
    private var demo = false
    private var demoStart: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var recorder: GestureRecorderController?
    private var recognitionDelivery = RecognitionDelivery()
    private let deliveryTrace = RecognitionTrace.fromEnvironment()
    private let snapshotURL: URL?
    private let snapshotDelay: TimeInterval
    private let tuningURL: URL?
    private var tiltTuning: TiltTuningController?

    init(snapshotURL: URL? = nil, snapshotDelay: TimeInterval = 1, tuningURL: URL? = nil) {
        self.snapshotURL = snapshotURL
        self.snapshotDelay = snapshotDelay
        self.tuningURL = tuningURL
        self.overlay = OverlayController(offscreen: snapshotURL != nil)
        super.init()
        overlay.onRightClick = { [weak self] deviceID, time in
            guard let self else { return }
            if let recorder = self.recorder { recorder.receiveRightClick(deviceID: deviceID, at: time) }
            else { self.interruptRecognition(deviceID: deviceID, at: time) }
        }
        if let deliveryTrace {
            overlay.onRecognitionDecision = { deviceID, frame, intent, elapsed in
                deliveryTrace.decision(deviceID: deviceID, frame: frame, intent: intent, elapsed: elapsed)
            }
            overlay.onVisualSubmission = { time, scale, displayedScale, opacity, displayedOpacity in
                deliveryTrace.visualSubmission(at: time, scale: scale, displayedScale: displayedScale,
                                               opacity: opacity, displayedOpacity: displayedOpacity)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        demo = CommandLine.arguments.contains("--demo")
        demoStart = ProcessInfo.processInfo.systemUptime
        if !demo { capture = TrackpadCapture() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.and.hand.point.up.left", accessibilityDescription: "Trackcard")
            ?? NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Trackcard")
        statusItem.button?.toolTip = "Trackcard"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshDevices()
        tick()
        frameLoop.onFrame = { [weak self] _ in self?.tick() }
        restartFrameLoop()
        let discoveryTimer = DispatchSource.makeTimerSource(queue: .main)
        discoveryTimer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(100))
        discoveryTimer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        self.discoveryTimer = discoveryTimer
        discoveryTimer.resume()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlay.configure()
                self?.restartFrameLoop()
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = true
                self.recorder?.stop()
                self.frameLoop.stop()
                self.capture?.close()
                self.capture = nil
                self.recognitionDelivery = RecognitionDelivery()
                self.overlay.resetContacts()
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = false
                if !self.demo { self.capture = TrackpadCapture() }
                self.refreshDevices()
                self.overlay.configure()
                self.restartFrameLoop()
            }
        })
        if let snapshotURL {
            DispatchQueue.main.asyncAfter(deadline: .now() + snapshotDelay) { [weak self] in
                guard let self else { return }
                do {
                    try self.overlay.writeSnapshot(to: snapshotURL)
                    NSApp.terminate(nil)
                } catch {
                    fputs("Snapshot failed: \(error.localizedDescription)\n", stderr)
                    self.capture?.close()
                    self.overlay.close()
                    exit(1)
                }
            }
        }
        if CommandLine.arguments.contains("--record-gestures"), snapshotURL == nil { showRecorder() }
        if CommandLine.arguments.contains("--compare-classifiers"), snapshotURL == nil, !demo { showClassifiers() }
        if let tuningURL, snapshotURL == nil, !demo {
            let tuning = TiltTuningController(datasetURL: tuningURL)
            tuning.onRightClick = { [weak self] deviceID, time in self?.interruptRecognition(deviceID: deviceID, at: time) }
            tuning.onThresholdChange = { [weak self] deviceID, time in
                self?.interruptRecognition(deviceID: deviceID, at: time, nativeClick: false)
            }
            tiltTuning = tuning; tuning.setDevices(devices); tuning.show()
        }
    }

    private func refreshDevices() {
        guard !sleeping else { return }
        if demo {
            devices = [
                TrackpadDevice(id: 1, name: "Built-in Trackpad", sizeMM: CGSize(width: 124.8, height: 76.8), builtIn: true, color: nil),
                TrackpadDevice(id: 2, name: "Magic Trackpad", sizeMM: CGSize(width: 160, height: 114.9), builtIn: false, color: nil)
            ]
        } else {
            devices = capture?.refresh() ?? []
        }
        overlay.setDevices(devices)
        recognitionDelivery.setDevices(devices.map(\.id))
        recorder?.setDevices(devices)
        tiltTuning?.setDevices(devices)
        statusItem.button?.toolTip = devices.isEmpty ? (capture?.error ?? "No trackpads connected") : "Trackcard · \(devices.count) connected"
    }

    private func restartFrameLoop() {
        guard !sleeping, let screen = overlay.screen else { frameLoop.stop(); return }
        frameLoop.start(on: screen)
    }

    private func tick() {
        guard !sleeping else { return }
        let time = ProcessInfo.processInfo.systemUptime
        if demo { tickDemo(at: time) }
        else {
            let batch = capture?.recognitionFrames()
            let deviceIDs = Set(devices.map(\.id))
            for (deviceID, frame) in batch?.frames ?? [] where deviceIDs.contains(deviceID) {
                let drainedAt = ProcessInfo.processInfo.systemUptime
                let receipt = recognitionDelivery.receive(deviceID: deviceID, streamID: frame.streamID,
                    sequence: frame.sequence, receivedAt: frame.receivedAt, sourceTimestamp: frame.sourceTimestamp,
                    touchingCount: frame.contacts.filter(\.isTouching).count, drainedAt: drainedAt,
                    callbackAt: frame.callbackAt > 0 ? frame.callbackAt : nil)
                deliveryTrace?.frame(deviceID: deviceID, frame: frame, receipt: receipt,
                                     drainedAt: drainedAt, dropped: batch?.dropped ?? 0)
                if receipt.interrupted {
                    overlay.interruptRecognition(deviceID: deviceID)
                    recorder?.interruptRecognition(deviceID: deviceID)
                    tiltTuning?.interrupt(deviceID: deviceID)
                }
                guard receipt.accepted else { continue }
                overlay.receive(frame, from: deviceID, recognize: receipt.canRecognize, at: receipt.recognitionTime)
                recorder?.observeContacts(frame, deviceID: deviceID,
                    recognize: receipt.canRecognize, at: receipt.recognitionTime)
                tiltTuning?.receive(frame, deviceID: deviceID, recognize: receipt.canRecognize, at: receipt.recognitionTime,
                                    pointerOverTarget: overlay.pointerIsOverSurface, actionAvailability: overlay.gestureActionAvailability)
            }
        }
        drainRecordingFrames()
        recorder?.tick(at: time)
        overlay.tick(at: time)
    }

    private func interruptRecognition(deviceID: UInt64?, at time: TimeInterval, nativeClick: Bool = true) {
        recognitionDelivery.interrupt(deviceID: deviceID, at: time)
        for device in devices where deviceID == nil || device.id == deviceID {
            overlay.interruptRecognition(deviceID: device.id)
        }
        if nativeClick { deliveryTrace?.rightClick(deviceID: deviceID, at: time) }
        tiltTuning?.interrupt(deviceID: deviceID)
    }

    private func drainRecordingFrames() {
        guard recorder?.isRecording == true, let capture else { return }
        let recording = capture.recordedFrames()
        for (id, frame) in recording.frames { recorder?.receive(frame, deviceID: id, dropped: recording.dropped) }
    }

    @objc private func showRecorder() {
        if recorder == nil {
            let recorder = GestureRecorderController()
            recorder.setCaptureEnabled = { [weak self] enabled in
                self?.capture?.setRecording(enabled)
                if !enabled { self?.drainRecordingFrames() }
            }
            recorder.onRecordingChanged = { [weak self] recording in
                self?.overlay.isRecordingGestures = recording
                self?.tiltTuning?.setRecordingActive(recording)
            }
            recorder.onReplayStarted = { [weak self] devices in self?.overlay.beginReplay(devices: devices) }
            recorder.onReplayFrame = { [weak self] frame in self?.overlay.replay(frame) }
            recorder.onReplayTime = { [weak self] time in self?.overlay.setReplayTime(time) }
            recorder.onReplaySelectionActive = { [weak self] active in self?.overlay.setReplaySelectionActive(active) }
            recorder.onReplayEnded = { [weak self] in self?.overlay.endReplay() }
            recorder.capturePreview = { [overlay] in overlay.previewState() }
            recorder.pointerOverPreview = { [weak self] in self?.overlay.pointerIsOverSurface ?? false }
            recorder.actionAvailability = { [weak self] in self?.overlay.gestureActionAvailability }
            recorder.onNativeRightClick = { [weak self] deviceID, time in
                self?.interruptRecognition(deviceID: deviceID, at: time)
            }
            overlay.onPreviewState = { [weak recorder] state in recorder?.receivePreview(state) }
            recorder.onReplayPreview = { [weak self] state in self?.overlay.replayPreview(state) }
            self.recorder = recorder
        }
        recorder?.setDevices(devices)
        recorder?.show()
    }

    @objc private func showClassifiers() {
        showRecorder()
        recorder?.showClassifierComparison()
    }

    private func tickDemo(at time: TimeInterval) {
        let phase = (time - demoStart).truncatingRemainder(dividingBy: 16)
        for device in devices {
            let active = device.id == 1 ? (phase < 2 || (phase >= 6 && phase < 9))
                                        : ((phase >= 4 && phase < 7) || (phase >= 10 && phase < 15))
            let contacts: [Contact] = active ? (0..<2).map { index in
                Contact(id: Int32(index), stage: 4,
                        position: CGPoint(x: 0.38 + Double(index) * 0.19 + sin(time * 1.7) * 0.08,
                                          y: 0.52 + cos(time * 1.2 + Double(index)) * 0.1),
                        radiiMM: CGSize(width: 5.5, height: 3.8), angle: 1.35)
            } : []
            overlay.receive(ContactFrame(sequence: UInt64(time * 60), receivedAt: time, contacts: contacts), from: device.id)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addItem("Trackcard\(demo ? " · Demo" : "")", to: menu).isEnabled = false
        if devices.isEmpty {
            addItem(capture?.error ?? "No trackpads connected", to: menu).isEnabled = false
        }
        menu.addItem(.separator())
        let visibility = addItem(overlay.isVisible ? "Hide Preview" : "Show Preview", action: #selector(toggleVisibility), to: menu)
        visibility.keyEquivalent = "h"
        if overlay.isTucked { addItem("Bring Back Preview", action: #selector(restorePreview), to: menu) }
        for (index, device) in devices.enumerated() {
            let item = addItem("\(device.name)\(devices.count > 1 ? " · \(index + 1)" : "")", to: menu)
            let submenu = NSMenu()
            let dimensions = String(format: "%.1f × %.1f mm", device.sizeMM.width, device.sizeMM.height)
            addItem(dimensions, to: submenu).isEnabled = false
            let selected = UserDefaults.standard.string(forKey: "finish.\(device.id)") ?? TrackpadFinish.automatic.rawValue
            for finish in TrackpadFinish.allCases {
                let option = addItem(finish.title, action: #selector(changeFinish(_:)), to: submenu)
                option.representedObject = ["id": String(device.id), "finish": finish.rawValue]
                option.state = selected == finish.rawValue ? .on : .off
            }
            item.submenu = submenu
        }
        let displayItem = addItem("Display", to: menu)
        let displayMenu = NSMenu()
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let item = addItem(screen.localizedName, action: #selector(changeDisplay(_:)), to: displayMenu)
            item.representedObject = NSNumber(value: id)
            item.state = screen == overlay.screen ? .on : .off
        }
        displayItem.submenu = displayMenu
        let sizingItem = addItem("Preview Size", to: menu)
        let sizingMenu = NSMenu()
        let factor = calibration
        addItem("\(Int((factor * 100).rounded()))%", to: sizingMenu).isEnabled = false
        addItem("Smaller", action: #selector(smaller), to: sizingMenu).isEnabled = factor > OverlayController.minimumScale
        addItem("Larger", action: #selector(larger), to: sizingMenu).isEnabled = factor < OverlayController.maximumScale
        addItem("Compact (50%)", action: #selector(compactSize), to: sizingMenu)
        addItem("Match Physical Size (100%)", action: #selector(resetSize), to: sizingMenu)
        sizingItem.submenu = sizingMenu
        addItem("Reset Opacity", action: #selector(resetOpacity), to: menu)
        addItem("Record Gestures…", action: #selector(showRecorder), to: menu).isEnabled = !demo
        addItem("Compare Classifiers…", action: #selector(showClassifiers), to: menu).isEnabled = !demo
        menu.addItem(.separator())
        addItem("Quit Trackcard", action: #selector(quit), to: menu).keyEquivalent = "q"
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private var calibrationKey: String {
        let id = (overlay.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        return "calibration.\(id)"
    }

    private var calibration: Double {
        let value = UserDefaults.standard.double(forKey: calibrationKey)
        return value > 0 ? value : OverlayController.defaultScale
    }

    @objc private func toggleVisibility() { overlay.isVisible.toggle() }
    @objc private func restorePreview() { overlay.restore() }
    @objc private func resetOpacity() { overlay.resetOpacity() }
    @objc private func changeFinish(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String: String], let id = value["id"], let finish = value["finish"] else { return }
        UserDefaults.standard.set(finish, forKey: "finish.\(id)")
        overlay.configure()
    }
    @objc private func changeDisplay(_ sender: NSMenuItem) {
        overlay.screenID = (sender.representedObject as? NSNumber)?.uint32Value
        overlay.configure()
        restartFrameLoop()
    }
    @objc private func smaller() { setCalibration(calibration - 0.05) }
    @objc private func larger() { setCalibration(calibration + 0.05) }
    @objc private func compactSize() { setCalibration(OverlayController.defaultScale) }
    @objc private func resetSize() { setCalibration(1) }
    private func setCalibration(_ value: Double) {
        UserDefaults.standard.set(min(OverlayController.maximumScale, max(OverlayController.minimumScale, value)), forKey: calibrationKey)
        overlay.configure()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder, recorder.isRecording || recorder.hasPendingSaves else { return .terminateNow }
        recorder.stop()
        recorder.whenSavesFinish { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        frameLoop.stop()
        recorder?.close()
        discoveryTimer?.cancel()
        capture?.close()
        capture = nil
        overlay.close()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
