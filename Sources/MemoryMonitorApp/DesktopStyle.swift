import AppKit
import SwiftUI

struct MemoryMonitorMark: Shape {
    // MenuBarExtra extracts Image labels but does not display arbitrary shapes.
    @MainActor static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 17, height: 17), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            MemoryMonitorBrand.drawSymbol(in: context, rect: rect, color: CGColor(gray: 0, alpha: 1))
            return true
        }
        image.isTemplate = true
        return image
    }()

    func path(in rect: CGRect) -> Path {
        Path(MemoryMonitorBrand.symbolPath(in: rect))
    }
}

struct GlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var accent: Color = .white

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accent.opacity(scheme == .dark ? 0.055 : 0.025))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(LinearGradient(
                        colors: [.white.opacity(scheme == .dark ? 0.20 : 0.7), .white.opacity(0.03)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
            }
    }
}

struct MonitorPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.monitorMotionAllowed) private var motion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .padding(.horizontal, 20).frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: enabled ? [.init(red: 0.15, green: 0.66, blue: 0.96), .blue] : [.gray.opacity(0.18)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(enabled ? 0.26 : 0.06), lineWidth: 0.8) }
            .brightness(configuration.isPressed ? -0.09 : 0)
            .scaleEffect(configuration.isPressed && motion ? 0.985 : 1)
            .animation(motion ? .easeOut(duration: 0.15) : nil, value: configuration.isPressed)
    }
}

struct MonitorRowHover: ViewModifier {
    @Environment(\.monitorMotionAllowed) private var motion
    @State private var hovering = false
    var selected = false

    func body(content: Content) -> some View {
        content
            .background((selected ? Color.blue.opacity(0.14) : hovering ? Color.primary.opacity(0.055) : .clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .animation(motion ? .easeOut(duration: 0.16) : nil, value: hovering)
            .animation(motion ? .easeOut(duration: 0.18) : nil, value: selected)
    }
}

extension View {
    func glassSurface(accent: Color = .white) -> some View { modifier(GlassSurface(accent: accent)) }
    func monitorRowHover(selected: Bool = false) -> some View { modifier(MonitorRowHover(selected: selected)) }
}
