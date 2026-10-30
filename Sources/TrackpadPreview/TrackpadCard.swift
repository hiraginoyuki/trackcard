import AppKit
import QuartzCore

enum TrackpadFinish: String, CaseIterable {
    case automatic, white, silver, spaceGray, black

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .white: "White"
        case .silver: "Silver"
        case .spaceGray: "Space Gray"
        case .black: "Black"
        }
    }

    func color(for device: TrackpadDevice) -> NSColor {
        switch self {
        case .automatic:
            if let color = device.color {
                return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
            }
            return device.builtIn ? TrackpadFinish.black.color(for: device) : TrackpadFinish.white.color(for: device)
        case .white: return NSColor(srgbRed: 0.94, green: 0.94, blue: 0.925, alpha: 1)
        case .silver: return NSColor(srgbRed: 0.72, green: 0.73, blue: 0.74, alpha: 1)
        case .spaceGray: return NSColor(srgbRed: 0.32, green: 0.33, blue: 0.35, alpha: 1)
        case .black: return NSColor(srgbRed: 0.12, green: 0.125, blue: 0.135, alpha: 1)
        }
    }
}

@MainActor
final class TrackpadCard {
    let layer = CALayer()
    private let surface = CAGradientLayer()
    private let contactsLayer = CALayer()
    private var contactLayers: [Int32: CAShapeLayer] = [:]
    private var fadingContacts: [ObjectIdentifier: (layer: CAShapeLayer, contact: Contact)] = [:]
    private var accent = NSColor.systemCyan
    private var device: TrackpadDevice
    private var latestContacts: [Contact] = []

    init(device: TrackpadDevice) {
        self.device = device
        layer.name = device.name
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.26
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -5)
        surface.cornerRadius = 13
        surface.cornerCurve = .circular
        surface.borderWidth = 0.75
        layer.addSublayer(surface)
        contactsLayer.masksToBounds = true
        contactsLayer.cornerRadius = 13
        layer.addSublayer(contactsLayer)
    }

    func configure(size: CGSize, finish: TrackpadFinish) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let base = finish.color(for: device).usingColorSpace(.sRGB)!
        let brightness = (base.redComponent + base.greenComponent + base.blueComponent) / 3
        let dark = brightness < 0.5
        // Adding white through NSColor blending lifts near-black surfaces too
        // far. Keep the highlight in sRGB so black still looks like black.
        let lift: CGFloat = brightness < 0.2 ? 0.006 : 0.025
        surface.colors = [NSColor(srgbRed: min(1, base.redComponent + lift),
                                 green: min(1, base.greenComponent + lift),
                                 blue: min(1, base.blueComponent + lift), alpha: 1).cgColor,
                          NSColor(srgbRed: base.redComponent * 0.975,
                                  green: base.greenComponent * 0.975,
                                  blue: base.blueComponent * 0.975, alpha: 1).cgColor]
        surface.startPoint = CGPoint(x: 0.5, y: 1)
        surface.endPoint = CGPoint(x: 0.5, y: 0)
        surface.borderColor = NSColor.white.withAlphaComponent(brightness < 0.2 ? 0.075 : (dark ? 0.18 : 0.65)).cgColor
        accent = dark ? NSColor(srgbRed: 0.47, green: 0.91, blue: 0.85, alpha: 1)
                      : NSColor(srgbRed: 0.08, green: 0.42, blue: 0.49, alpha: 1)
        resize(to: size)
        CATransaction.commit()
    }

    func resize(to size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(origin: .zero, size: size)
        surface.frame = layer.bounds
        contactsLayer.frame = layer.bounds
        let radius = min(14, size.height * 0.055)
        surface.cornerRadius = radius
        contactsLayer.cornerRadius = radius
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        update(contacts: latestContacts)
        for fading in fadingContacts.values { setGeometry(of: fading.layer, for: fading.contact) }
        CATransaction.commit()
    }

    func update(contacts: [Contact]) {
        let previousContacts = latestContacts
        latestContacts = contacts
        let visible = contacts.filter(\.isVisible)
        let ids = Set(visible.map(\.id))
        for id in Array(contactLayers.keys) where !ids.contains(id) {
            guard let departing = contactLayers.removeValue(forKey: id) else { continue }
            let lifetime = ObjectIdentifier(departing)
            if let contact = previousContacts.first(where: { $0.id == id }) {
                fadingContacts[lifetime] = (departing, contact)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let releaseOpacity = min(0.75, departing.presentation()?.opacity ?? departing.opacity)
            departing.fillColor = desaturated(departing.fillColor)
            departing.strokeColor = desaturated(departing.strokeColor)
            departing.shadowOpacity = 0
            if let dot = departing.sublayers?.first as? CAShapeLayer { dot.fillColor = desaturated(dot.fillColor) }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = releaseOpacity
            fade.toValue = 0
            fade.duration = 0.12
            departing.opacity = 0
            CATransaction.commit()
            departing.add(fade, forKey: "departure")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
                self?.fadingContacts.removeValue(forKey: lifetime)
                departing.removeFromSuperlayer()
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for contact in visible {
            let shape: CAShapeLayer
            if let existing = contactLayers[contact.id] {
                shape = existing
            } else {
                shape = CAShapeLayer()
                shape.lineWidth = 1
                let center = CAShapeLayer()
                center.path = CGPath(ellipseIn: CGRect(x: -1.8, y: -1.8, width: 3.6, height: 3.6), transform: nil)
                shape.addSublayer(center)
                contactsLayer.addSublayer(shape)
                contactLayers[contact.id] = shape
            }
            setGeometry(of: shape, for: contact)
            shape.fillColor = accent.withAlphaComponent(contact.isTouching ? 0.22 : 0.025).cgColor
            shape.strokeColor = accent.withAlphaComponent(contact.isTouching ? 0.85 : 0.25).cgColor
            shape.shadowColor = accent.cgColor
            shape.shadowRadius = 5
            shape.shadowOpacity = contact.isTouching ? 0.2 : 0
            shape.shadowOffset = .zero
            if let dot = shape.sublayers?.first as? CAShapeLayer {
                dot.fillColor = accent.withAlphaComponent(contact.isTouching ? 1 : 0.2).cgColor
                dot.position = .zero
            }
        }
        CATransaction.commit()
    }

    func resetContacts() {
        latestContacts = []
        contactLayers.removeAll()
        fadingContacts.removeAll()
        contactsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    private func setGeometry(of shape: CAShapeLayer, for contact: Contact) {
        // Always map the original sample into the current card dimensions.
        // Fading layers use this too, without restarting their opacity fade.
        let rx = contact.radiiMM.width * layer.bounds.width / device.sizeMM.width
        let ry = contact.radiiMM.height * layer.bounds.height / device.sizeMM.height
        shape.bounds = CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)
        shape.path = CGPath(ellipseIn: shape.bounds, transform: nil)
        shape.position = CGPoint(x: contact.position.x * layer.bounds.width,
                                 y: contact.position.y * layer.bounds.height)
        shape.setAffineTransform(CGAffineTransform(rotationAngle: contact.angle))
    }

    private func desaturated(_ color: CGColor?) -> CGColor? {
        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return color }
        // Preserve linear-light luminance and the original component alpha.
        // In particular, an approaching contact must never become an opaque
        // active-touch outline just because its path disappeared.
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let luminance = linear(rgb.redComponent) * 0.2126 + linear(rgb.greenComponent) * 0.7152 + linear(rgb.blueComponent) * 0.0722
        let grey = luminance <= 0.0031308 ? 12.92 * luminance : 1.055 * pow(luminance, 1 / 2.4) - 0.055
        return NSColor(srgbRed: grey, green: grey, blue: grey, alpha: rgb.alphaComponent).cgColor
    }
}
