import AppKit
import QuartzCore
import TrackpadCore

private final class PreviewPanel: NSPanel {
    weak var gestureTarget: PreviewGestureView?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if gestureTarget?.routeGesture(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class OverlayController {
    static let defaultScale = 0.5
    static let minimumScale = 0.25
    static let maximumScale = 1.5
    private var panel: PreviewPanel
    private let offscreen: Bool
    private var root = CALayer()
    private var deck = CALayer()
    private var tab = CAShapeLayer()
    private var chevron = CAShapeLayer()
    private var gestureView = PreviewGestureView()
    private let adjustment: PreviewAdjustmentController
    private var cards: [UInt64: TrackpadCard] = [:]
    private var devices: [TrackpadDevice] = []
    private var liveDevices: [TrackpadDevice] = []
    private(set) var isReplaying = false
    private var replayTime: TimeInterval = 0
    private var replaySelectionActive = false
    private var replayMotionState: RecordedPreviewState?
    private var replayOriginal: (dock: PreviewDock, scale: Double)?
    var onPreviewState: ((RecordedPreviewState) -> Void)?
    private var activity = TrackpadActivity()
    private var renderedLayout: TrackpadLayout?
    private var renderedFront: UInt64?
    private var sizes: [UInt64: CGSize] = [:]
    private var unitSizes: [UInt64: CGSize] = [:]
    private var currentOpacity = 1.0
    private var opacityMotion = OpacityMotion(value: 1)
    private var provisionalTrackpad = false
    private var provisionalClone: OverlayController?
    private var cloneIsFading = false
    private var latestContacts: [UInt64: [Contact]] = [:]
    private var dirtyContacts: Set<UInt64> = []
    var onRightClick: ((UInt64?, TimeInterval) -> Void)?
    var onRecognitionDecision: ((UInt64, ContactFrame, ContactTransform.Intent, TimeInterval) -> Void)?
    var onVisualSubmission: ((TimeInterval, Double, Double, Double, Double) -> Void)?
    private var classificationTransitionUntil: TimeInterval = 0
    private var currentScale = defaultScale
    private var resizeMotion = ResizeMotion(scale: defaultScale)
    private let padding: CGFloat = 20
    private var dock = PreviewDock()
    private var surfaceBounds = CGRect.zero
    private var dragging = false
    private var restoringFromTab = false
    private var contactTransforms: [UInt64: ContactTransform] = [:]
    private var contactOwner: UInt64?
    private var lastContactFrame: TimeInterval = 0
    private var pointerMonitors: [Any] = []
    var screenID: CGDirectDisplayID? {
        didSet { if screenID != oldValue { cancelContactTransform() } }
    }
    var isTucked: Bool { dock.tucked }
    var pointerIsOverSurface: Bool {
        panel.isVisible && !dock.tucked && containsSurface(panel.convertPoint(fromScreen: NSEvent.mouseLocation))
    }
    var isRecordingGestures = false {
        willSet {
            if newValue && !isRecordingGestures {
                cancelContactTransform()
                finishResize()
                contactTransforms.removeAll()
            }
        }
        didSet { updateStatusGlow() }
    }
    var isVisible = true {
        didSet {
            if !isVisible { cancelContactTransform() }
            updateVisibility()
            updateInteraction()
        }
    }

    init(offscreen: Bool = false, adjustment: PreviewAdjustmentController? = nil) {
        self.offscreen = offscreen
        self.adjustment = adjustment ?? PreviewAdjustmentController()
        panel = PreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.title = "Trackcard"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        let opacity = UserDefaults.standard.double(forKey: "previewOpacity")
        currentOpacity = opacity > 0 ? min(1, max(0.15, opacity)) : 1
        panel.alphaValue = currentOpacity
        opacityMotion.reset(to: currentOpacity)
        gestureView.wantsLayer = true
        gestureView.layer = root
        panel.contentView = gestureView
        panel.gestureTarget = gestureView
        gestureView.allowedTouchTypes = [.indirect]
        gestureView.usesContactTransforms = true
        root.masksToBounds = true
        deck.anchorPoint = .zero
        root.addSublayer(deck)
        tab.fillColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1).cgColor
        tab.isHidden = true
        tab.addSublayer(chevron)
        chevron.strokeColor = NSColor.white.withAlphaComponent(0.7).cgColor
        chevron.fillColor = nil
        chevron.lineWidth = 2
        chevron.lineCap = .round
        chevron.lineJoin = .round
        root.addSublayer(tab)
        if let corner = UserDefaults.standard.string(forKey: "previewCorner").flatMap(PreviewCorner.init(rawValue:)) {
            dock = PreviewDock(corner: corner, tucked: UserDefaults.standard.bool(forKey: "previewTucked"))
        }
        self.adjustment.onScale = { [weak self] value in
            guard let self, !self.isRecordingGestures, !self.isReplaying else { return }
            self.currentScale = min(Self.maximumScale, max(Self.minimumScale, value))
            self.resizeMotion.retarget(to: self.currentScale)
            UserDefaults.standard.set(self.currentScale, forKey: self.calibrationKey)
            self.adjustment.update(scale: self.currentScale, opacity: self.currentOpacity, at: NSEvent.mouseLocation)
        }
        self.adjustment.onOpacity = { [weak self] value in
            guard let self, !self.isRecordingGestures, !self.isReplaying else { return }
            self.currentOpacity = min(1, max(0.15, value))
            self.panel.alphaValue = self.currentOpacity
            self.opacityMotion.reset(to: self.currentOpacity)
            UserDefaults.standard.set(self.currentOpacity, forKey: "previewOpacity")
            self.adjustment.update(scale: self.currentScale, opacity: self.currentOpacity, at: NSEvent.mouseLocation)
        }
        configureGestureView()
        if !offscreen {
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.updateInteraction() }) {
                pointerMonitors.append(monitor)
            }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.updateInteraction()
                return event
            }) { pointerMonitors.append(monitor) }
        }
    }

    private func configureGestureView() {
        gestureView.makeContextMenu = { [weak self] time in
            guard let self else { return NSMenu() }
            let owner = self.contactOwner
            self.cancelContactTransform(rejectUntilRelease: true)
            self.onRightClick?(owner, time)
            self.adjustment.hapticDeviceID = self.activity.frontID ?? self.devices.first?.id
            return self.adjustment.contextMenu(scale: self.currentScale, opacity: self.currentOpacity,
                enabled: !self.isRecordingGestures && !self.isReplaying)
        }
        gestureView.onMagnify = { [weak self] delta, phase in self?.magnify(by: delta, phase: phase) }
        gestureView.onRotate = { [weak self] degrees, phase in self?.rotate(by: degrees, phase: phase) }
        gestureView.containsSurface = { [weak self] point in self?.containsSurface(point) ?? false }
        gestureView.onDrag = { [weak self] delta, velocity, phase in self?.drag(by: delta, velocity: velocity, phase: phase) }
        gestureView.onSwipe = { [weak self] direction in self?.swipe(direction) }
        gestureView.onClick = { [weak self] point in
            guard let self, self.containsTab(point) else { return false }
            self.restore()
            return true
        }
    }

    var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screenID }
            ?? NSScreen.screens.first
    }

    func setDevices(_ devices: [TrackpadDevice]) {
        liveDevices = devices
        guard !isReplaying else { return }
        setRenderedDevices(devices)
    }

    private func setRenderedDevices(_ devices: [TrackpadDevice]) {
        guard self.devices != devices else { return }
        self.devices = devices
        let ids = Set(devices.map(\.id))
        latestContacts = latestContacts.filter { ids.contains($0.key) }
        dirtyContacts.formIntersection(ids)
        if let contactOwner, !ids.contains(contactOwner) { cancelContactTransform() }
        contactTransforms = contactTransforms.filter { ids.contains($0.key) }
        for id in Array(cards.keys) where !ids.contains(id) {
            cards.removeValue(forKey: id)?.layer.removeFromSuperlayer()
            sizes.removeValue(forKey: id)
            unitSizes.removeValue(forKey: id)
        }
        for device in devices where cards[device.id] == nil {
            let card = TrackpadCard(device: device)
            cards[device.id] = card
            deck.addSublayer(card.layer)
        }
        activity.setDevices(devices.map(\.id))
        renderedLayout = nil
        configure()
        if !offscreen {
            if provisionalClone == nil {
                let clone = OverlayController(offscreen: true)
                clone.panel.title = "Provisional Trackcard"
                provisionalClone = clone
            }
            provisionalClone?.setDevices(devices)
        }
    }

    func configure(scale: Double? = nil) {
        guard let screen else { return }
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let mm = CGDisplayScreenSize(id)
        let pointsPerMM = PhysicalGeometry.pointsPerMillimeter(screenPoints: screen.frame.size, screenMM: mm)
        let calibration = UserDefaults.standard.double(forKey: "calibration.\(id)")
        let factor = scale ?? (calibration > 0 ? calibration : Self.defaultScale)
        currentScale = factor
        resizeMotion.reset(to: factor, at: ProcessInfo.processInfo.systemUptime)
        // AppKit can flush the layer tree while updating a window. Do this
        // before changing card geometry, and never force a redraw per pinch.
        if panel.frame != screen.visibleFrame { panel.setFrame(screen.visibleFrame, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: panel.frame.size)
        for device in devices {
            let unitSize = PhysicalGeometry.surfaceSize(millimeters: device.sizeMM, pointsPerMM: pointsPerMM)
            unitSizes[device.id] = unitSize
            let size = CGSize(width: unitSize.width * factor, height: unitSize.height * factor)
            sizes[device.id] = size
            let finish = TrackpadFinish(rawValue: UserDefaults.standard.string(forKey: "finish.\(device.id)") ?? "") ?? .automatic
            cards[device.id]?.configure(size: size, finish: finish)
        }
        // Surface bounds, contact geometry, card centers and deck anchoring
        // must reach the compositor together, including both trackpads.
        positionCards(animated: false)
        CATransaction.commit()
        updateVisibility()
        updateInteraction()
    }

    private var calibrationKey: String {
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        return "calibration.\(id)"
    }

    private func magnify(by delta: CGFloat, phase: NSEvent.Phase) {
        guard !isRecordingGestures, !isReplaying, delta.isFinite else { return }
        if phase.contains(.began), !offscreen {
            adjustment.begin(.scale, scale: currentScale, opacity: currentOpacity, at: NSEvent.mouseLocation)
        }
        if delta != 0 {
            currentScale = min(Self.maximumScale, max(Self.minimumScale, currentScale * (1 + Double(delta))))
            resizeMotion.retarget(to: currentScale)
        }
        if phase.isEmpty || phase.contains(.ended) || phase.contains(.cancelled) {
            UserDefaults.standard.set(currentScale, forKey: calibrationKey)
            adjustment.end()
        } else { adjustment.update(scale: currentScale, opacity: currentOpacity, at: NSEvent.mouseLocation) }
    }

    private func rotate(by degrees: CGFloat, phase: NSEvent.Phase) {
        guard !isRecordingGestures, !isReplaying, degrees.isFinite else { return }
        if phase.contains(.began), !offscreen {
            adjustment.begin(.opacity, scale: currentScale, opacity: currentOpacity, at: NSEvent.mouseLocation)
        }
        currentOpacity = min(1, max(0.15, currentOpacity - degrees / 90))
        opacityMotion.retarget(to: currentOpacity)
        if phase.isEmpty || phase.contains(.ended) || phase.contains(.cancelled) {
            UserDefaults.standard.set(currentOpacity, forKey: "previewOpacity")
            adjustment.end()
        } else { adjustment.update(scale: currentScale, opacity: currentOpacity, at: NSEvent.mouseLocation) }
    }

    private func renderResize(at time: TimeInterval) {
        let old = resizeMotion.scale
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        resizeMotion.advance(at: time, reduceMotion: reduceMotion, settlingTime: time < classificationTransitionUntil ? 0.2 : 0.05)
        guard resizeMotion.scale != old else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyResizeScale(resizeMotion.scale)
        CATransaction.commit()
    }

    private func applyResizeScale(_ scale: Double) {
        for device in devices {
            guard let unitSize = unitSizes[device.id] else { continue }
            let size = CGSize(width: unitSize.width * scale, height: unitSize.height * scale)
            sizes[device.id] = size
            cards[device.id]?.resize(to: size)
        }
        positionCards(animated: false)
    }

    private func finishResize() {
        // A new drag must start from a settled size. Otherwise a
        // pending resize frame could re-anchor the deck after dragging begins.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if resizeMotion.scale != currentScale { applyResizeScale(currentScale) }
        resizeMotion.reset(to: currentScale, at: ProcessInfo.processInfo.systemUptime)
        CATransaction.commit()
    }

    private func updateInteraction() {
        let point = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let interactive = !offscreen && isVisible && (gestureView.isGesturing || containsSurface(point))
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    private func containsTab(_ point: CGPoint) -> Bool {
        guard !tab.isHidden else { return false }
        guard (tab.presentation()?.opacity ?? tab.opacity) > 0.01 else { return false }
        guard let path = tab.path else { return false }
        var sample = point
        let bounds = path.boundingBox
        let halfPixel = 0.5 / (screen?.backingScaleFactor ?? 1)
        // CGPath excludes its boundary. A flush screen-edge handle must accept
        // the outermost cursor position while retaining its rounded cutouts.
        if dock.corner.isLeft && point.x == bounds.minX { sample.x += halfPixel }
        if !dock.corner.isLeft && point.x >= bounds.maxX - halfPixel && point.x <= bounds.maxX {
            sample.x = bounds.maxX - halfPixel
        }
        return path.contains(sample)
    }

    private func containsSurface(_ point: CGPoint) -> Bool {
        if containsTab(point) { return true }
        guard root.bounds.contains(point) else { return false }
        return cards.values.contains { card in
            let layer = card.layer.presentation() ?? card.layer
            let stage = root.presentation() ?? root
            let local = layer.convert(point, from: stage)
            return layer.shadowPath?.contains(local) ?? layer.bounds.contains(local)
        }
    }

    var gestureActionAvailability: GestureActionAvailability? {
        GestureActionAvailability(scale: currentScale, opacity: Double(currentOpacity),
            minimumScale: Self.minimumScale, maximumScale: Self.maximumScale, minimumOpacity: 0.15)
    }

    func receive(_ frame: ContactFrame, from deviceID: UInt64, recognize: Bool = true, at recognitionTime: TimeInterval? = nil) {
        guard !isReplaying else { return }
        latestContacts[deviceID] = frame.contacts
        dirtyContacts.insert(deviceID)
        if contactOwner == nil || contactOwner == deviceID {
            adjustment.hapticDeviceID = deviceID
            adjustment.hapticContactTime = frame.contacts.contains(where: \.isTouching) ? frame.receivedAt : -.infinity
        }
        activity.receive(deviceID: deviceID, hasContact: frame.contacts.contains(where: \.isTouching), at: frame.receivedAt)
        guard recognize, !isRecordingGestures, !offscreen, isVisible,
              let device = devices.first(where: { $0.id == deviceID }) else { return }
        let point = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let canBegin = contactOwner == nil && !dock.tucked && !restoringFromTab && containsSurface(point)
        let contacts = frame.contacts.filter(\.isTouching).map {
            TransformContact(id: $0.id, positionMM: CGPoint(x: $0.position.x * device.sizeMM.width,
                                                          y: $0.position.y * device.sizeMM.height), orientation: Double($0.angle), radiiMM: $0.radiiMM, force: Double($0.force))
        }
        let configuration = ContactTransform.Configuration(tiltThresholds: ClassifierTuningStore.shared.thresholds(for: deviceID))
        if contactTransforms[deviceID]?.configuration != configuration, contactOwner == deviceID {
            cancelContactTransform(rejectUntilRelease: true)
        }
        var transform = contactTransforms[deviceID] ?? ContactTransform(configuration: configuration)
        _ = transform.reconfigure(configuration)
        let previousIntent = transform.intent
        let update = transform.receive(contacts, canBegin: canBegin, at: recognitionTime ?? frame.receivedAt,
                                       sourceTimestamp: frame.sourceTimestamp, pointerOverTarget: containsSurface(point),
                                       actionAvailability: gestureActionAvailability)
        contactTransforms[deviceID] = transform
        if previousIntent == .undecided && transform.intent != .undecided {
            onRecognitionDecision?(deviceID, frame, transform.intent, transform.elapsed)
        }
        if contactOwner == nil && transform.isTracking { contactOwner = deviceID }
        guard contactOwner == deviceID else { return }
        adjustment.hapticDeviceID = deviceID
        lastContactFrame = frame.receivedAt
        gestureView.setContactTracking(transform.isTracking, transforming: transform.isActive)
        if let update {
            if update.phase == .began {
                if update.kind == .magnify { promoteProvisionalClone() }
                else { endProvisionalTrackpad(animated: true) }
            }
            applyContactTransform(update)
        }
        if !offscreen, transform.intent == .undecided && transform.isTracking {
            if transform.isPressCandidate { suppressProvisionalForPress(at: frame.receivedAt) }
            else { showProvisionalAdjustment(transform, at: frame.receivedAt) }
        } else if adjustment.isProvisional || provisionalTrackpad {
            endProvisionalTrackpad(animated: true)
            if transform.intent == .movement { adjustment.resolveMovement() }
            else { adjustment.end() }
        }
        if !transform.isTracking { contactOwner = nil }
        updateInteraction()
    }

    private func showProvisionalAdjustment(_ transform: ContactTransform, at time: TimeInterval) {
        let scale = min(Self.maximumScale, max(Self.minimumScale, currentScale * transform.assessment.scaleRatio))
        if !provisionalTrackpad {
            provisionalTrackpad = true
            cloneIsFading = false
            if provisionalClone == nil {
                let clone = OverlayController(offscreen: true)
                clone.panel.title = "Provisional Trackcard"
                provisionalClone = clone
            }
            if let clone = provisionalClone {
                clone.screenID = screenID
                clone.dock = dock; clone.activity = activity
                clone.setDevices(devices)
                clone.configure(scale: resizeMotion.scale)
                for (id, contacts) in latestContacts { clone.cards[id]?.update(contacts: contacts) }
                clone.panel.ignoresMouseEvents = true
                if !clone.panel.isVisible { clone.opacityMotion.reset(to: 0, at: time) }
                clone.panel.alphaValue = min(currentOpacity, clone.opacityMotion.value)
                clone.panel.order(.above, relativeTo: panel.windowNumber)
            }
        }
        provisionalClone?.resizeMotion.retarget(to: scale)
        // Tilt evidence progressively removes the uncommitted scale ghost.
        provisionalClone?.opacityMotion.retarget(to: min(0.5, currentOpacity) * (1 - transform.assessment.scores.rotation))
        adjustment.preview(scale: scale, opacity: currentOpacity,
                           confidence: transform.assessment.confidence, at: NSEvent.mouseLocation, time: time)
    }

    private func suppressProvisionalForPress(at time: TimeInterval) {
        adjustment.end()
        // Keep the clone's geometry ready for a later transform, while removing
        // its feedback immediately. Only an actual click latches the veto.
        provisionalClone?.opacityMotion.reset(to: 0, at: time)
        provisionalClone?.panel.alphaValue = 0
    }

    private func promoteProvisionalClone() {
        guard provisionalTrackpad, let clone = provisionalClone else { return }
        provisionalTrackpad = false; cloneIsFading = false
        // Adopt the exact window/layers already visible under the fingers.
        // Retire the previous original as the reusable clone for the next pair.
        swap(&panel, &clone.panel)
        swap(&root, &clone.root); swap(&deck, &clone.deck)
        swap(&tab, &clone.tab); swap(&chevron, &clone.chevron)
        swap(&gestureView, &clone.gestureView)
        swap(&cards, &clone.cards); swap(&sizes, &clone.sizes); swap(&unitSizes, &clone.unitSizes)
        swap(&renderedLayout, &clone.renderedLayout); swap(&renderedFront, &clone.renderedFront)
        swap(&surfaceBounds, &clone.surfaceBounds); swap(&resizeMotion, &clone.resizeMotion)
        opacityMotion = clone.opacityMotion
        opacityMotion.retarget(to: currentOpacity)
        classificationTransitionUntil = 0
        panel.title = "Trackcard"; panel.gestureTarget = gestureView
        clone.panel.title = "Provisional Trackcard"; clone.panel.gestureTarget = clone.gestureView
        clone.panel.orderOut(nil)
        configureGestureView(); clone.configureGestureView()
        clone.gestureView.setContactTracking(false, transforming: false)
        gestureView.setContactTracking(true, transforming: true)
        updateInteraction()
    }

    private func endProvisionalTrackpad(animated: Bool) {
        guard provisionalTrackpad else { return }
        provisionalTrackpad = false
        guard let clone = provisionalClone else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            cloneIsFading = true
            clone.opacityMotion.retarget(to: 0)
        } else {
            cloneIsFading = false
            clone.panel.orderOut(nil)
            clone.opacityMotion.reset(to: 0)
        }
    }

    private func applyContactTransform(_ update: ContactTransformUpdate) {
        let phase: NSEvent.Phase = switch update.phase {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        }
        switch update.kind {
        case .magnify: magnify(by: update.magnification, phase: phase)
        case .rotate: rotate(by: update.rotation * 180 / .pi, phase: phase)
        }
    }

    private func cancelContactTransform(rejectUntilRelease: Bool = false) {
        adjustment.end()
        endProvisionalTrackpad(animated: false)
        cloneIsFading = false
        provisionalClone?.panel.orderOut(nil)
        if let contactOwner, var transform = contactTransforms.removeValue(forKey: contactOwner) {
            let update = rejectUntilRelease ? transform.interrupt() : transform.receive([], canBegin: false)
            if let update { applyContactTransform(update) }
            if rejectUntilRelease { contactTransforms[contactOwner] = transform }
        }
        contactOwner = nil
        opacityMotion.reset(to: currentOpacity)
        panel.alphaValue = currentOpacity
        gestureView.setContactTracking(false, transforming: false)
    }

    func interruptRecognition(deviceID: UInt64) {
        if contactOwner == deviceID { cancelContactTransform(rejectUntilRelease: true) }
        else if var transform = contactTransforms[deviceID] {
            _ = transform.interrupt()
            contactTransforms[deviceID] = transform
        }
    }

    func tick(at time: TimeInterval) {
        if !isReplaying {
            for id in dirtyContacts {
                let contacts = latestContacts[id] ?? []
                cards[id]?.update(contacts: contacts)
                provisionalClone?.cards[id]?.update(contacts: contacts)
            }
        }
        dirtyContacts.removeAll(keepingCapacity: true)
        if contactOwner != nil && time - lastContactFrame > 0.25 { cancelContactTransform(rejectUntilRelease: true) }
        if adjustment.isProvisional, let contactOwner, let transform = contactTransforms[contactOwner] {
            if transform.isPressCandidate { suppressProvisionalForPress(at: time) }
            else { showProvisionalAdjustment(transform, at: time) }
        }
        if adjustment.activeKind != nil { adjustment.update(scale: currentScale, opacity: currentOpacity, at: NSEvent.mouseLocation) }
        gestureView.expireInterruptedGesture(at: time)
        renderResize(at: time)
        if (provisionalTrackpad || cloneIsFading), let clone = provisionalClone {
            if provisionalTrackpad { clone.renderResize(at: time) }
            clone.opacityMotion.advance(at: time, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, maximum: min(0.5, currentOpacity))
            clone.panel.alphaValue = clone.opacityMotion.value
            if cloneIsFading && clone.opacityMotion.value < 0.002 {
                cloneIsFading = false; clone.panel.orderOut(nil); clone.opacityMotion.reset(to: 0)
            }
        }
        opacityMotion.advance(at: time, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        panel.alphaValue = opacityMotion.value
        activity.evaluate(at: isReplaying ? replayTime : time)
        if !gestureView.isGesturing && !dragging && (renderedLayout != activity.layout || renderedFront != activity.frontID) { positionCards(animated: true) }
        if let state = replayMotionState { applyReplayPreview(state) }
        updateInteraction()
        if isRecordingGestures || isReplaying { updateStatusGlow() }
        // Commit contacts even while AppKit is servicing a nested gesture mode.
        CATransaction.flush()
        onVisualSubmission?(time, currentScale, resizeMotion.scale, currentOpacity, panel.alphaValue)
        if isRecordingGestures { onPreviewState?(previewState(at: time)) }
    }

    private func positionCards(animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animate = animated && renderedLayout != nil && !reduceMotion
        let swap = animate && renderedLayout == .stacked && activity.layout == .stacked && renderedFront != activity.frontID
        var nextX = padding
        var bounds = CGRect.null
        for device in devices {
            guard let card = cards[device.id], let size = sizes[device.id] else { continue }
            let front = device.id == activity.frontID
            let origin: CGPoint
            if devices.count == 1 {
                origin = CGPoint(x: padding, y: padding)
            } else if activity.layout == .sideBySide {
                origin = CGPoint(x: nextX, y: padding)
                nextX += size.width + 16
            } else {
                origin = CGPoint(x: padding + (front ? 18 : 0), y: padding + (front ? 14 : 0))
            }
            let target = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            bounds = bounds.union(CGRect(origin: origin, size: size))
            let oldPosition = card.layer.presentation()?.position ?? card.layer.position
            let oldZ = card.layer.presentation()?.zPosition ?? card.layer.zPosition
            let oldRotation = (card.layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0
            let newZ: CGFloat = front ? 2 : 1
            card.layer.removeAnimation(forKey: "position")
            card.layer.removeAnimation(forKey: "zPosition")
            card.layer.removeAnimation(forKey: "rotation")
            card.layer.removeAnimation(forKey: "cardSwap")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.layer.position = target
            card.layer.zPosition = newZ
            CATransaction.commit()
            guard animate else { continue }
            if swap {
                let position = CAKeyframeAnimation(keyPath: "position")
                let path = CGMutablePath()
                path.move(to: oldPosition)
                let control = CGPoint(x: target.x + (front ? size.width * 0.32 : -size.width * 0.24),
                                      y: target.y + (front ? 24 : -12))
                path.addQuadCurve(to: target, control: control)
                position.path = path
                position.calculationMode = .paced
                position.duration = 0.3
                let z = CAKeyframeAnimation(keyPath: "zPosition")
                z.values = [oldZ, newZ, newZ]
                z.keyTimes = [0, 0.5, 1]
                z.calculationMode = .discrete
                z.duration = 0.3
                let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                rotation.values = [oldRotation, front ? 0.025 : -0.035, 0]
                rotation.keyTimes = [0, 0.5, 1]
                rotation.duration = 0.3
                let group = CAAnimationGroup()
                group.animations = [position, z, rotation]
                group.duration = 0.3
                group.timingFunction = PreviewAnimation.timingFunction
                card.layer.add(group, forKey: "cardSwap")
            } else {
                let position = CABasicAnimation(keyPath: "position")
                position.fromValue = NSValue(point: oldPosition)
                position.toValue = NSValue(point: target)
                position.duration = 0.26
                position.timingFunction = PreviewAnimation.timingFunction
                card.layer.add(position, forKey: "position")
            }
        }
        renderedLayout = activity.layout
        renderedFront = activity.frontID
        surfaceBounds = bounds.isNull ? .zero : bounds
        if !dragging && !(isReplaying && replayMotionState != nil) { positionDeck(animated: animate) }
        if isRecordingGestures || isReplaying { updateStatusGlow() }
    }

    /// One shadow on the filled union of card silhouettes. Overlapping paths
    /// fill as one shape, so buried card edges never gain their own glow.
    private func updateStatusGlow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard isRecordingGestures || isReplaying else {
            deck.shadowOpacity = 0
            deck.shadowPath = nil
            CATransaction.commit()
            return
        }
        let outline = CGMutablePath()
        let shownDeck = deck.presentation() ?? deck
        for card in cards.values {
            let shown = card.layer.presentation() ?? card.layer
            guard let path = card.layer.shadowPath else { continue }
            let origin = shown.convert(CGPoint.zero, to: shownDeck)
            let x = shown.convert(CGPoint(x: 1, y: 0), to: shownDeck)
            let y = shown.convert(CGPoint(x: 0, y: 1), to: shownDeck)
            var transform = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
            if let transformed = path.copy(using: &transform) { outline.addPath(transformed) }
        }
        deck.shadowColor = (isRecordingGestures ? NSColor.systemRed : NSColor.systemBlue).cgColor
        deck.shadowOpacity = isRecordingGestures ? 0.85 : (replaySelectionActive ? 1 : 0.55)
        deck.shadowRadius = isRecordingGestures ? 10 : (replaySelectionActive ? 18 : 9)
        deck.shadowOffset = .zero
        deck.shadowPath = outline
        CATransaction.commit()
    }

    func beginReplay(devices recorded: [RecordedDevice]) {
        if replayOriginal == nil { replayOriginal = (dock, currentScale) }
        cancelContactTransform()
        finishResize()
        isReplaying = true
        replaySelectionActive = false
        replayMotionState = nil
        replayTime = 0
        setRenderedDevices(recorded.prefix(2).map { device in
            let live = liveDevices.first { $0.id == device.id }
            return TrackpadDevice(id: device.id, name: device.name, sizeMM: device.sizeMM,
                                  builtIn: live?.builtIn ?? false, color: live?.color)
        })
        resetContacts()
        isVisible = true
        dock.tucked = false
        positionDeck(animated: false)
        updateInteraction()
        updateStatusGlow()
    }

    func replay(_ frame: RecordedContactFrame) {
        guard isReplaying else { return }
        cards[frame.deviceID]?.update(contacts: frame.contacts.map { Contact(recorded: $0) })
        activity.receive(deviceID: frame.deviceID, hasContact: frame.contacts.contains { $0.stage == 3 || $0.stage == 4 }, at: frame.time)
    }

    func setReplayTime(_ time: TimeInterval) { replayTime = time }

    func setReplaySelectionActive(_ active: Bool) {
        let active = isReplaying && active
        guard replaySelectionActive != active else { return }
        replaySelectionActive = active
        updateStatusGlow()
    }

    func previewState(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> RecordedPreviewState {
        let position = deck.presentation()?.position ?? deck.position
        let opacity = tab.isHidden ? 0 : Double(tab.presentation()?.opacity ?? tab.opacity)
        return RecordedPreviewState(time: time,
            center: CGPoint(x: (position.x + surfaceBounds.midX) / max(1, root.bounds.width),
                            y: (position.y + surfaceBounds.midY) / max(1, root.bounds.height)),
            scale: resizeMotion.scale, corner: dock.corner, tucked: dock.tucked, tabOpacity: opacity)
    }

    func replayPreview(_ state: RecordedPreviewState) {
        guard isReplaying else { return }
        replayMotionState = state
        applyReplayPreview(state)
    }

    private func applyReplayPreview(_ state: RecordedPreviewState) {
        let scale = min(Self.maximumScale, max(Self.minimumScale, state.scale))
        if abs(currentScale - scale) > 0.000001 { configure(scale: scale) }
        dock = PreviewDock(corner: state.corner, tucked: state.tucked)
        deck.removeAnimation(forKey: "dock")
        tab.removeAnimation(forKey: "restoreFade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        deck.position = CGPoint(x: state.center.x * root.bounds.width - surfaceBounds.midX,
                                y: state.center.y * root.bounds.height - surfaceBounds.midY)
        tab.path = dock.tabPath(in: root.bounds.size, bounds: surfaceBounds)
        tab.opacity = Float(min(1, max(0, state.tabOpacity)))
        tab.isHidden = tab.opacity <= 0
        chevron.path = chevronPath(in: dock.tab(in: root.bounds.size, bounds: surfaceBounds))
        CATransaction.commit()
    }

    func endReplay() {
        guard isReplaying else { return }
        let original = replayOriginal
        isReplaying = false
        replaySelectionActive = false
        replayMotionState = nil
        replayOriginal = nil
        if let original { dock = original.dock }
        resetContacts()
        setRenderedDevices(liveDevices)
        if let original { configure(scale: original.scale) }
        updateStatusGlow()
    }

    private func positionDeck(animated: Bool, velocity: CGPoint = .zero) {
        let target = dock.origin(for: surfaceBounds, in: root.bounds.size)
        let old = deck.presentation()?.position ?? deck.position
        deck.removeAnimation(forKey: "dock")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        deck.position = target
        let tabFrame = dock.tab(in: root.bounds.size, bounds: surfaceBounds)
        tab.path = dock.tabPath(in: root.bounds.size, bounds: surfaceBounds)
        tab.removeAnimation(forKey: "restoreFade")
        if dock.tucked {
            tab.isHidden = false
            tab.opacity = 1
        } else if animated && !tab.isHidden && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Keep a visible handle until the card has started sliding back in.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = tab.presentation()?.opacity ?? tab.opacity
            fade.toValue = 0
            fade.duration = 0.2
            tab.opacity = 0
            tab.add(fade, forKey: "restoreFade")
        } else {
            tab.isHidden = true
            tab.opacity = 0
        }
        chevron.path = chevronPath(in: tabFrame)
        CATransaction.commit()
        guard animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let move = CASpringAnimation(keyPath: "position")
        move.fromValue = NSValue(point: old)
        move.toValue = NSValue(point: target)
        move.mass = 1
        // Approximate the acceleration and long settling tail observed in
        // iPadOS PiP. These are app tuning values, not private Apple constants.
        move.stiffness = 180
        move.damping = 24
        let displacement = CGPoint(x: target.x - old.x, y: target.y - old.y)
        let distance = hypot(displacement.x, displacement.y)
        move.initialVelocity = distance > 1 ? max(-4, min(8, (velocity.x * displacement.x + velocity.y * displacement.y) / (distance * distance))) : 0
        move.duration = move.settlingDuration
        deck.add(move, forKey: "dock")
    }

    private func drag(by delta: CGPoint, velocity: CGPoint, phase: NSEvent.Phase) {
        guard !isReplaying else { return }
        if phase.contains(.began) { finishResize() }
        if phase.contains(.began), dock.tucked {
            restoringFromTab = true
            return
        }
        if restoringFromTab {
            if phase.contains(.changed), dock.tucked,
               delta.x * (dock.corner.isLeft ? 1 : -1) > 0 {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                restore()
            }
            if phase.contains(.ended) || phase.contains(.cancelled) { restoringFromTab = false }
            return
        }
        if phase.contains(.began) {
            let position = deck.presentation()?.position ?? deck.position
            deck.removeAnimation(forKey: "dock")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            deck.position = position
            tab.isHidden = true
            CATransaction.commit()
            dragging = true
        }
        if phase.contains(.changed) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            deck.position = CGPoint(x: deck.position.x + delta.x, y: deck.position.y + delta.y)
            CATransaction.commit()
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            dragging = false
            if !phase.contains(.cancelled) {
                dock = PreviewDock.released(bounds: surfaceBounds, origin: deck.position, velocity: velocity,
                                            screen: root.bounds.size, startingCorner: dock.corner)
                saveDock()
            }
            positionDeck(animated: true, velocity: velocity)
        }
    }

    private func swipe(_ direction: CGPoint) {
        guard !isReplaying else { return }
        if dock.tucked {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            restore()
            return
        }
        let left = abs(direction.x) > abs(direction.y) ? direction.x > 0 : dock.corner.isLeft
        let top = abs(direction.y) > abs(direction.x) ? direction.y < 0 : dock.corner.isTop
        let towardCurrentEdge = abs(direction.x) > abs(direction.y) && left == dock.corner.isLeft
        dock = PreviewDock(corner: top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight), tucked: towardCurrentEdge)
        saveDock()
        positionDeck(animated: true)
    }

    func restore() {
        guard !isReplaying else { return }
        dock.tucked = false
        saveDock()
        positionDeck(animated: true)
        updateInteraction()
    }

    func resetOpacity() {
        currentOpacity = 1
        opacityMotion.reset(to: 1)
        panel.alphaValue = 1
        UserDefaults.standard.set(1, forKey: "previewOpacity")
    }

    private func saveDock() {
        UserDefaults.standard.set(dock.corner.rawValue, forKey: "previewCorner")
        UserDefaults.standard.set(dock.tucked, forKey: "previewTucked")
    }

    private func chevronPath(in frame: CGRect) -> CGPath {
        let arrow = CGMutablePath()
        let direction: CGFloat = dock.corner.isLeft ? 1 : -1
        arrow.move(to: CGPoint(x: frame.midX - direction * 3, y: frame.midY - 6))
        arrow.addLine(to: CGPoint(x: frame.midX + direction * 3, y: frame.midY))
        arrow.addLine(to: CGPoint(x: frame.midX - direction * 3, y: frame.midY + 6))
        return arrow
    }

    private func updateVisibility() {
        if !offscreen && isVisible && !devices.isEmpty {
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        else { panel.orderOut(nil) }
    }

    func resetContacts() {
        cancelContactTransform()
        finishResize()
        contactTransforms.removeAll()
        latestContacts.removeAll()
        dirtyContacts.removeAll()
        activity = TrackpadActivity()
        activity.setDevices(devices.map(\.id))
        for card in cards.values { card.resetContacts() }
        positionCards(animated: false)
    }

    // Render only our own layers; this does not capture the desktop or require
    // Screen Recording access. The caller runs a bounded synthetic demo.
    func writeSnapshot(to url: URL) throws {
        let scale = screen?.backingScaleFactor ?? 2
        let stageBounds = surfaceBounds.offsetBy(dx: deck.position.x, dy: deck.position.y)
        let visible = stageBounds.intersection(root.bounds)
        let content = dock.tucked ? dock.tab(in: root.bounds.size, bounds: surfaceBounds) : visible
        let captureBounds = content.insetBy(dx: -20, dy: -20).intersection(root.bounds)
        let size = captureBounds.size
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                  pixelsWide: Int(ceil(size.width * scale)),
                  pixelsHigh: Int(ceil(size.height * scale)),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "Trackcard.Snapshot", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display or bitmap context is available."])
        }
        CATransaction.flush()
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -captureBounds.minX, y: -captureBounds.minY)
        context.setAlpha(panel.alphaValue)
        // CALayer's bitmap renderer ignores zPosition. Flatten in the same
        // back-to-front order as the onscreen compositor for a settled layout.
        let original = root.sublayers
        let originalCards = deck.sublayers
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers = original?.sorted { $0.zPosition < $1.zPosition }
        deck.sublayers = originalCards?.sorted { $0.zPosition < $1.zPosition }
        root.render(in: context)
        root.sublayers = original
        deck.sublayers = originalCards
        CATransaction.commit()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Trackcard.Snapshot", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode the overlay as PNG."])
        }
        try png.write(to: url, options: .atomic)
        print("Snapshot: \(url.path) · \(activity.layout) · \(devices.count) trackpads")
    }

    func close() {
        cancelContactTransform()
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerMonitors.removeAll()
        adjustment.close()
        cloneIsFading = false
        provisionalClone?.close(); provisionalClone = nil
        panel.close()
    }
}
