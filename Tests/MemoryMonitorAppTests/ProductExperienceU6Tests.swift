import XCTest
@testable import MemoryMonitorApp
@testable import MemoryMonitorCore

@MainActor
final class ProductExperienceU6Tests: XCTestCase {
    func testNavigationKeepsSessionContext() {
        let navigation = DesktopNavigation()
        navigation.processQuery = "helper"
        navigation.processSort = .cpu
        navigation.processIncludesSystem = true
        navigation.expandedProcessGroups = ["group"]
        navigation.historyHours = 24
        navigation.historyRangeInitialized = true

        XCTAssertEqual(navigation.processQuery, "helper")
        XCTAssertEqual(navigation.processSort, .cpu)
        XCTAssertTrue(navigation.processIncludesSystem)
        XCTAssertEqual(navigation.expandedProcessGroups, ["group"])
        XCTAssertEqual(navigation.historyHours, 24)
        XCTAssertTrue(navigation.historyRangeInitialized)
        XCTAssertEqual(DesktopPage.history.title, "历史")
    }

    func testSearchMatchesGroupMembersAndKeepsStableTieBreak() {
        let process = cleanupApp(1).process
        let group = WorkloadGroupSnapshot(
            id: "group", title: "Unrelated", processCount: 1,
            physicalFootprintBytes: process.physicalFootprintBytes,
            residentBytes: process.residentBytes,
            isSystem: false, representativeProcess: process.name,
            memberProcessIdentities: [process.identity]
        )
        let rows = DesktopPresentation.groupedProcesses(
            [group], processes: [process], query: "Test", includeSystem: true,
            sort: .memory, cpu: [:]
        )
        XCTAssertEqual(rows.map { $0.id }, ["group"])
        XCTAssertEqual(rows.first?.members.map(\.identity), [process.identity])
    }

    func testAppearanceFollowsSystemAndFallsBackForInvalidValues() {
        XCTAssertNil(DesktopAppearancePreference.colorScheme("system"))
        XCTAssertNil(DesktopAppearancePreference.colorScheme("unexpected"))
        XCTAssertEqual(DesktopAppearancePreference.colorScheme("dark"), .dark)
        XCTAssertEqual(DesktopAppearancePreference.colorScheme("light"), .light)
        XCTAssertTrue(DesktopAppearancePreference.isDark("dark") == true)
        XCTAssertFalse(DesktopAppearancePreference.isDark("light") == true)
        XCTAssertNil(DesktopAppearancePreference.isDark("system"))
    }
}
