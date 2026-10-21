import AppKit
import SwiftUI
import MemoryMonitorCore

enum DesktopPage: String, CaseIterable, Identifiable {
    case overview, processes, cleanup, history, stress, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "内存"
        case .processes: "进程"
        case .cleanup: "释放内存"
        case .history: "统计"
        case .stress: "压力测试"
        case .settings: "设置"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "memorychip"
        case .processes: "list.bullet.rectangle"
        case .cleanup: "sparkles"
        case .history: "chart.xyaxis.line"
        case .stress: "cpu"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class DesktopNavigation: ObservableObject {
    @Published var page: DesktopPage = .overview
    @Published var selectedProcess: ProcessIdentity?
    @Published var showsAudit = false
}

/// Owns the window independently of MenuBarExtra's transient focus lifetime.
@MainActor
final class DesktopWindowCoordinator: NSObject, NSWindowDelegate {
    let navigation = DesktopNavigation()
    let memoryTest: MemoryTestController
    private let model: MonitorViewModel
    private(set) var window: NSWindow?

    init(model: MonitorViewModel, allowsMemoryTest: Bool = false) {
        self.model = model
        memoryTest = MemoryTestController(operationGate: model.processActions.operationGate,
            manualActionIsBusy: { [weak model] in model?.processActions.isBusy != false },
            executionEnabled: allowsMemoryTest)
    }

    func show(_ page: DesktopPage = .overview, process: ProcessIdentity? = nil, audit: Bool = false) {
        navigation.page = page
        navigation.selectedProcess = process
        navigation.showsAudit = audit
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Memory Monitor"
            window.identifier = NSUserInterfaceItemIdentifier("memory-monitor-desktop")
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 800, height: 560)
            window.delegate = self
            window.contentView = NSHostingView(rootView: DesktopWindowRoot(
                model: model, navigation: navigation, memoryTest: memoryTest
            ))
            window.center()
            window.setFrameAutosaveName("MemoryMonitorDesktop")
            self.window = window
        }
        NSApplication.shared.setActivationPolicy(.regular)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        model.setDesktopPresented(true)
    }

    func windowWillClose(_ notification: Notification) {
        memoryTest.stop()
        model.smartCleanup.cancel()
        model.setDesktopPresented(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model.setDesktopPresented(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        model.setDesktopPresented(true)
    }
}

struct DesktopWindowRoot: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var navigation: DesktopNavigation
    @ObservedObject var memoryTest: MemoryTestController
    @AppStorage("desktopAppearance") private var appearance = "dark"

    var body: some View {
        DesktopShell(model: model, navigation: navigation, memoryTest: memoryTest)
        .sheet(isPresented: Binding(
            get: { navigation.selectedProcess != nil },
            set: { if !$0 { navigation.selectedProcess = nil } }
        )) {
            if let identity = navigation.selectedProcess {
                ProcessDetailView(model: model, actions: model.processActions, identity: identity)
            }
        }
        .sheet(isPresented: $navigation.showsAudit) {
            OperationsAuditPanel(actions: model.processActions)
        }
        .background(DesktopWindowAppearance(dark: appearance != "light"))
        .preferredColorScheme(appearance == "light" ? .light : .dark)
    }
}

private struct DesktopWindowAppearance: NSViewRepresentable {
    let dark: Bool

    func makeNSView(context: Context) -> AppearanceView { AppearanceView() }
    func updateNSView(_ view: AppearanceView, context: Context) {
        view.dark = dark
        view.apply()
    }

    final class AppearanceView: NSView {
        var dark = true
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() { window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
    }
}
