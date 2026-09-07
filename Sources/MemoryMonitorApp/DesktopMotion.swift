import AppKit
import QuartzCore
import SwiftUI

private struct MonitorMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var monitorMotionAllowed: Bool {
        get { self[MonitorMotionKey.self] }
        set { self[MonitorMotionKey.self] = newValue }
    }
}

enum MonitorParticleMode: Equatable { case running, burst }

struct MonitorParticles: NSViewRepresentable {
    let mode: MonitorParticleMode
    var running = false
    var trigger = 0
    @Environment(\.monitorMotionAllowed) private var allowed

    func makeNSView(context: Context) -> MonitorParticleView { MonitorParticleView() }
    func updateNSView(_ view: MonitorParticleView, context: Context) {
        view.configure(mode: mode, running: running, trigger: trigger, allowed: allowed)
    }
    static func dismantleNSView(_ view: MonitorParticleView, coordinator: ()) { view.stop() }
}

/// The compositor advances particles; sampling and SwiftUI never receive frame ticks.
final class MonitorParticleView: NSView {
    private(set) var emitter: CAEmitterLayer?
    private(set) var suppressionReason: String?
    private var mode: MonitorParticleMode = .running
    private var running = false
    private var allowed = false
    private var lastTrigger = 0
    private var pendingBurst = false
    private var stopEmission: DispatchWorkItem?
    private var finishBurst: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                     NSView.boundsDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(lifecycleChanged(_:)), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lifecycleChanged(_:)),
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter?.frame = bounds
        emitter?.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        reconcile()
    }

    func configure(mode: MonitorParticleMode, running: Bool, trigger: Int, allowed: Bool) {
        if self.mode != mode { stop() }
        self.mode = mode
        self.running = running
        self.allowed = allowed
        if lastTrigger != trigger {
            lastTrigger = trigger
            pendingBurst = trigger > 0
        }
        reconcile()
    }

    @objc private func lifecycleChanged(_ notification: Notification) {
        if notification.name == NSApplication.didResignActiveNotification ||
            (notification.name == NSWindow.willCloseNotification && notification.object as? NSWindow === window) {
            stop()
        } else { reconcile() }
    }

    private func reconcile() {
        suppressionReason = !allowed ? "disabled" : NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "reduced motion" :
            !NSRunningApplication.current.isActive ? "inactive" : window == nil ? "detached" :
            window?.isVisible != true ? "invisible" : window?.isMiniaturized == true ? "minimized" :
            window?.occlusionState.contains(.visible) != true ? "occluded" : isHiddenOrHasHiddenAncestor ? "hidden" :
            visibleRect.isEmpty ? "offscreen" : nil
        guard suppressionReason == nil else {
            stop()
            return
        }
        switch mode {
        case .running:
            if running, emitter == nil { startEmitter(burst: false) }
            else if !running { stop() }
        case .burst:
            guard pendingBurst else { return }
            stop()
            startEmitter(burst: true)
        }
    }

    private func startEmitter(burst: Bool) {
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        emitter.emitterShape = burst ? .point : .circle
        emitter.emitterMode = .outline
        emitter.emitterSize = burst ? .zero : CGSize(width: min(bounds.width, bounds.height) * 0.76,
                                                     height: min(bounds.width, bounds.height) * 0.76)
        emitter.seed = UInt32.random(in: 1...UInt32.max)
        let cell = CAEmitterCell()
        cell.contents = Self.particleImage
        cell.color = (burst ? NSColor.systemGreen : NSColor.systemCyan).cgColor
        cell.birthRate = burst ? 100 : 12
        cell.lifetime = burst ? 0.65 : 0.85
        cell.velocity = burst ? 65 : 12
        cell.velocityRange = burst ? 20 : 5
        cell.emissionRange = .pi * 2
        cell.scale = burst ? 0.55 : 0.45
        cell.scaleRange = 0.15
        cell.alphaSpeed = -1.1
        emitter.emitterCells = [cell]
        layer?.addSublayer(emitter)
        self.emitter = emitter
        if burst {
            let stopEmission = DispatchWorkItem { [weak self] in self?.emitter?.birthRate = 0 }
            let finishBurst = DispatchWorkItem { [weak self] in self?.stop() }
            self.stopEmission = stopEmission
            self.finishBurst = finishBurst
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: stopEmission)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: finishBurst)
        }
    }

    func stop() {
        stopEmission?.cancel()
        finishBurst?.cancel()
        stopEmission = nil
        finishBurst = nil
        pendingBurst = false
        emitter?.removeFromSuperlayer()
        emitter = nil
    }

    private static let particleImage: CGImage? = {
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 1, y: 1, width: 6, height: 6))
        return context.makeImage()
    }()

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
