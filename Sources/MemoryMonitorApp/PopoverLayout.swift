import Foundation
import SwiftUI

/// Pure sizing policy for the menu-bar popover.
///
/// The header, view switcher, and footer stay outside the central scroll view.
/// This keeps long live/history content from pushing the footer beyond the
/// popover viewport while allowing callers to provide measured fixed-area
/// heights when accessibility sizing changes.
struct MonitorPopoverLayoutPolicy: Equatable, Sendable {
    static let defaultWidth: Double = 410
    static let defaultMaxHeight: Double = 650
    static let defaultContentMaxHeight: Double = 480
    static let minimumContentHeight: Double = 180

    static let defaultHeaderHeight: Double = 74
    static let defaultViewPickerHeight: Double = 32
    static let minimumFooterHeight: Double = 44
    static let defaultVerticalSpacing: Double = 14
    static let defaultVerticalPadding: Double = 32

    /// Fixed chrome reserved by the production popover. This includes the
    /// header, view picker, footer, root spacing, and vertical insets.
    /// Keep this aligned with the default `chromeHeight` used by
    /// `contentHeight(maxHeight:chromeHeight:minimum:)`.
    static let defaultReservedHeight: Double = 170

    let width: Double
    let maxHeight: Double
    let contentMaxHeight: Double

    init(
        width: Double = Self.defaultWidth,
        maxHeight: Double = Self.defaultMaxHeight,
        contentMaxHeight: Double = Self.defaultContentMaxHeight
    ) {
        self.width = Self.configurationValue(width, fallback: Self.defaultWidth)
        let configuredMaxHeight = Self.configurationValue(
            maxHeight,
            fallback: Self.defaultMaxHeight
        )
        // Keep the fixed chrome and the minimum scroll viewport representable
        // even when a caller supplies an undersized custom cap.
        self.maxHeight = max(
            configuredMaxHeight,
            Self.defaultReservedHeight + Self.minimumContentHeight
        )
        let requestedContentMaxHeight = Self.configurationValue(
            contentMaxHeight,
            fallback: Self.defaultContentMaxHeight
        )
        self.contentMaxHeight = max(
            min(
                requestedContentMaxHeight,
                Self.contentHeight(maxHeight: self.maxHeight)
            ),
            Self.minimumContentHeight
        )
    }

    /// The default production policy used by the popover view.
    static let `default` = Self()

    /// Compatibility aliases for callers that describe the outer bound as a
    /// popover bound rather than the policy's `maxHeight`.
    static let defaultPopoverMaxHeight = defaultMaxHeight

    var popoverMaxHeight: Double { maxHeight }

    /// The finite viewport offered to the variable body by the production
    /// chrome. It is never smaller than the minimum usable content height.
    var contentViewportHeight: Double {
        max(
            centralScrollHeight(availableHeight: maxHeight),
            Self.minimumContentHeight
        )
    }

    /// The minimum total height needed to keep the fixed footer reachable.
    var minimumPopoverHeight: Double {
        Self.defaultReservedHeight
    }

    /// Returns the finite central viewport available below fixed chrome.
    /// The minimum keeps a normal popover usable even when a small custom
    /// content cap is supplied.
    static func contentHeight(
        maxHeight: Double = Self.defaultMaxHeight,
        chromeHeight: Double = 170,
        minimum: Double = Self.minimumContentHeight
    ) -> Double {
        let safeMax = configurationValue(maxHeight, fallback: Self.defaultMaxHeight)
        let safeChrome = configurationValue(chromeHeight, fallback: 170)
        let safeMinimum = configurationValue(minimum, fallback: Self.minimumContentHeight)
        let available = max(safeMax - safeChrome, 0)
        return max(available, safeMinimum)
    }

    /// Computes a finite total popover height from content and fixed-area
    /// measurements. A content value larger than the central cap scrolls;
    /// invalid content contributes zero height.
    func totalHeight(
        contentHeight: Double,
        reservedHeight: Double = Self.defaultReservedHeight
    ) -> Double {
        let reserved = Self.runtimeValue(reservedHeight)
        let content = Self.contentValue(contentHeight, cap: contentMaxHeight)
        let central = min(content, centralScrollHeight(
            availableHeight: maxHeight,
            reservedHeight: reserved
        ))

        // The reserved area contains the footer. If a caller supplies a
        // malformed value, preserving the production baseline keeps that
        // footer reachable instead of allowing the root stack to collapse.
        let minimumReserved = max(reserved, minimumPopoverHeight)
        let total = minimumReserved + central
        guard total.isFinite else { return minimumReserved }
        // A malformed or undersized outer cap cannot be allowed to clip the
        // footer. In that case the fixed area is the effective lower bound.
        let upperBound = max(maxHeight, minimumReserved)
        return min(max(total, minimumReserved), upperBound)
    }

    /// Computes the central scroll viewport for a finite or unbounded outer
    /// viewport. The result is always finite and non-negative.
    func centralScrollHeight(
        availableHeight: Double,
        reservedHeight: Double = Self.defaultReservedHeight
    ) -> Double {
        let available: Double
        if availableHeight == .infinity {
            available = maxHeight
        } else {
            available = Self.runtimeValue(availableHeight)
        }
        let reserved = max(Self.runtimeValue(reservedHeight), minimumPopoverHeight)
        guard available > reserved else { return 0 }
        return min(available - reserved, contentMaxHeight)
    }

    /// Label-compatible overload for callers that name the outer viewport.
    func centralScrollHeight(
        viewportHeight: Double,
        reservedHeight: Double = Self.defaultReservedHeight
    ) -> Double {
        centralScrollHeight(
            availableHeight: viewportHeight,
            reservedHeight: reservedHeight
        )
    }

    /// Returns a finite non-negative runtime dimension. NaN, infinities other
    /// than positive infinity, and negative values collapse to zero.
    private static func runtimeValue(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(value, 0)
    }

    /// Configuration dimensions need a positive finite value. Positive
    /// infinity is intentionally rejected so layout cannot become unbounded.
    private static func configurationValue(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value > 0 else { return fallback }
        return value
    }

    private static func contentValue(_ value: Double, cap: Double) -> Double {
        guard value.isFinite else {
            return value == .infinity ? cap : 0
        }
        return min(max(value, 0), cap)
    }
}

/// Keeps the variable live/history body in one vertical scroll container.
/// Fixed chrome such as the header and footer remains outside this view so
/// the exit action is reachable even when the body is taller than the window.
struct MonitorPopoverContentScroll<Content: View>: View {
    let layout: MonitorPopoverLayoutPolicy
    private let content: Content

    init(
        layout: MonitorPopoverLayoutPolicy = .default,
        @ViewBuilder content: () -> Content
    ) {
        self.layout = layout
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: CGFloat(MonitorPopoverLayoutPolicy.minimumContentHeight),
            maxHeight: CGFloat(layout.contentViewportHeight),
            alignment: .top
        )
        .accessibilityIdentifier("monitor-popover-content")
    }
}
