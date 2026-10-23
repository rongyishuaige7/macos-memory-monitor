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
        case .history: "历史"
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

enum DesktopAppearancePreference {
    static func colorScheme(_ value: String) -> ColorScheme? {
        switch value {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    static func isDark(_ value: String) -> Bool? {
        switch value {
        case "dark": return true
        case "light": return false
        default: return nil
        }
    }
}

@MainActor
final class DesktopNavigation: ObservableObject {
    @Published var page: DesktopPage = .overview
    @Published var selectedProcess: ProcessIdentity?
    @Published var showsAudit = false
    @Published var showsLocalData = false
    @Published var processQuery = ""
    @Published var processSort: DesktopProcessSort = .memory
    @Published var processIncludesSystem = false
    @Published var expandedProcessGroups: Set<String> = []
    @Published var historyHours = 1
    @Published var historyRangeInitialized = false
    @Published var searchFocusRequest = UUID()
}

/// Pure policy for whether the desktop window should request panel-level
/// sampling. A closed, hidden, minimized or fully occluded window is not a
/// surface the user can be reading, so it must not keep the 3-second cadence
/// and full process scan running.
enum DesktopPresentationPolicy {
    static func isPresented(
        windowExists: Bool,
        windowVisible: Bool,
        isMiniaturized: Bool,
        isOccluded: Bool,
        appHidden: Bool
    ) -> Bool {
        windowExists
            && windowVisible
            && !isMiniaturized
            && !isOccluded
            && !appHidden
    }
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
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationVisibilityChanged(_:)),
            name: NSApplication.didHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationVisibilityChanged(_:)),
            name: NSApplication.didUnhideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationVisibilityChanged(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationVisibilityChanged(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func show(
        _ page: DesktopPage = .overview,
        process: ProcessIdentity? = nil,
        audit: Bool = false,
        localData: Bool = false
    ) {
        navigation.page = page
        navigation.selectedProcess = process
        navigation.showsAudit = audit
        navigation.showsLocalData = localData
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
        updateDesktopPresentation()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateDesktopPresentation()
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else { return }
        updateDesktopPresentation()
    }

    @objc private func applicationVisibilityChanged(_ notification: Notification) {
        updateDesktopPresentation()
    }

    @objc private func activeSpaceChanged(_ notification: Notification) {
        updateDesktopPresentation()
    }

    private func updateDesktopPresentation() {
        guard let window else {
            model.setDesktopPresented(false)
            return
        }
        let presented = DesktopPresentationPolicy.isPresented(
            windowExists: true,
            windowVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isOccluded: !window.occlusionState.contains(.visible),
            appHidden: NSApplication.shared.isHidden
        )
        model.setDesktopPresented(presented)
    }
}

struct DesktopWindowRoot: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var navigation: DesktopNavigation
    @ObservedObject var memoryTest: MemoryTestController
    @AppStorage("desktopAppearance") private var appearance = "system"

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
        .sheet(isPresented: $navigation.showsLocalData) {
            LocalDataPanel()
        }
        .background(DesktopWindowAppearance(dark: DesktopAppearancePreference.isDark(appearance)))
        .preferredColorScheme(DesktopAppearancePreference.colorScheme(appearance))
    }
}

private struct DesktopWindowAppearance: NSViewRepresentable {
    let dark: Bool?

    func makeNSView(context: Context) -> AppearanceView { AppearanceView() }
    func updateNSView(_ view: AppearanceView, context: Context) {
        view.dark = dark
        view.apply()
    }

    final class AppearanceView: NSView {
        var dark: Bool?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            guard let dark else {
                window?.appearance = nil
                return
            }
            window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
    }
}
