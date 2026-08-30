import XCTest
@testable import MemoryMonitorApp

@MainActor
final class DetailLayoutContractTests: XCTestCase {
    func testContentWidthMatchesDetailWindowInsetsAndMinimums() {
        XCTAssertEqual(
            DetailLayoutPolicy.contentWidth(viewportWidth: 500, minimumContentWidth: 460),
            460
        )
        XCTAssertEqual(
            DetailLayoutPolicy.contentWidth(viewportWidth: 540, minimumContentWidth: 500),
            500
        )
        XCTAssertEqual(
            DetailLayoutPolicy.contentWidth(viewportWidth: 600, minimumContentWidth: 460),
            560
        )
        XCTAssertEqual(
            DetailLayoutPolicy.contentWidth(viewportWidth: 300, minimumContentWidth: 460),
            460
        )
        XCTAssertEqual(
            DetailLayoutPolicy.contentWidth(viewportWidth: .infinity, minimumContentWidth: 460),
            460
        )
        XCTAssertEqual(
            DetailLayoutPolicy.contentWidth(viewportWidth: .nan, minimumContentWidth: 460),
            460
        )
        XCTAssertEqual(
            DetailLayoutPolicy.contentWidth(
                viewportWidth: 500,
                minimumContentWidth: -10,
                horizontalInset: -20
            ),
            500
        )
    }

    func testRequiredWidthModeUsesAnExactBoundary() {
        let required = 238.0
        XCTAssertEqual(
            DetailLayoutPolicy.modeForRequiredWidth(
                availableWidth: required,
                requiredWidth: required
            ),
            .inline
        )
        XCTAssertEqual(
            DetailLayoutPolicy.modeForRequiredWidth(
                availableWidth: required - 0.01,
                requiredWidth: required
            ),
            .stacked
        )
        XCTAssertEqual(
            DetailLayoutPolicy.modeForRequiredWidth(
                availableWidth: required,
                requiredWidth: required
            ),
            .inline
        )
        XCTAssertEqual(
            DetailLayoutPolicy.modeForRequiredWidth(
                availableWidth: required + 0.01,
                requiredWidth: required
            ),
            .inline
        )
        XCTAssertEqual(
            DetailLayoutPolicy.modeForRequiredWidth(
                availableWidth: .infinity,
                requiredWidth: required
            ),
            .inline
        )
        XCTAssertEqual(
            DetailLayoutPolicy.modeForRequiredWidth(
                availableWidth: .infinity,
                requiredWidth: .nan
            ),
            .stacked
        )
        XCTAssertEqual(
            DetailLayoutPolicy.modeForRequiredWidth(
                availableWidth: .nan,
                requiredWidth: required
            ),
            .stacked
        )

        XCTAssertEqual(
            DetailLayoutPolicy.modeForRequiredWidth(
                availableWidth: 0,
                requiredWidth: 0
            ),
            .stacked
        )
        XCTAssertEqual(
            DetailLayoutPolicy.modeForRequiredWidth(
                availableWidth: 300,
                requiredWidth: .infinity
            ),
            .stacked
        )
    }

    func testInfoAndRelationContractsScaleWithLargeLabels() {
        let infoRequired = DetailLayoutPolicy.defaultInfoLabelWidth
            + DetailLayoutPolicy.infoRowSpacing
            + DetailLayoutPolicy.minimumInfoValueWidth
        XCTAssertEqual(
            DetailLayoutPolicy.infoRowMode(availableWidth: infoRequired),
            .inline
        )
        XCTAssertEqual(
            DetailLayoutPolicy.infoRowMode(
                availableWidth: 300,
                labelWidth: DetailLayoutPolicy.defaultInfoLabelWidth * 2
            ),
            .stacked
        )
        XCTAssertEqual(
            DetailLayoutPolicy.infoRowMode(
                availableWidth: 316,
                labelWidth: DetailLayoutPolicy.defaultInfoLabelWidth * 2
            ),
            .inline
        )

        let relationRequired = DetailLayoutPolicy.relationRequiredWidth(
            labelWidth: 52,
            nameWidth: 140,
            trailingWidth: 74
        )
        XCTAssertEqual(relationRequired, 294)
        XCTAssertEqual(
            DetailLayoutPolicy.relationRowMode(availableWidth: relationRequired - 0.01),
            .stacked
        )
        XCTAssertEqual(
            DetailLayoutPolicy.relationRowMode(availableWidth: relationRequired),
            .inline
        )
        XCTAssertEqual(
            DetailLayoutPolicy.relationRowMode(
                availableWidth: 360,
                leadingWidth: 90,
                trailingWidth: 100,
                minimumValueWidth: 180,
                spacing: 10
            ),
            .stacked
        )

        let measuredRequired = DetailLayoutPolicy.relationRequiredWidth(
            labelWidth: 64,
            nameWidth: 220,
            trailingWidth: 116,
            spacing: 10,
            spacerMinimumLength: 6
        )
        XCTAssertEqual(measuredRequired, 436)
        XCTAssertEqual(
            DetailLayoutPolicy.relationRowMode(
                availableWidth: measuredRequired - 0.01,
                labelWidth: 64,
                nameWidth: 220,
                trailingWidth: 116,
                spacing: 10,
                spacerMinimumLength: 6
            ),
            .stacked
        )
        XCTAssertEqual(
            DetailLayoutPolicy.relationRowMode(
                availableWidth: measuredRequired,
                labelWidth: 64,
                nameWidth: 220,
                trailingWidth: 116,
                spacing: 10,
                spacerMinimumLength: 6
            ),
            .inline
        )
        XCTAssertEqual(
            DetailLayoutPolicy.relationRequiredWidth(
                labelWidth: .nan,
                nameWidth: .infinity,
                trailingWidth: -10
            ),
            .infinity
        )
    }

    func testActionRequiredWidthUsesMeasuredButtonLabels() {
        XCTAssertEqual(
            DetailLayoutPolicy.actionRequiredWidth(buttonCount: 3),
            352
        )
        XCTAssertEqual(
            DetailLayoutPolicy.actionLayoutMode(availableWidth: 352 - 0.01, buttonCount: 3),
            .stacked
        )
        XCTAssertEqual(
            DetailLayoutPolicy.actionLayoutMode(availableWidth: 352, buttonCount: 3),
            .inline
        )
        XCTAssertEqual(
            DetailLayoutPolicy.actionRequiredWidth(
                buttonWidths: [90, 140, 160],
                minimumButtonWidth: 112,
                spacing: 8
            ),
            428
        )
        XCTAssertEqual(
            DetailLayoutPolicy.actionRequiredWidth(
                buttonWidths: [.nan, -20, 160],
                minimumButtonWidth: 112,
                spacing: -4
            ),
            384
        )
        XCTAssertEqual(
            DetailLayoutPolicy.actionRequiredWidth(buttonWidths: [.infinity, 100]),
            .infinity
        )
        XCTAssertEqual(
            DetailLayoutPolicy.actionRequiredWidth(buttonCount: 0),
            0
        )
        XCTAssertEqual(
            DetailLayoutPolicy.actionRequiredWidth(buttonCount: -3),
            0
        )
    }

    func testMetricColumnsStayAtOneUntilTheTwoColumnBoundary() {
        XCTAssertEqual(
            DetailLayoutPolicy.metricColumnCount(availableWidth: 369.99),
            1
        )
        XCTAssertEqual(
            DetailLayoutPolicy.metricColumnCount(availableWidth: 370),
            2
        )
        XCTAssertEqual(
            DetailLayoutPolicy.metricColumnCount(availableWidth: .infinity),
            2
        )
        XCTAssertEqual(
            DetailLayoutPolicy.metricColumnCount(availableWidth: .nan),
            1
        )
        XCTAssertEqual(
            DetailLayoutPolicy.metricColumnCount(
                availableWidth: 900,
                minimumColumnWidth: 200,
                spacing: 20,
                maximumColumns: 1
            ),
            1
        )
        XCTAssertEqual(
            DetailLayoutPolicy.metricColumnCount(
                availableWidth: 900,
                spacing: .nan
            ),
            1
        )
        XCTAssertEqual(
            DetailLayoutPolicy.metricColumnCount(
                availableWidth: .greatestFiniteMagnitude,
                minimumColumnWidth: .leastNonzeroMagnitude,
                spacing: .leastNonzeroMagnitude,
                maximumColumns: 2
            ),
            2
        )
        XCTAssertEqual(
            DetailLayoutPolicy.metricColumnCount(
                availableWidth: 900,
                minimumColumnWidth: 200,
                spacing: 20,
                maximumColumns: 3
            ),
            3
        )
        XCTAssertEqual(
            DetailLayoutPolicy.metricColumnCount(
                availableWidth: 900,
                minimumColumnWidth: 200,
                spacing: 20,
                maximumColumns: 0
            ),
            1
        )
    }

    func testBoundedInlineWidthNeverExceedsRemainingSpace() {
        XCTAssertEqual(
            DetailLayoutPolicy.boundedInlineWidth(
                requestedWidth: 100,
                availableWidth: 238,
                leadingOffset: 138
            ),
            100
        )
        XCTAssertEqual(
            DetailLayoutPolicy.boundedInlineWidth(
                requestedWidth: 101,
                availableWidth: 238,
                leadingOffset: 138
            ),
            100
        )
        XCTAssertEqual(
            DetailLayoutPolicy.boundedInlineWidth(
                requestedWidth: .infinity,
                availableWidth: 238,
                leadingOffset: 138
            ),
            100
        )
        XCTAssertEqual(
            DetailLayoutPolicy.boundedInlineWidth(
                requestedWidth: 100,
                availableWidth: .nan,
                leadingOffset: 0
            ),
            0
        )
    }
}
