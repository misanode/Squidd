import AppKit
import QuartzCore

final class SplashWindow: NSPanel {
    static let cardWidth: CGFloat = 400
    static let cardAspect: CGFloat = 598.0 / 1000.0
    static let spinnerGap: CGFloat = 18
    static let spinnerSize: CGFloat = 20
    static let edge: CGFloat = 2
    static let logoReveal = 0.22
    static let wordmarkRise = 0.42
    static let wordmarkFade = 0.26
    static let wordmarkLift: CGFloat = 18
    static let fadeOut = 0.18
    static let spinPeriod = 0.9
    static let rise = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private let card = CALayer()
    private let logo = CALayer()
    private let wordmark = CALayer()
    private let spinner = CALayer()
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let cardSize: CGSize
    private var dismissed = false

    var entranceDuration: TimeInterval { reduceMotion ? 0.25 : Self.logoReveal + Self.wordmarkRise }

    init?(screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return nil }
        let area = screen.visibleFrame
        let extra = Self.spinnerGap + Self.spinnerSize + Self.edge
        let width = min(Self.cardWidth, area.width * 0.8, (area.height * 0.8 - extra) / Self.cardAspect).rounded(.down)
        cardSize = CGSize(width: width, height: (width * Self.cardAspect).rounded())
        let size = NSSize(width: width, height: cardSize.height + extra)
        let frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        guard let images = Self.artwork(cardSize, scale: screen.backingScaleFactor) else { return nil }
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.progressIndicator)
        view.setAccessibilityLabel("Squidd is loading")
        contentView = view
        let root = view.layer!
        let scale = screen.backingScaleFactor
        let cardFrame = CGRect(x: 0, y: extra, width: cardSize.width, height: cardSize.height)
        for (layer, image) in zip([card, logo, wordmark], images) {
            layer.frame = cardFrame
            layer.contents = image
            layer.contentsScale = scale
            root.addSublayer(layer)
        }

        spinner.frame = CGRect(x: (width - Self.spinnerSize) / 2, y: Self.edge, width: Self.spinnerSize, height: Self.spinnerSize)
        let ring = CGPath(ellipseIn: spinner.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        track.path = ring
        track.fillColor = nil
        track.strokeColor = NSColor(srgbRed: 0x40 / 255.0, green: 0x0A / 255.0, blue: 0x0A / 255.0, alpha: 0.5).cgColor
        track.lineWidth = 4
        arc.path = ring
        arc.fillColor = nil
        arc.strokeColor = NSColor.white.cgColor
        arc.lineWidth = 2.25
        arc.lineCap = .round
        arc.strokeEnd = reduceMotion ? 1 : 0.28
        for layer in [track, arc] {
            layer.frame = spinner.bounds
            layer.contentsScale = scale
            spinner.addSublayer(layer)
        }
        root.addSublayer(spinner)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private static func artwork(_ size: CGSize, scale: CGFloat) -> [CGImage]? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        var images: [CGImage] = []
        for (name, type) in [("splash-card", "svg"), ("splash-logo", "png"), ("splash-wordmark", "svg")] {
            guard let url = Bundle.main.url(forResource: name, withExtension: type), let art = NSImage(contentsOf: url),
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            art.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            guard let image = rep.cgImage else { return nil }
            images.append(image)
        }
        return images
    }

    private func fade(_ layer: CALayer, at begin: CFTimeInterval, duration: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.beginTime = begin
        a.duration = duration
        a.fillMode = .backwards
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "entrance")
    }

    func show(onEntered: @escaping () -> Void) {
        let start = CACurrentMediaTime() + 0.02
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if reduceMotion {
            for layer in [card, logo, wordmark, spinner] { fade(layer, at: start, duration: 0.25) }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.45
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = start + 0.25
            arc.add(pulse, forKey: "loading")
        } else {
            fade(card, at: start, duration: 0.16)
            fade(logo, at: start, duration: Self.logoReveal)
            fade(spinner, at: start, duration: 0.2)
            fade(wordmark, at: start + Self.logoReveal, duration: Self.wordmarkFade)
            let lift = Self.wordmarkLift * cardSize.width / Self.cardWidth
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -lift
            rise.toValue = 0
            rise.beginTime = start + Self.logoReveal
            rise.duration = Self.wordmarkRise
            rise.fillMode = .backwards
            rise.timingFunction = Self.rise
            wordmark.add(rise, forKey: "rise")
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = Self.spinPeriod
            spin.repeatCount = .infinity
            spinner.add(spin, forKey: "loading")
        }
        CATransaction.commit()
        orderFrontRegardless()
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 + entranceDuration) { [weak self] in
            guard let self, !self.dismissed else { return }
            onEntered()
        }
    }

    func dismiss(completion: (() -> Void)? = nil) {
        guard !dismissed else { return }
        dismissed = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeOut
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.tearDown()
            completion?()
        })
    }

    func tearDown() {
        dismissed = true
        for layer in [card, logo, wordmark, spinner, arc] { layer.removeAllAnimations() }
        orderOut(nil)
        close()
    }
}
