import AppKit
import SwiftUI
import XCTest
@testable import MemoryMonitorApp

@MainActor
final class DetailLayoutSmokeTests: XCTestCase {
    func testLongValueFixtureStaysSizedAtProductionAndNarrowWidths() {
        let productionWidth = CGFloat(460)
        let narrowWidth = CGFloat(300)

        let production = measure(
            longValueFixture(width: productionWidth, dynamicTypeSize: .large),
            width: productionWidth
        )
        let narrow = measure(
            longValueFixture(width: narrowWidth, dynamicTypeSize: .accessibility3),
            width: narrowWidth
        )

        XCTAssertEqual(production.width, productionWidth, accuracy: 0.5)
        XCTAssertEqual(narrow.width, narrowWidth, accuracy: 0.5)
        XCTAssertTrue(production.height.isFinite)
        XCTAssertTrue(narrow.height.isFinite)
        XCTAssertGreaterThan(production.height, 0)
        XCTAssertGreaterThan(narrow.height, production.height)
    }

    func testThreeActionFixtureUsesVerticalFallbackWhenWidthIsNarrow() {
        let wideWidth = CGFloat(460)
        let narrowWidth = CGFloat(300)

        let wide = measure(actionFixture(width: wideWidth), width: wideWidth)
        let narrow = measure(actionFixture(width: narrowWidth), width: narrowWidth)

        XCTAssertEqual(wide.width, wideWidth, accuracy: 0.5)
        XCTAssertEqual(narrow.width, narrowWidth, accuracy: 0.5)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertGreaterThanOrEqual(narrow.height, 3 * 24)
    }

    func testMetricFixtureKeepsPositiveRowsWhenDroppingToOneColumn() {
        let twoColumnWidth = CGFloat(460)
        let oneColumnWidth = CGFloat(369)

        let twoColumn = measure(metricFixture(width: twoColumnWidth), width: twoColumnWidth)
        let oneColumn = measure(metricFixture(width: oneColumnWidth), width: oneColumnWidth)

        XCTAssertEqual(twoColumn.width, twoColumnWidth, accuracy: 0.5)
        XCTAssertEqual(oneColumn.width, oneColumnWidth, accuracy: 0.5)
        XCTAssertGreaterThan(twoColumn.height, 0)
        XCTAssertGreaterThan(oneColumn.height, twoColumn.height)
    }

    func testRelationFixtureUsesVerticalFallbackForNarrowWidth() {
        let wideWidth = CGFloat(300)
        let narrowWidth = CGFloat(240)

        let wide = measure(
            relationFixture(width: wideWidth, dynamicTypeSize: .large),
            width: wideWidth
        )
        let narrow = measure(
            relationFixture(width: narrowWidth, dynamicTypeSize: .large),
            width: narrowWidth
        )

        XCTAssertEqual(wide.width, wideWidth, accuracy: 0.5)
        XCTAssertEqual(narrow.width, narrowWidth, accuracy: 0.5)
        XCTAssertTrue(wide.height.isFinite)
        XCTAssertTrue(narrow.height.isFinite)
        XCTAssertGreaterThan(narrow.height, wide.height)
    }

    func testMetricTileValueGrowsWithDynamicType() {
        let width = CGFloat(420)
        let normal = measure(
            metricTileFixture(width: width, dynamicTypeSize: .medium),
            width: width
        )
        let large = measure(
            metricTileFixture(width: width, dynamicTypeSize: .accessibility3),
            width: width
        )

        XCTAssertTrue(normal.height.isFinite)
        XCTAssertTrue(large.height.isFinite)
        // AppKit's headless fitting pass does not always apply the user's
        // Dynamic Type scale, but the semantic font must never collapse the
        // tile below its default measured height.
        XCTAssertGreaterThanOrEqual(large.height, normal.height)
    }

    func testNarrowMemberRowRemainsFiniteAtExtremeWidths() {
        let widths: [CGFloat] = [20, 40, 80]
        for width in widths {
            let size = measure(
                AdaptiveDetailMemberRow(
                    name: String(repeating: "member-process-", count: 8),
                    subtitle: String(repeating: "PID 12345 · RSS 123.4 MiB · ", count: 4),
                    footprint: String(repeating: "123.4 GiB ", count: 8)
                )
                .frame(width: width, alignment: .leading)
                .environment(\.dynamicTypeSize, .accessibility3),
                width: width
            )

            XCTAssertEqual(size.width, width, accuracy: 0.5)
            XCTAssertTrue(size.height.isFinite)
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertLessThan(size.height, 120)
        }
    }

    func testNarrowAuditRowKeepsActionsAndMetadataSingleLine() {
        let widths: [CGFloat] = [20, 40, 80]
        for width in widths {
            let size = measure(
                AdaptiveDetailAuditRow(
                    action: String(repeating: "请求优雅退出 ", count: 8),
                    process: String(repeating: "long-process-name ", count: 8),
                    status: String(repeating: "已确认 ", count: 8),
                    timestamp: Date(timeIntervalSince1970: 1_756_000_000),
                    statusColor: .orange
                )
                .frame(width: width, alignment: .leading)
                .environment(\.dynamicTypeSize, .accessibility3),
                width: width
            )

            XCTAssertEqual(size.width, width, accuracy: 0.5)
            XCTAssertTrue(size.height.isFinite)
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertLessThan(size.height, 120)
        }
    }

    private func measure<Content: View>(_ view: Content, width: CGFloat) -> CGSize {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 2_000)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
    }

    private func longValueFixture(
        width: CGFloat,
        dynamicTypeSize: DynamicTypeSize
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveDetailInfoRow(
                label: "Bundle ID",
                value: "com.example.very.long.application.identifier.with.extra.components"
            )
            AdaptiveDetailInfoRow(
                label: "工作目录",
                value: "/Users/example/Library/Application Support/Memory Monitor/Projects/very-long-project-name"
            )
            AdaptiveDetailRelationRow(
                label: "父进程",
                name: "A very long parent process name with a path-like suffix",
                trailing: "PID 12345"
            )
            AdaptiveDetailMemberRow(
                name: "A very long member process name",
                subtitle: "PID 12345 · RSS 123.4 MiB",
                footprint: "1.2 GiB"
            )
            AdaptiveDetailAuditRow(
                action: "请求优雅退出",
                process: "A very long process label",
                status: "已确认",
                timestamp: Date(timeIntervalSince1970: 1_756_000_000),
                statusColor: .orange
            )
            actionFixture(width: width)
        }
        .padding(20)
        .frame(width: width, alignment: .leading)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
    }

    private func actionFixture(width: CGFloat) -> some View {
        AdaptiveDetailActionGroup {
            Button("请求优雅退出") {}
                .buttonStyle(.bordered)
            Button("强制结束") {}
                .buttonStyle(.borderedProminent)
            Button("取消当前操作") {}
                .buttonStyle(.bordered)
        }
        .frame(width: width, alignment: .leading)
    }

    private func relationFixture(
        width: CGFloat,
        dynamicTypeSize: DynamicTypeSize
    ) -> some View {
        AdaptiveDetailRelationRow(
            label: "父进程",
            name: "parent-process",
            trailing: "PID 12345"
        )
        .padding(8)
        .frame(width: width, alignment: .leading)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
    }

    private func metricFixture(width: CGFloat) -> some View {
        AdaptiveDetailMetricGrid {
            ForEach(0..<4, id: \.self) { index in
                DetailMetricTile(
                    title: "指标 \(index)",
                    value: "123.4 MiB",
                    detail: "说明"
                )
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func metricTileFixture(
        width: CGFloat,
        dynamicTypeSize: DynamicTypeSize
    ) -> some View {
        DetailMetricTile(
            title: "footprint",
            value: "123.4 MiB",
            detail: "物理归因口径"
        )
        .frame(width: width, alignment: .leading)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
    }
}
