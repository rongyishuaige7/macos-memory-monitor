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
                    .padding(20)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func resolvedContentWidth(_ viewportWidth: CGFloat) -> CGFloat {
        guard viewportWidth.isFinite, viewportWidth > 0 else {
            return max(minimumContentWidth, 0)
        }
        return max(minimumContentWidth, viewportWidth - 40)
    }
}

enum DetailRowLayoutMode: String, Equatable, Sendable {
    case inline
    case stacked
}

/// Pure sizing decisions shared by the detail layouts and their tests.
/// Keeping the thresholds here prevents each row from inventing a different
/// definition of "too narrow".
enum DetailLayoutPolicy {
    static let defaultInfoLabelWidth: Double = 78
    static let infoRowSpacing: Double = 10
    static let minimumInfoValueWidth: Double = 150
    static let relationSpacing: Double = 8
    static let minimumRelationValueWidth: Double = 140
    static let actionSpacing: Double = 8
    static let minimumActionButtonWidth: Double = 112
    static let metricMinimumColumnWidth: Double = 180
    static let metricSpacing: Double = 10

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
        modeForRequiredWidth(
            availableWidth: availableWidth,
            requiredWidth: max(leadingWidth, 0)
                + max(trailingWidth, 0)
                + max(minimumValueWidth, 0)
                + max(spacing, 0) * 2
        )
    }

    static func actionLayoutMode(
        availableWidth: Double,
        buttonCount: Int,
        minimumButtonWidth: Double = minimumActionButtonWidth,
        spacing: Double = actionSpacing
    ) -> DetailRowLayoutMode {
        guard buttonCount > 0 else { return .inline }
        let count = Double(buttonCount)
        return modeForRequiredWidth(
            availableWidth: availableWidth,
            requiredWidth: count * max(minimumButtonWidth, 0)
                + max(count - 1, 0) * max(spacing, 0)
        )
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
        guard availableWidth > 0, minimumColumnWidth > 0 else {
            return 1
        }
        let count = Int(floor((availableWidth + max(spacing, 0))
            / (minimumColumnWidth + max(spacing, 0))))
        return min(max(count, 1), maximumColumns)
    }

    static func modeForRequiredWidth(
        availableWidth: Double,
        requiredWidth: Double
    ) -> DetailRowLayoutMode {
        if availableWidth == .infinity {
            return .inline
        }
        guard availableWidth.isFinite, availableWidth > 0,
              requiredWidth.isFinite else {
            return .stacked
        }
        return availableWidth + 0.5 >= max(requiredWidth, 0)
            ? .inline
            : .stacked
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
            let valueWidth = max(width - actualLabelWidth - horizontalSpacing, minimumValueWidth)
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
            let valueWidth = max(width - actualLabelWidth - horizontalSpacing, minimumValueWidth)
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: actualLabelWidth, height: nil)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + actualLabelWidth + horizontalSpacing, y: bounds.minY),
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
        let requiredWidth = idealSizes.reduce(0) { $0 + max($1.width, minimumButtonWidth) }
            + spacing * CGFloat(max(subviews.count - 1, 0))
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
        let requiredWidth = idealSizes.reduce(0) { $0 + max($1.width, minimumButtonWidth) }
            + spacing * CGFloat(max(subviews.count - 1, 0))
        let mode = DetailLayoutPolicy.modeForRequiredWidth(
            availableWidth: Double(width),
            requiredWidth: Double(requiredWidth)
        )

        switch mode {
        case .inline:
            var x = bounds.minX
            for (index, subview) in subviews.enumerated() {
                let size = idealSizes[index]
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: nil)
                )
                x += size.width + spacing
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
        return idealSizes.reduce(0) { $0 + max(finiteNonNegative($1.width), minimumButtonWidth) }
            + spacing * CGFloat(max(idealSizes.count - 1, 0))
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
        let safeWidth = finiteNonNegative(width)
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

struct AdaptiveDetailRelationRow: View {
    let label: String
    let name: String
    let trailing: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: DetailLayoutPolicy.relationSpacing) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: CGFloat(DetailLayoutPolicy.minimumRelationValueWidth), alignment: .leading)
                Spacer(minLength: 4)
                Text(trailing)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(trailing)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(name)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
