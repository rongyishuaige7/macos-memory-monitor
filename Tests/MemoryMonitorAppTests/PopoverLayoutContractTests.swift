import AppKit
import SwiftUI
import XCTest
@testable import MemoryMonitorApp

@MainActor
final class PopoverLayoutContractTests: XCTestCase {
    func testProductionDefaultsAreFiniteAndMatchPopoverWidth() {
        let policy = MonitorPopoverLayoutPolicy.default

        XCTAssertEqual(MonitorPopoverLayoutPolicy.defaultWidth, 410)
        XCTAssertEqual(policy.width, MonitorPopoverLayoutPolicy.defaultWidth)
        XCTAssertEqual(policy.maxHeight, MonitorPopoverLayoutPolicy.defaultMaxHeight)
        XCTAssertEqual(policy.contentMaxHeight, MonitorPopoverLayoutPolicy.defaultContentMaxHeight)
        XCTAssertTrue(policy.maxHeight.isFinite)
        XCTAssertTrue(policy.contentMaxHeight.isFinite)
        XCTAssertGreaterThan(policy.minimumPopoverHeight, MonitorPopoverLayoutPolicy.minimumFooterHeight)
    }

    func testConfigurationDimensionsFallBackWhenInvalid() {
        let policy = MonitorPopoverLayoutPolicy(
            width: .nan,
            maxHeight: .infinity,
            contentMaxHeight: -20
        )

        XCTAssertEqual(policy.width, MonitorPopoverLayoutPolicy.defaultWidth)
        XCTAssertEqual(policy.maxHeight, MonitorPopoverLayoutPolicy.defaultMaxHeight)
        XCTAssertEqual(policy.contentMaxHeight, MonitorPopoverLayoutPolicy.defaultContentMaxHeight)

        let negative = MonitorPopoverLayoutPolicy(width: -1, maxHeight: -.infinity, contentMaxHeight: .nan)
        XCTAssertEqual(negative, .default)

        let undersizedContent = MonitorPopoverLayoutPolicy(contentMaxHeight: 1)
        XCTAssertEqual(undersizedContent.contentMaxHeight, MonitorPopoverLayoutPolicy.minimumContentHeight)
    }

    func testCentralHeightSubtractsReservedAreaAndHonorsContentCap() {
        let policy = MonitorPopoverLayoutPolicy(
            maxHeight: 600,
            contentMaxHeight: 300
        )
        let reserved = 200.0

        XCTAssertEqual(
            policy.centralScrollHeight(availableHeight: 550, reservedHeight: reserved),
            300
        )
        XCTAssertEqual(
            policy.centralScrollHeight(availableHeight: 350, reservedHeight: reserved),
            150
        )
        XCTAssertEqual(
            policy.centralScrollHeight(availableHeight: 150, reservedHeight: reserved),
            0
        )
        XCTAssertEqual(
            policy.centralScrollHeight(viewportHeight: .infinity, reservedHeight: reserved),
            300
        )
        XCTAssertEqual(policy.contentViewportHeight, 300)

        let undersized = MonitorPopoverLayoutPolicy(maxHeight: 1)
        XCTAssertEqual(undersized.contentViewportHeight, MonitorPopoverLayoutPolicy.minimumContentHeight)
    }

    func testStaticContentHeightUsesChromeCapAndCleansInvalidInputs() {
        XCTAssertEqual(
            MonitorPopoverLayoutPolicy.contentHeight(
                maxHeight: 600,
                chromeHeight: 170,
                minimum: 180
            ),
            430
        )
        XCTAssertEqual(
            MonitorPopoverLayoutPolicy.contentHeight(
                maxHeight: 200,
                chromeHeight: 170,
                minimum: 180
            ),
            180
        )

        for value in [Double.nan, Double.infinity, -Double.infinity, -10] {
            let height = MonitorPopoverLayoutPolicy.contentHeight(
                maxHeight: value,
                chromeHeight: value,
                minimum: value
            )
            XCTAssertTrue(height.isFinite)
            XCTAssertGreaterThanOrEqual(height, MonitorPopoverLayoutPolicy.minimumContentHeight)
        }
    }

    func testTotalHeightCapsLongContentAndKeepsFooterBaselineReachable() {
        let policy = MonitorPopoverLayoutPolicy(
            maxHeight: 600,
            contentMaxHeight: 300
        )
        let reserved = 200.0

        XCTAssertEqual(policy.totalHeight(contentHeight: 120, reservedHeight: reserved), 320)
        XCTAssertEqual(policy.totalHeight(contentHeight: 1_000, reservedHeight: reserved), 500)
        XCTAssertEqual(policy.totalHeight(contentHeight: .infinity, reservedHeight: reserved), 500)
        XCTAssertGreaterThanOrEqual(
            policy.totalHeight(contentHeight: -20, reservedHeight: reserved),
            policy.minimumPopoverHeight
        )
        XCTAssertLessThanOrEqual(policy.totalHeight(contentHeight: .infinity), policy.maxHeight)

        let undersizedPopover = MonitorPopoverLayoutPolicy(maxHeight: 1)
        XCTAssertGreaterThanOrEqual(
            undersizedPopover.totalHeight(contentHeight: 0),
            undersizedPopover.minimumPopoverHeight
        )
    }

    func testInvalidRuntimeDimensionsRemainFiniteAndNonNegative() {
        let policy = MonitorPopoverLayoutPolicy.default
        let invalidValues: [Double] = [.nan, .infinity, -.infinity, -10]

        for value in invalidValues {
            let central = policy.centralScrollHeight(
                availableHeight: value,
                reservedHeight: value
            )
            let total = policy.totalHeight(
                contentHeight: value,
                reservedHeight: value
            )
            XCTAssertTrue(central.isFinite)
            XCTAssertGreaterThanOrEqual(central, 0)
            XCTAssertTrue(total.isFinite)
            XCTAssertGreaterThanOrEqual(total, policy.minimumPopoverHeight)
            XCTAssertLessThanOrEqual(total, policy.maxHeight)
        }
    }

    func testLongBodyIsCappedWhileFooterRemainsInMeasuredLayout() {
        let policy = MonitorPopoverLayoutPolicy(
            maxHeight: 600,
            contentMaxHeight: 300
        )
        let fixture = VStack(alignment: .leading, spacing: 14) {
            MonitorPopoverContentScroll(layout: policy) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<40, id: \.self) { index in
                        Text("长内容行 \(index) ")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Text("退出 Memory Monitor")
                .frame(maxWidth: .infinity, minHeight: MonitorPopoverLayoutPolicy.minimumFooterHeight)
                .accessibilityIdentifier("popover-footer")
        }
        .padding(16)
        .frame(width: CGFloat(policy.width), alignment: .topLeading)

        let hostingView = NSHostingView(rootView: fixture)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: CGFloat(policy.width),
            height: CGFloat(policy.maxHeight)
        )
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize

        XCTAssertEqual(fittingSize.width, CGFloat(policy.width), accuracy: 0.5)
        XCTAssertTrue(fittingSize.height.isFinite)
        XCTAssertGreaterThanOrEqual(
            fittingSize.height,
            CGFloat(32 + MonitorPopoverLayoutPolicy.minimumContentHeight
                + MonitorPopoverLayoutPolicy.minimumFooterHeight)
        )
        XCTAssertLessThanOrEqual(
            fittingSize.height,
            CGFloat(32 + policy.contentMaxHeight
                + MonitorPopoverLayoutPolicy.minimumFooterHeight
                + 14) + 1
        )
    }
}
