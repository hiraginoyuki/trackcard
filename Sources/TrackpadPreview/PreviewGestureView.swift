import AppKit

@MainActor
final class PreviewGestureView: NSView {
    var onMagnify: ((CGFloat, NSEvent.Phase) -> Void)?
    var onRotate: ((CGFloat, NSEvent.Phase) -> Void)?
    var containsSurface: ((CGPoint) -> Bool)?
    var onDrag: ((CGPoint, CGPoint, NSEvent.Phase) -> Void)?
    var onSwipe: ((CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Bool)?
    var makeContextMenu: ((TimeInterval) -> NSMenu)?
    var usesContactTransforms = false
    private var contactTracking = false
    private var contactTransforming = false
    private var activeGestures: Set<NSEvent.EventType> = []
    private var gestureSequence = false
    private var mouseDragging = false
    private var scrollDragging = false
    private var lastPoint = CGPoint.zero
    private var lastTime: TimeInterval = 0
    private var velocity = CGPoint.zero
    private var lastGestureEvent: TimeInterval = 0
    var isGesturing: Bool { contactTracking || gestureSequence || mouseDragging || scrollDragging || !activeGestures.isEmpty }

    func setContactTracking(_ tracking: Bool, transforming: Bool) {
        if transforming && !contactTransforming && scrollDragging {
            scrollDragging = false
            onDrag?(.zero, .zero, .cancelled)
        }
        contactTracking = tracking
        contactTransforming = transforming
        if !tracking && usesContactTransforms {
            gestureSequence = false
            activeGestures.removeAll()
        }
    }

    /// Borderless nonactivating panels must route recognized gestures before
    /// AppKit hit-tests again against a surface that the gesture itself moves.
    /// Initial events still require the exact rendered path; continuations use
    /// the gesture target until its end/cancel event, regardless of the pointer.
    func routeGesture(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let overSurface = containsSurface?(point) == true
        switch event.type {
        case .scrollWheel:
            guard contactTracking || scrollDragging || overSurface else { return false }
            scrollWheel(with: event)
        case .magnify:
            guard contactTracking || gestureSequence || activeGestures.contains(.magnify) || overSurface else { return false }
            magnify(with: event)
        case .rotate:
            guard contactTracking || gestureSequence || activeGestures.contains(.rotate) || overSurface else { return false }
            rotate(with: event)
        case .swipe:
            guard isGesturing || overSurface else { return false }
            swipe(with: event)
        case .beginGesture:
            guard overSurface else { return false }
            beginGesture(with: event)
        case .endGesture:
            guard gestureSequence || !activeGestures.isEmpty else { return false }
            endGesture(with: event)
        default:
            return false
        }
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return containsSurface?(local) == true ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func magnify(with event: NSEvent) {
        // Captured contacts are the sole transform source in the overlay. The
        // same gesture may also arrive through AppKit; absorb it exactly once.
        guard !usesContactTransforms else { return }
        lastGestureEvent = ProcessInfo.processInfo.systemUptime
        track(event)
        onMagnify?(event.magnification, event.phase)
    }

    override func rotate(with event: NSEvent) {
        guard !usesContactTransforms else { return }
        lastGestureEvent = ProcessInfo.processInfo.systemUptime
        track(event)
        onRotate?(CGFloat(event.rotation), event.phase)
    }

    private func track(_ event: NSEvent) {
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            activeGestures.remove(event.type)
        } else {
            activeGestures.insert(event.type)
        }
    }

    override func beginGesture(with event: NSEvent) {
        lastGestureEvent = ProcessInfo.processInfo.systemUptime
        gestureSequence = true
    }
    override func endGesture(with event: NSEvent) {
        gestureSequence = false
        activeGestures.removeAll()
    }

    override func mouseDown(with event: NSEvent) {
        if onClick?(convert(event.locationInWindow, from: nil)) == true { return }
        mouseDragging = true
        lastPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        lastTime = event.timestamp
        velocity = .zero
        onDrag?(.zero, .zero, .began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDragging else { return }
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        let delta = CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
        let dt = max(1 / 240, event.timestamp - lastTime)
        velocity = CGPoint(x: delta.x / dt, y: delta.y / dt)
        lastTime = event.timestamp
        lastPoint = point
        onDrag?(delta, velocity, .changed)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDragging else { return }
        mouseDragging = false
        if event.timestamp - lastTime > 0.1 { velocity = .zero }
        onDrag?(.zero, velocity, .ended)
    }

    override func scrollWheel(with event: NSEvent) {
        lastGestureEvent = ProcessInfo.processInfo.systemUptime
        guard !contactTransforming else { return }
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.mayBegin) { return }
        if !scrollDragging {
            scrollDragging = true
            velocity = .zero
            lastTime = event.timestamp
            onDrag?(.zero, .zero, .began)
        }
        // Scroll deltas use the opposite vertical axis to the layer stage.
        let delta = CGPoint(x: event.scrollingDeltaX, y: -event.scrollingDeltaY)
        if delta != .zero {
            let dt = max(1 / 120, event.timestamp - lastTime)
            velocity = CGPoint(x: delta.x / dt, y: delta.y / dt)
            lastTime = event.timestamp
            onDrag?(delta, velocity, .changed)
        }
        if event.phase.isEmpty || event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scrollDragging = false
            if event.timestamp - lastTime > 0.1 { velocity = .zero }
            onDrag?(.zero, velocity, event.phase.contains(.cancelled) ? .cancelled : .ended)
        }
    }

    override func swipe(with event: NSEvent) {
        guard !contactTransforming else { return }
        onSwipe?(CGPoint(x: event.deltaX, y: event.deltaY))
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if let menu = makeContextMenu?(event.timestamp) { return menu }
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func pressureChange(with event: NSEvent) {}

    func expireInterruptedGesture(at time: TimeInterval) {
        // A system gesture can take over without delivering endGesture. Never
        // leave a full-stage input latch behind when that sequence is lost.
        // Physical frames provide their own interruption timeout. A pause in
        // synthesized events must not cancel a pair that is still touching.
        guard !contactTracking, time - lastGestureEvent > 1,
              gestureSequence || scrollDragging || !activeGestures.isEmpty else { return }
        let wasScrolling = scrollDragging
        gestureSequence = false
        scrollDragging = false
        activeGestures.removeAll()
        onMagnify?(0, .cancelled)
        onRotate?(0, .cancelled)
        if wasScrolling { onDrag?(.zero, .zero, .cancelled) }
    }
}
