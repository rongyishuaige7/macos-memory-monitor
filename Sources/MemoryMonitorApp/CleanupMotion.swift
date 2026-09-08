import AppKit
import MemoryMonitorCore
import QuartzCore
import SwiftUI

enum CleanupMotionTier: Equatable {
    case off, reduced, full
    static func resolve(enabled: Bool, reduceMotion: Bool, pressure: MemoryPressureLevel?) -> Self {
        guard enabled, !reduceMotion else { return .off }
        switch pressure {
        case .normal: return .full
        case .attention: return .reduced
        case .critical, nil: return .off
        }
    }
}

struct CleanupParticles: NSViewRepresentable {
    let phase: CleanupPhase
    let tier: CleanupMotionTier
    let pulse: Int
    let measuredBenefit: Bool

    func makeNSView(context: Context) -> CleanupParticleView { CleanupParticleView() }
    func updateNSView(_ view: CleanupParticleView, context: Context) {
        view.configure(phase: phase, tier: tier, pulse: pulse, measuredBenefit: measuredBenefit)
    }
    static func dismantleNSView(_ view: CleanupParticleView, coordinator: ()) { view.stop() }
}

/// All movement stays in Core Animation; the controller publishes only task events.
final class CleanupParticleView: NSView {
    private(set) var emitter: CAEmitterLayer?
    private(set) var suppressionReason: String?
    private var phase: CleanupPhase = .idle
    private var tier: CleanupMotionTier = .off
    private var lastPulse = 0
    private var configured = false
    private var pendingPulse = false
    private var pendingSuccess = false
    private var renderedPhase: CleanupPhase?
    private var renderedTier: CleanupMotionTier?
    private var lastBounds = CGRect.zero
    private var finish: DispatchWorkItem?
    private var endEmission: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                     NSView.boundsDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(lifecycle(_:)), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lifecycle(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        reconcile()
    }
    override func viewDidHide() { super.viewDidHide(); reconcile() }
    override func viewDidUnhide() { super.viewDidUnhide(); reconcile() }
    override func layout() {
        super.layout()
        if lastBounds != bounds { lastBounds = bounds; clearLayers() }
        reconcile()
    }

    func configure(phase: CleanupPhase, tier: CleanupMotionTier, pulse: Int, measuredBenefit: Bool) {
        pendingPulse = configured && pulse != lastPulse
        pendingSuccess = configured && self.phase != .finished && phase == .finished && measuredBenefit
        self.phase = phase
        self.tier = tier
        lastPulse = pulse
        configured = true
        reconcile()
    }

    @objc private func lifecycle(_ notification: Notification) {
        if notification.name == NSApplication.didResignActiveNotification ||
            (notification.name == NSWindow.willCloseNotification && notification.object as? NSWindow === window) {
            stop()
        } else { reconcile() }
    }

    private func reconcile() {
        suppressionReason = tier == .off ? "disabled" : NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "reduced motion" :
            !NSRunningApplication.current.isActive ? "inactive" : window == nil ? "detached" :
            window?.isVisible != true ? "invisible" : window?.isMiniaturized == true ? "minimized" :
            window?.occlusionState.contains(.visible) != true ? "occluded" : isHiddenOrHasHiddenAncestor ? "hidden" :
            visibleRect.isEmpty ? "offscreen" : nil
        guard suppressionReason == nil else { stop(); return }
        if pendingSuccess {
            clearLayers()
            renderedPhase = phase
            renderedTier = tier
            burst()
        } else if phase == .idle || phase == .finished {
            if renderedPhase != phase { clearLayers(); renderedPhase = phase }
        } else if renderedPhase != phase || renderedTier != tier {
            clearLayers()
            renderedPhase = phase
            renderedTier = tier
            animateStage()
        }
        if pendingPulse && phase != .idle && phase != .finished { pulseRing() }
        pendingSuccess = false
        pendingPulse = false
    }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var radius: CGFloat { min(89, bounds.height * 0.4) }
    private var accent: NSColor { phase == .waiting ? .systemTeal : .systemCyan }

    private func animateStage() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let ring = CAShapeLayer()
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = accent.withAlphaComponent(0.85).cgColor
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.strokeStart = 0
        ring.strokeEnd = phase == .measuring ? 0.12 : 0.23
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = phase == .waiting ? 5 : 2.8
        rotation.repeatCount = .infinity
        ring.add(rotation, forKey: "scan")
        layer?.addSublayer(ring)

        if phase == .measuring { return }
        let count = tier == .full ? 10 : 4
        for index in 0..<count {
            addStream(index: index, count: count)
        }
        let dust = CAEmitterLayer()
        dust.frame = bounds
        dust.emitterPosition = center
        dust.emitterShape = .circle
        dust.emitterMode = .outline
        dust.emitterSize = CGSize(width: radius * 2.2, height: radius * 2.2)
        let cell = particleCell(color: accent)
        cell.birthRate = tier == .full ? 30 : 8
        cell.lifetime = 1.3
        cell.velocity = 8
        cell.velocityRange = 4
        cell.emissionRange = .pi * 2
        cell.alphaSpeed = -0.7
        dust.emitterCells = [cell]
        layer?.addSublayer(dust)
        emitter = dust
    }

    private func addStream(index: Int, count: Int) {
        let angle = CGFloat(index) / CGFloat(count) * .pi * 2 + 0.12
        let outerX = max(radius + 15, min(bounds.width * 0.46, 285))
        let outerY = min(bounds.height * 0.47, 110)
        let start = CGPoint(x: center.x + cos(angle) * outerX, y: center.y + sin(angle) * outerY)
        let endAngle = angle - 0.45
        let end = CGPoint(x: center.x + cos(endAngle) * (radius + 6), y: center.y + sin(endAngle) * (radius + 6))
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end,
            control1: CGPoint(x: center.x + cos(angle + 0.4) * outerX * 0.84, y: center.y + sin(angle + 0.4) * outerY),
            control2: CGPoint(x: center.x + cos(endAngle + 0.3) * (radius + 24), y: center.y + sin(endAngle + 0.3) * (radius + 24)))
        let trace = CAShapeLayer()
        trace.path = path
        trace.fillColor = nil
        trace.strokeColor = accent.withAlphaComponent(0.10).cgColor
        trace.lineWidth = 0.7
        layer?.addSublayer(trace)
        let duration = phase == .waiting ? 3.2 : phase == .scanning ? 2.4 : 1.4
        let beads = tier == .full ? 3 : 1
        for bead in 0..<beads {
            let point = CALayer()
            let size: CGFloat = bead == 0 ? 3 : 2
            point.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            point.cornerRadius = size / 2
            point.backgroundColor = (index.isMultiple(of: 3) ? NSColor.systemMint : accent).cgColor
            point.opacity = 0
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.85, 0.65, 0]
            fade.keyTimes = [0, 0.25, 0.75, 1]
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = duration
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.09 + Double(bead) * 0.24
            point.add(group, forKey: "inward")
            layer?.addSublayer(point)
        }
    }

    private func pulseRing() {
        // Reuse one event layer so a fast batch cannot accumulate pulse layers.
        layer?.sublayers?.first(where: { $0.name == "completion-pulse" })?.removeFromSuperlayer()
        let ring = CAShapeLayer()
        ring.name = "completion-pulse"
        ring.frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        ring.strokeColor = NSColor.systemMint.cgColor
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.opacity = 0
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.85
        opacity.toValue = 0
        opacity.duration = 0.6
        ring.add(opacity, forKey: "verified")
        layer?.addSublayer(ring)
    }

    private func burst() {
        pulseRing()
        let dust = CAEmitterLayer()
        dust.frame = bounds
        dust.emitterPosition = center
        dust.emitterShape = .circle
        dust.emitterMode = .outline
        dust.emitterSize = CGSize(width: radius * 2, height: radius * 2)
        let cell = particleCell(color: .systemMint)
        cell.birthRate = tier == .full ? 160 : 45
        cell.lifetime = 0.7
        cell.velocity = 50
        cell.velocityRange = 20
        cell.emissionRange = .pi * 2
        cell.alphaSpeed = -1.2
        dust.emitterCells = [cell]
        layer?.addSublayer(dust)
        emitter = dust
        let end = DispatchWorkItem { [weak self] in self?.emitter?.birthRate = 0 }
        let finish = DispatchWorkItem { [weak self] in
            self?.clearLayers()
            self?.renderedPhase = .finished
        }
        self.endEmission = end
        self.finish = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: end)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95, execute: finish)
    }

    private func particleCell(color: NSColor) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = Self.particleImage
        cell.color = color.cgColor
        cell.scale = 0.4
        cell.scaleRange = 0.15
        return cell
    }

    private static let particleImage: CGImage? = {
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 1, y: 1, width: 6, height: 6))
        return context.makeImage()
    }()

    private func clearLayers() {
        finish?.cancel()
        endEmission?.cancel()
        finish = nil
        endEmission = nil
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        emitter = nil
        renderedPhase = nil
        renderedTier = nil
    }

    func stop() {
        pendingSuccess = false
        pendingPulse = false
        clearLayers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
