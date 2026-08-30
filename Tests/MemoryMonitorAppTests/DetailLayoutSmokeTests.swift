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

    private func metricFixture(width: CGFloat) -> some View {
        AdaptiveDetailMetricGrid {
            ForEach(0..<4, id: \.self) { index in
                VStack(alignment: .leading, spacing: 3) {
                    Text("指标 \(index)")
                    Text("123.4 MiB")
                    Text("说明")
                }
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .padding(9)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .frame(width: width, alignment: .leading)
    }
}
