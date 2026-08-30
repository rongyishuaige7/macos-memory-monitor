import Foundation
import SwiftUI

/// Keeps vertical detail scroll content tied to the sheet viewport.
///
/// A vertical `ScrollView` may measure its child with an unspecified width.
/// That makes intrinsic children (notably grids and fixed-size rows) choose a
/// width unrelated to the visible sheet and can create an accidental
/// horizontal overflow. Measuring the viewport first gives the content a
/// deterministic width while retaining the minimum width used by the detail
/// windows.
struct AdaptiveDetailScrollView<Content: View>: View {
    let minimumContentWidth: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = resolvedContentWidth(proxy.size.width)
            ScrollView(.vertical) {
                content()
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.horizontal, CGFloat(DetailLayoutPolicy.detailHorizontalPadding))
                    .padding(.vertical, 20)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func resolvedContentWidth(_ viewportWidth: CGFloat) -> CGFloat {
        CGFloat(
            DetailLayoutPolicy.contentWidth(
                viewportWidth: Double(viewportWidth),
                minimumContentWidth: Double(minimumContentWidth)
            )
        )
    }
}

enum DetailRowLayoutMode: String, Equatable, Sendable {
    case inline
    case stacked
}

/// Intrinsic widths used by a relation row's inline candidate.
///
/// Keeping the measured values in a small value type lets the policy and the
/// custom SwiftUI layout agree on the same required-width calculation. The
/// minimum name width mirrors the previous `frame(minWidth:)` guarantee while
/// allowing the label and trailing metadata to follow their actual fonts.
struct DetailRelationMetrics: Equatable, Sendable {
    let labelWidth: Double
    let nameWidth: Double
    let trailingWidth: Double
    let spacing: Double
    let spacerMinimumLength: Double
    let minimumNameWidth: Double

    var requiredWidth: Double {
        let label = nonNegativePreservingInfinity(labelWidth)
        let name = max(
            nonNegativePreservingInfinity(nameWidth),
            nonNegativePreservingInfinity(minimumNameWidth)
        )
        let trailing = nonNegativePreservingInfinity(trailingWidth)
        let gap = nonNegativePreservingInfinity(spacing)
        let spacer = nonNegativePreservingInfinity(spacerMinimumLength)

        var total = 0.0
        for component in [label, name, trailing, spacer] {
            if component == .infinity { return .infinity }
            total += component
            if !total.isFinite { return .infinity }
        }
        let gaps = gap * Double(DetailLayoutPolicy.relationGapCount)
        guard gaps.isFinite else { return .infinity }
        total += gaps
        return total.isFinite ? total : .infinity
    }

    private func nonNegativePreservingInfinity(_ value: Double) -> Double {
        if value == .infinity { return .infinity }
        guard value.isFinite else { return 0 }
        return max(value, 0)
    }
}

/// Pure sizing decisions shared by the detail layouts and their tests.
/// Keeping the thresholds here prevents each row from inventing a different
/// definition of "too narrow".
enum DetailLayoutPolicy {
    static let detailHorizontalPadding: Double = 20
    static let detailHorizontalInset: Double = detailHorizontalPadding * 2
    static let defaultInfoLabelWidth: Double = 78
    static let infoRowSpacing: Double = 10
    static let minimumInfoValueWidth: Double = 150
    static let relationSpacing: Double = 8
    static let relationSpacerMinimumLength: Double = 4
    static let relationGapCount: Int = 3
    static let minimumRelationValueWidth: Double = 140
    static let actionSpacing: Double = 8
    static let minimumActionButtonWidth: Double = 112
    static let metricMinimumColumnWidth: Double = 180
    static let metricSpacing: Double = 10

    static func contentWidth(
        viewportWidth: Double,
        minimumContentWidth: Double,
        horizontalInset: Double = detailHorizontalInset
    ) -> Double {
        let minimum = finiteNonNegative(minimumContentWidth)
        let inset = finiteNonNegative(horizontalInset)
        guard viewportWidth.isFinite, viewportWidth > 0 else {
            return minimum
        }
        return max(minimum, viewportWidth - inset)
    }

    static func infoRowMode(
        availableWidth: Double,
        labelWidth: Double = defaultInfoLabelWidth,
        minimumValueWidth: Double = minimumInfoValueWidth,
        spacing: Double = infoRowSpacing
    ) -> DetailRowLayoutMode {
        modeForRequiredWidth(
            availableWidth: availableWidth,
            requiredWidth: max(labelWidth, 0) + max(spacing, 0) + max(minimumValueWidth, 0)
        )
    }

    static func relationRowMode(
        availableWidth: Double,
        leadingWidth: Double = 52,
        trailingWidth: Double = 74,
        minimumValueWidth: Double = minimumRelationValueWidth,
        spacing: Double = relationSpacing
    ) -> DetailRowLayoutMode {
        relationRowMode(
            availableWidth: availableWidth,
            metrics: DetailRelationMetrics(
                labelWidth: leadingWidth,
                nameWidth: minimumValueWidth,
                trailingWidth: trailingWidth,
                spacing: spacing,
                spacerMinimumLength: relationSpacerMinimumLength,
                minimumNameWidth: 0
            )
        )
    }

    /// Returns the minimum width needed by a measured relation row.
    ///
    /// The inline row contains three HStack gaps: label/name, name/spacer,
    /// and spacer/trailing. The spacer's minimum length is included as a
    /// separate term so the policy matches the custom layout exactly.
    static func relationRequiredWidth(
        metrics: DetailRelationMetrics
    ) -> Double {
        metrics.requiredWidth
    }

    /// Convenience overload for callers that already have measured child
    /// widths. The name width is floored at `minimumValueWidth` so a short
    /// process name cannot collapse the value column.
    static func relationRequiredWidth(
        labelWidth: Double,
        nameWidth: Double,
        trailingWidth: Double,
        minimumValueWidth: Double = minimumRelationValueWidth,
        spacing: Double = relationSpacing,
        spacerMinimumLength: Double = relationSpacerMinimumLength
    ) -> Double {
        relationRequiredWidth(
            metrics: DetailRelationMetrics(
                labelWidth: labelWidth,
                nameWidth: nameWidth,
                trailingWidth: trailingWidth,
                spacing: spacing,
                spacerMinimumLength: spacerMinimumLength,
                minimumNameWidth: minimumValueWidth
            )
        )
    }

    /// Selects inline or stacked mode from measured relation-row widths.
    static func relationRowMode(
        availableWidth: Double,
        metrics: DetailRelationMetrics
    ) -> DetailRowLayoutMode {
        modeForRequiredWidth(
            availableWidth: availableWidth,
            requiredWidth: relationRequiredWidth(metrics: metrics)
        )
    }

    /// Measured-width overload kept explicit for tests and non-View callers.
    static func relationRowMode(
        availableWidth: Double,
        labelWidth: Double,
        nameWidth: Double,
        trailingWidth: Double,
        minimumValueWidth: Double = minimumRelationValueWidth,
        spacing: Double = relationSpacing,
        spacerMinimumLength: Double = relationSpacerMinimumLength
    ) -> DetailRowLayoutMode {
        relationRowMode(
            availableWidth: availableWidth,
            metrics: DetailRelationMetrics(
                labelWidth: labelWidth,
                nameWidth: nameWidth,
                trailingWidth: trailingWidth,
                spacing: spacing,
                spacerMinimumLength: spacerMinimumLength,
                minimumNameWidth: minimumValueWidth
            )
        )
    }

    static func actionLayoutMode(
        availableWidth: Double,
        buttonCount: Int,
        minimumButtonWidth: Double = minimumActionButtonWidth,
        spacing: Double = actionSpacing
    ) -> DetailRowLayoutMode {
        guard buttonCount > 0 else { return .inline }
        return modeForRequiredWidth(
            availableWidth: availableWidth,
            requiredWidth: actionRequiredWidth(
                buttonCount: buttonCount,
                minimumButtonWidth: minimumButtonWidth,
                spacing: spacing
            )
        )
    }

    static func actionRequiredWidth(
        buttonCount: Int,
        minimumButtonWidth: Double = minimumActionButtonWidth,
        spacing: Double = actionSpacing
    ) -> Double {
        guard buttonCount > 0 else { return 0 }
        let count = Double(buttonCount)
        let minimum = finiteNonNegative(minimumButtonWidth)
        let gap = finiteNonNegative(spacing)
        return count * minimum + max(count - 1, 0) * gap
    }

    static func actionRequiredWidth(
        buttonWidths: [Double],
        minimumButtonWidth: Double = minimumActionButtonWidth,
        spacing: Double = actionSpacing
    ) -> Double {
        guard !buttonWidths.isEmpty else { return 0 }
        let minimum = finiteNonNegative(minimumButtonWidth)
        let gap = finiteNonNegative(spacing)
        let width = buttonWidths.reduce(0) { total, candidate in
            if candidate == .infinity {
                return .infinity
            }
            let safeCandidate = candidate.isFinite
                ? max(candidate, minimum)
                : minimum
            return total + safeCandidate
        }
        guard width.isFinite else { return .infinity }
        return width + max(Double(buttonWidths.count - 1), 0) * gap
    }

    static func metricColumnCount(
        availableWidth: Double,
        minimumColumnWidth: Double = metricMinimumColumnWidth,
        spacing: Double = metricSpacing,
        maximumColumns: Int = 2
    ) -> Int {
        guard maximumColumns > 0 else { return 1 }
        guard availableWidth.isFinite else {
            return availableWidth == .infinity ? maximumColumns : 1
        }
        guard availableWidth > 0,
              minimumColumnWidth.isFinite,
              minimumColumnWidth > 0,
              spacing.isFinite else {
            return 1
        }
        let gap = max(spacing, 0)
        let denominator = minimumColumnWidth + gap
        guard denominator.isFinite, denominator > 0 else {
            return 1
        }
        let numerator = availableWidth + gap
        guard numerator.isFinite else {
            return maximumColumns
        }
        let rawCount = floor(numerator / denominator)
        guard rawCount.isFinite else {
            return maximumColumns
        }
        // Clamp before converting to Int. A very large finite ratio can be
        // outside Int's representable range even though the final policy is
        // capped by maximumColumns.
        guard rawCount < Double(maximumColumns) else {
            return maximumColumns
        }
        return max(Int(rawCount), 1)
    }

    static func modeForRequiredWidth(
        availableWidth: Double,
        requiredWidth: Double
    ) -> DetailRowLayoutMode {
        guard requiredWidth.isFinite else {
            return .stacked
        }
        if availableWidth == .infinity {
            return .inline
        }
        guard availableWidth.isFinite, availableWidth > 0 else {
            return .stacked
        }
        return availableWidth >= max(requiredWidth, 0)
            ? .inline
            : .stacked
    }

    /// Limits a child width to the space that remains after its leading
    /// siblings. Layout placement uses this helper so a borderline inline
    /// decision cannot place a child beyond the container's trailing edge.
    static func boundedInlineWidth(
        requestedWidth: Double,
        availableWidth: Double,
        leadingOffset: Double = 0
    ) -> Double {
        let requested: Double
        if requestedWidth == .infinity {
            requested = .infinity
        } else {
            requested = finiteNonNegative(requestedWidth)
        }
        guard availableWidth.isFinite else {
            guard availableWidth == .infinity, requested.isFinite else { return 0 }
            return requested
        }
        guard availableWidth > 0 else { return 0 }
        let offset = min(finiteNonNegative(leadingOffset), availableWidth)
        return min(requested, max(availableWidth - offset, 0))
    }

    private static func finiteNonNegative(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(value, 0)
    }
}

private struct AdaptiveDetailInfoRowLayout: Layout {
    private let labelFloor = CGFloat(DetailLayoutPolicy.defaultInfoLabelWidth)
    private let horizontalSpacing = CGFloat(DetailLayoutPolicy.infoRowSpacing)
    private let minimumValueWidth = CGFloat(DetailLayoutPolicy.minimumInfoValueWidth)
    private let verticalSpacing: CGFloat = 3

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count >= 2 else { return .zero }

        let labelIdeal = sanitizedSize(subviews[0].sizeThatFits(.unspecified))
        let valueIdeal = sanitizedSize(subviews[1].sizeThatFits(.unspecified))
        let width = resolvedWidth(
            proposal.width,
            labelIdeal: labelIdeal.width,
            valueIdeal: valueIdeal.width
        )
        let labelWidth = max(labelFloor, finiteNonNegative(labelIdeal.width))
        let mode = DetailLayoutPolicy.infoRowMode(
            availableWidth: Double(width),
            labelWidth: Double(labelWidth),
            minimumValueWidth: Double(minimumValueWidth),
            spacing: Double(horizontalSpacing)
        )

        switch mode {
        case .inline:
            let actualLabelWidth = min(
                labelWidth,
                max(labelFloor, width - horizontalSpacing - minimumValueWidth)
            )
            let valueWidth = DetailLayoutPolicy.boundedInlineWidth(
                requestedWidth: max(width - actualLabelWidth - horizontalSpacing, minimumValueWidth),
                availableWidth: Double(width),
                leadingOffset: Double(actualLabelWidth + horizontalSpacing)
            )
            let labelSize = sanitizedSize(subviews[0].sizeThatFits(
                ProposedViewSize(width: actualLabelWidth, height: nil)
            ))
            let valueSize = sanitizedSize(subviews[1].sizeThatFits(
                ProposedViewSize(width: valueWidth, height: nil)
            ))
            return CGSize(
                width: finiteProposedWidth(proposal.width) ?? width,
                height: max(labelSize.height, valueSize.height)
            )
        case .stacked:
            let labelSize = sanitizedSize(subviews[0].sizeThatFits(
                ProposedViewSize(width: width, height: nil)
            ))
            let valueSize = sanitizedSize(subviews[1].sizeThatFits(
                ProposedViewSize(width: width, height: nil)
            ))
            return CGSize(
                width: finiteProposedWidth(proposal.width) ?? width,
                height: labelSize.height + verticalSpacing + valueSize.height
            )
        }
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 2 else { return }

        let labelIdeal = sanitizedSize(subviews[0].sizeThatFits(.unspecified))
        let valueIdeal = sanitizedSize(subviews[1].sizeThatFits(.unspecified))
        let width = resolvedWidth(
            bounds.width,
            labelIdeal: labelIdeal.width,
            valueIdeal: valueIdeal.width
        )
        let labelWidth = max(labelFloor, finiteNonNegative(labelIdeal.width))
        let mode = DetailLayoutPolicy.infoRowMode(
            availableWidth: Double(width),
            labelWidth: Double(labelWidth),
            minimumValueWidth: Double(minimumValueWidth),
            spacing: Double(horizontalSpacing)
        )

        switch mode {
        case .inline:
            let actualLabelWidth = min(
                labelWidth,
                max(labelFloor, width - horizontalSpacing - minimumValueWidth)
            )
            let valueWidth = CGFloat(DetailLayoutPolicy.boundedInlineWidth(
                requestedWidth: max(width - actualLabelWidth - horizontalSpacing, minimumValueWidth),
                availableWidth: Double(width),
                leadingOffset: Double(actualLabelWidth + horizontalSpacing)
            ))
            let valueOrigin = min(
                bounds.maxX,
                bounds.minX + actualLabelWidth + horizontalSpacing
            )
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: actualLabelWidth, height: nil)
            )
            subviews[1].place(
                at: CGPoint(x: valueOrigin, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: valueWidth, height: nil)
            )
        case .stacked:
            let labelSize = sanitizedSize(subviews[0].sizeThatFits(
                ProposedViewSize(width: width, height: nil)
            ))
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: labelSize.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + labelSize.height + verticalSpacing),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: nil)
            )
        }
    }

    private func resolvedWidth(
        _ proposedWidth: CGFloat?,
        labelIdeal: CGFloat,
        valueIdeal: CGFloat
    ) -> CGFloat {
        if let proposedWidth, proposedWidth.isFinite {
            return max(proposedWidth, 0)
        }
        return max(
            labelFloor + horizontalSpacing + minimumValueWidth,
            finiteNonNegative(labelIdeal) + horizontalSpacing + finiteNonNegative(valueIdeal)
        )
    }
}

private struct AdaptiveDetailActionFlowLayout: Layout {
    private let spacing = CGFloat(DetailLayoutPolicy.actionSpacing)
    private let minimumButtonWidth = CGFloat(DetailLayoutPolicy.minimumActionButtonWidth)

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let idealSizes = subviews.map { sanitizedSize($0.sizeThatFits(.unspecified)) }
        let width = resolvedWidth(proposal.width, idealSizes: idealSizes)
        let buttonWidths = idealSizes.map { Double($0.width) }
        let requiredWidth = CGFloat(DetailLayoutPolicy.actionRequiredWidth(
            buttonWidths: buttonWidths,
            minimumButtonWidth: Double(minimumButtonWidth),
            spacing: Double(spacing)
        ))
        let mode = DetailLayoutPolicy.modeForRequiredWidth(
            availableWidth: Double(width),
            requiredWidth: Double(requiredWidth)
        )

        switch mode {
        case .inline:
            return CGSize(
                width: finiteProposedWidth(proposal.width) ?? width,
                height: idealSizes.map(\.height).max() ?? 0
            )
        case .stacked:
            let sizes = subviews.map {
                sanitizedSize($0.sizeThatFits(ProposedViewSize(width: width, height: nil)))
            }
            return CGSize(
                width: finiteProposedWidth(proposal.width) ?? width,
                height: sizes.reduce(0) { $0 + $1.height }
                    + spacing * CGFloat(max(sizes.count - 1, 0))
            )
        }
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }

        let idealSizes = subviews.map { sanitizedSize($0.sizeThatFits(.unspecified)) }
        let width = resolvedWidth(bounds.width, idealSizes: idealSizes)
        let buttonWidths = idealSizes.map { Double($0.width) }
        let requiredWidth = CGFloat(DetailLayoutPolicy.actionRequiredWidth(
            buttonWidths: buttonWidths,
            minimumButtonWidth: Double(minimumButtonWidth),
            spacing: Double(spacing)
        ))
        let mode = DetailLayoutPolicy.modeForRequiredWidth(
            availableWidth: Double(width),
            requiredWidth: Double(requiredWidth)
        )

        switch mode {
        case .inline:
            var x = bounds.minX
            for (index, subview) in subviews.enumerated() {
                let size = idealSizes[index]
                let leadingOffset = max(x - bounds.minX, 0)
                let width = CGFloat(DetailLayoutPolicy.boundedInlineWidth(
                    requestedWidth: Double(size.width),
                    availableWidth: Double(finiteNonNegative(bounds.width)),
                    leadingOffset: Double(leadingOffset)
                ))
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: nil)
                )
                x = min(
                    bounds.maxX,
                    x + width + min(spacing, max(bounds.maxX - x - width, 0))
                )
            }
        case .stacked:
            var y = bounds.minY
            for subview in subviews {
                let size = sanitizedSize(subview.sizeThatFits(ProposedViewSize(width: width, height: nil)))
                subview.place(
                    at: CGPoint(x: bounds.minX, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: size.height)
                )
                y += size.height + spacing
            }
        }
    }

    private func resolvedWidth(_ proposedWidth: CGFloat?, idealSizes: [CGSize]) -> CGFloat {
        if let proposedWidth, proposedWidth.isFinite {
            return max(proposedWidth, 0)
        }
        let buttonWidths = idealSizes.map { Double($0.width) }
        return CGFloat(DetailLayoutPolicy.actionRequiredWidth(
            buttonWidths: buttonWidths,
            minimumButtonWidth: Double(minimumButtonWidth),
            spacing: Double(spacing)
        ))
    }
}

/// Lays out metric tiles with a hard two-column ceiling.
///
/// `GridItem(.adaptive(...))` can create a third column when a detail sheet is
/// widened. The policy intentionally keeps these high-signal metrics in one
/// or two readable columns, so the layout computes the column count from the
/// same pure rule used by the tests.
private struct AdaptiveDetailMetricGridLayout: Layout {
    private let minimumColumnWidth = CGFloat(DetailLayoutPolicy.metricMinimumColumnWidth)
    private let spacing = CGFloat(DetailLayoutPolicy.metricSpacing)
    private let maximumColumns = 2

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let idealSizes = subviews.map { sanitizedSize($0.sizeThatFits(.unspecified)) }
        let width = resolvedWidth(proposal.width, idealSizes: idealSizes)
        let measurement = measure(width: width, idealSizes: idealSizes, subviews: subviews)
        return CGSize(
            width: finiteProposedWidth(proposal.width) ?? width,
            height: measurement.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let idealSizes = subviews.map { sanitizedSize($0.sizeThatFits(.unspecified)) }
        let measurement = measure(width: max(bounds.width, 0), idealSizes: idealSizes, subviews: subviews)
        var rowOrigins: [CGFloat] = []
        var y = bounds.minY
        for rowHeight in measurement.rowHeights {
            rowOrigins.append(y)
            y += rowHeight + spacing
        }

        for (index, subview) in subviews.enumerated() {
            let row = index / measurement.columns
            let column = index % measurement.columns
            let x = bounds.minX + CGFloat(column) * (measurement.columnWidth + spacing)
            let rowHeight = measurement.rowHeights[row]
            subview.place(
                at: CGPoint(x: x, y: rowOrigins[row]),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: measurement.columnWidth, height: rowHeight)
            )
        }
    }

    private struct Measurement {
        let columns: Int
        let columnWidth: CGFloat
        let spacing: CGFloat
        let rowHeights: [CGFloat]

        var height: CGFloat {
            rowHeights.reduce(0, +) + max(CGFloat(rowHeights.count - 1), 0) * spacing
        }
    }

    private func measure(
        width: CGFloat,
        idealSizes: [CGSize],
        subviews: Subviews
    ) -> Measurement {
        let safeWidth = width == .infinity
            ? resolvedWidth(nil, idealSizes: idealSizes)
            : finiteNonNegative(width)
        let columns = max(
            1,
            min(
                maximumColumns,
                DetailLayoutPolicy.metricColumnCount(
                    availableWidth: Double(safeWidth),
                    minimumColumnWidth: Double(minimumColumnWidth),
                    spacing: Double(spacing),
                    maximumColumns: min(maximumColumns, subviews.count)
                )
            )
        )
        let columnWidth = max(
            (safeWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns),
            0
        )
        let rowCount = (subviews.count + columns - 1) / columns
        var rowHeights = Array(repeating: CGFloat.zero, count: rowCount)
        for (index, subview) in subviews.enumerated() {
            let row = index / columns
            let size = sanitizedSize(subview.sizeThatFits(
                ProposedViewSize(width: columnWidth, height: nil)
            ))
            rowHeights[row] = max(rowHeights[row], size.height)
        }
        // A tile can report zero height while being measured with a zero-width
        // proposal. Preserve its minimum visual height in that pathological
        // case so a later placement cannot collapse the row.
        for index in rowHeights.indices where rowHeights[index] == 0 {
            let firstIndex = index * columns
            rowHeights[index] = max(
                idealSizes[firstIndex].height,
                54
            )
        }
        return Measurement(
            columns: columns,
            columnWidth: columnWidth,
            spacing: spacing,
            rowHeights: rowHeights
        )
    }

    private func resolvedWidth(_ proposedWidth: CGFloat?, idealSizes: [CGSize]) -> CGFloat {
        if let proposedWidth, proposedWidth.isFinite {
            return max(proposedWidth, 0)
        }
        let columns = min(maximumColumns, max(idealSizes.count, 1))
        let minimumWidth = minimumColumnWidth * CGFloat(columns)
            + spacing * CGFloat(max(columns - 1, 0))
        let idealWidth = idealSizes.map(\.width).reduce(0, +)
            + spacing * CGFloat(max(idealSizes.count - 1, 0))
        return max(minimumWidth, finiteNonNegative(idealWidth))
    }
}

struct AdaptiveDetailMetricGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        AdaptiveDetailMetricGridLayout {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func finiteProposedWidth(_ width: CGFloat?) -> CGFloat? {
    guard let width, width.isFinite else { return nil }
    return max(width, 0)
}

private func finiteNonNegative(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 0 }
    return max(value, 0)
}

private func sanitizedSize(_ size: CGSize) -> CGSize {
    CGSize(width: finiteNonNegative(size.width), height: finiteNonNegative(size.height))
}

struct AdaptiveDetailInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        AdaptiveDetailInfoRowLayout {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Text(value)
                .font(.caption)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .help(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(value)")
    }
}

private struct AdaptiveDetailRelationRowLayout: Layout {
    private let spacing = CGFloat(DetailLayoutPolicy.relationSpacing)
    private let spacerMinimumLength = CGFloat(DetailLayoutPolicy.relationSpacerMinimumLength)
    private let minimumNameWidth = CGFloat(DetailLayoutPolicy.minimumRelationValueWidth)
    private let verticalSpacing: CGFloat = 3

    private struct Measurement {
        let mode: DetailRowLayoutMode
        let labelWidth: CGFloat
        let nameWidth: CGFloat
        let trailingWidth: CGFloat
        let trailingOffset: CGFloat
        let verticalSpacing: CGFloat
        let labelHeight: CGFloat
        let nameHeight: CGFloat
        let trailingHeight: CGFloat

        var height: CGFloat {
            switch mode {
            case .inline:
                return max(labelHeight, max(nameHeight, trailingHeight))
            case .stacked:
                return max(labelHeight, trailingHeight) + verticalSpacing + nameHeight
            }
        }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count >= 3 else { return .zero }
        let idealSizes = idealSizes(for: subviews)
        let width = resolvedWidth(proposal.width, idealSizes: idealSizes)
        let measurement = measure(
            width: width,
            idealSizes: idealSizes,
            subviews: subviews
        )
        return CGSize(
            width: finiteProposedWidth(proposal.width) ?? width,
            height: measurement.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 3 else { return }
        let idealSizes = idealSizes(for: subviews)
        let measurement = measure(
            width: finiteNonNegative(bounds.width),
            idealSizes: idealSizes,
            subviews: subviews
        )
        let minX = bounds.minX
        let maxX = bounds.maxX

        switch measurement.mode {
        case .inline:
            let nameX = min(
                maxX,
                minX + measurement.labelWidth + spacing
            )
            let trailingX = min(
                maxX,
                max(minX, minX + measurement.trailingOffset)
            )
            subviews[0].place(
                at: CGPoint(x: minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: measurement.labelWidth, height: nil)
            )
            subviews[1].place(
                at: CGPoint(x: nameX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: measurement.nameWidth, height: nil)
            )
            subviews[2].place(
                at: CGPoint(x: trailingX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: measurement.trailingWidth, height: nil)
            )
        case .stacked:
            let trailingX = min(
                maxX,
                max(minX, minX + measurement.trailingOffset)
            )
            let topHeight = max(measurement.labelHeight, measurement.trailingHeight)
            subviews[0].place(
                at: CGPoint(x: minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: measurement.labelWidth, height: nil)
            )
            subviews[2].place(
                at: CGPoint(x: trailingX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: measurement.trailingWidth, height: nil)
            )
            subviews[1].place(
                at: CGPoint(x: minX, y: bounds.minY + topHeight + verticalSpacing),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: measurement.nameWidth, height: nil)
            )
        }
    }

    private func idealSizes(for subviews: Subviews) -> [CGSize] {
        subviews.prefix(3).map { sanitizedSize($0.sizeThatFits(.unspecified)) }
    }

    private func measure(
        width: CGFloat,
        idealSizes: [CGSize],
        subviews: Subviews
    ) -> Measurement {
        let safeWidth = finiteNonNegative(width)
        let labelIdeal = idealSizes[0].width
        let nameIdeal = max(idealSizes[1].width, minimumNameWidth)
        let trailingIdeal = idealSizes[2].width
        let metrics = DetailRelationMetrics(
            labelWidth: Double(labelIdeal),
            nameWidth: Double(nameIdeal),
            trailingWidth: Double(trailingIdeal),
            spacing: Double(spacing),
            spacerMinimumLength: Double(spacerMinimumLength),
            minimumNameWidth: Double(minimumNameWidth)
        )
        let mode = DetailLayoutPolicy.relationRowMode(
            availableWidth: Double(safeWidth),
            metrics: metrics
        )

        switch mode {
        case .inline:
            let widths = inlineWidths(
                availableWidth: safeWidth,
                labelWidth: labelIdeal,
                nameWidth: nameIdeal,
                trailingWidth: trailingIdeal
            )
            let labelSize = sanitizedSize(subviews[0].sizeThatFits(
                ProposedViewSize(width: widths.label, height: nil)
            ))
            let nameSize = sanitizedSize(subviews[1].sizeThatFits(
                ProposedViewSize(width: widths.name, height: nil)
            ))
            let trailingSize = sanitizedSize(subviews[2].sizeThatFits(
                ProposedViewSize(width: widths.trailing, height: nil)
            ))
            return Measurement(
                mode: mode,
                labelWidth: widths.label,
                nameWidth: widths.name,
                trailingWidth: widths.trailing,
                trailingOffset: max(safeWidth - widths.trailing, 0),
                verticalSpacing: verticalSpacing,
                labelHeight: labelSize.height,
                nameHeight: nameSize.height,
                trailingHeight: trailingSize.height
            )
        case .stacked:
            let trailingWidth = CGFloat(DetailLayoutPolicy.boundedInlineWidth(
                requestedWidth: Double(trailingIdeal),
                availableWidth: Double(safeWidth)
            ))
            let labelBudget = max(safeWidth - trailingWidth - spacing, 0)
            let labelWidth = min(labelIdeal, labelBudget)
            let labelSize = sanitizedSize(subviews[0].sizeThatFits(
                ProposedViewSize(width: labelWidth, height: nil)
            ))
            let trailingSize = sanitizedSize(subviews[2].sizeThatFits(
                ProposedViewSize(width: trailingWidth, height: nil)
            ))
            let nameSize = sanitizedSize(subviews[1].sizeThatFits(
                ProposedViewSize(width: safeWidth, height: nil)
            ))
            return Measurement(
                mode: mode,
                labelWidth: labelWidth,
                nameWidth: safeWidth,
                trailingWidth: trailingWidth,
                trailingOffset: max(safeWidth - trailingWidth, 0),
                verticalSpacing: verticalSpacing,
                labelHeight: labelSize.height,
                nameHeight: nameSize.height,
                trailingHeight: trailingSize.height
            )
        }
    }

    private func inlineWidths(
        availableWidth: CGFloat,
        labelWidth: CGFloat,
        nameWidth: CGFloat,
        trailingWidth: CGFloat
    ) -> (label: CGFloat, name: CGFloat, trailing: CGFloat) {
        let safeWidth = finiteNonNegative(availableWidth)
        let safeSpacing = finiteNonNegative(spacing)
        let fixedGaps = safeSpacing * CGFloat(DetailLayoutPolicy.relationGapCount)
            + finiteNonNegative(spacerMinimumLength)
        let safeTrailing = min(finiteNonNegative(trailingWidth), safeWidth)
        let safeName = min(
            finiteNonNegative(nameWidth),
            max(safeWidth - safeTrailing - fixedGaps, 0)
        )
        let safeLabel = min(
            finiteNonNegative(labelWidth),
            max(safeWidth - safeName - safeTrailing - fixedGaps, 0)
        )
        return (safeLabel, safeName, safeTrailing)
    }

    private func resolvedWidth(_ proposedWidth: CGFloat?, idealSizes: [CGSize]) -> CGFloat {
        if let proposedWidth, proposedWidth.isFinite {
            return max(proposedWidth, 0)
        }
        let metrics = DetailRelationMetrics(
            labelWidth: Double(idealSizes[0].width),
            nameWidth: Double(idealSizes[1].width),
            trailingWidth: Double(idealSizes[2].width),
            spacing: Double(spacing),
            spacerMinimumLength: Double(spacerMinimumLength),
            minimumNameWidth: Double(minimumNameWidth)
        )
        let required = DetailLayoutPolicy.relationRequiredWidth(metrics: metrics)
        if required.isFinite {
            return CGFloat(max(required, 0))
        }
        return minimumNameWidth + spacing * CGFloat(DetailLayoutPolicy.relationGapCount)
            + spacerMinimumLength
    }
}

struct AdaptiveDetailRelationRow: View {
    let label: String
    let name: String
    let trailing: String

    var body: some View {
        AdaptiveDetailRelationRowLayout {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Text(trailing)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(name)，\(trailing)")
    }
}

struct AdaptiveDetailMemberRow: View {
    let name: String
    let subtitle: String
    let footprint: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(footprint)
                    .font(.caption.monospacedDigit())
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(footprint)
                        .font(.caption.monospacedDigit())
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name)，\(subtitle)，\(footprint)")
    }
}

struct AdaptiveDetailAuditRow: View {
    let action: String
    let process: String
    let status: String
    let timestamp: Date
    let statusColor: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(action)
                    .font(.caption2.weight(.medium))
                    .fixedSize(horizontal: true, vertical: false)
                Text(process)
                    .font(.caption2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: true, vertical: false)
                Text(timestamp, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(action)
                        .font(.caption2.weight(.medium))
                    Spacer(minLength: 4)
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(process)
                        .font(.caption2)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(timestamp, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AdaptiveDetailActionGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        AdaptiveDetailActionFlowLayout {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
