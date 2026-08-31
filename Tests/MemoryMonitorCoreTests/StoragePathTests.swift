import Foundation
import XCTest
@testable import MemoryMonitorCore

final class StoragePathTests: XCTestCase {
    func testDefaultStoreURLsUseTheResolvedRoot() {
        let root = MemoryMonitorStoragePaths.currentRootURL

        XCTAssertEqual(
            HistoryStore.defaultFileURL,
            MemoryMonitorStoragePaths.historyFileURL(root: root)
        )
        XCTAssertEqual(
            ProcessActionAuditStore.defaultFileURL,
            MemoryMonitorStoragePaths.auditFileURL(root: root)
        )
    }

    func testProductionDefaultRootKeepsTheExistingDirectoryName() {
        XCTAssertEqual(MemoryMonitorStoragePaths.defaultRootURL.lastPathComponent, "MemoryMonitor")
    }

    func testValidOverrideIsTrimmedAndStandardized() {
        let fallback = URL(fileURLWithPath: "/var/fallback/MemoryMonitor", isDirectory: true)
        let resolved = MemoryMonitorStoragePaths.rootURL(
            overridePath: "  /tmp/memory-monitor-ui-check/../isolated  ",
            fallbackRootURL: fallback
        )

        XCTAssertEqual(resolved.path, "/tmp/isolated")
        XCTAssertNotEqual(resolved, fallback)
    }

    func testEnvironmentResolutionOnlyUsesTheExplicitKey() {
        let fallback = URL(fileURLWithPath: "/var/fallback/MemoryMonitor", isDirectory: true)
        let environment = [
            MemoryMonitorStoragePaths.overrideEnvironmentKey: "/tmp/ui-check",
            "MEMORY_MONITOR_STORAGE_ROOT": "/tmp/ignored"
        ]

        XCTAssertEqual(
            MemoryMonitorStoragePaths.rootURL(
                environment: environment,
                fallbackRootURL: fallback
            ).path,
            "/tmp/ui-check"
        )
    }

    func testIsolatedRootRequiresACanonicalTemporaryBoundary() {
        let environment = [
            "TMPDIR": "/tmp",
            MemoryMonitorStoragePaths.overrideEnvironmentKey:
                "  /tmp/memory-monitor-ui-check/../paired  "
        ]
        let expected = URL(fileURLWithPath: "/tmp/paired", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        XCTAssertEqual(
            MemoryMonitorStoragePaths.isolatedRootURL(environment: environment),
            expected
        )

        let invalidValues: [String?] = [
            nil,
            "",
            "relative/path",
            "/",
            "/tmp",
            "/tmpish/child",
            "/tmp/../var/fallback",
            "/tmp/memory-monitor\nui-check"
        ]
        for value in invalidValues {
            var invalidEnvironment = environment
            invalidEnvironment[MemoryMonitorStoragePaths.overrideEnvironmentKey] = value
            XCTAssertNil(
                MemoryMonitorStoragePaths.isolatedRootURL(environment: invalidEnvironment),
                "isolated root should be rejected: \(String(describing: value))"
            )
        }
    }

    func testInvalidOverridesFallBackWithoutRedirectingTheStore() {
        let fallback = URL(fileURLWithPath: "/var/fallback/MemoryMonitor", isDirectory: true)
        let invalidValues: [String?] = [
            nil,
            "",
            "   \n\t",
            "relative/path",
            "~/Library/Application Support/MemoryMonitor",
            "/",
            "/../",
            "\u{0}/tmp"
        ]

        for value in invalidValues {
            XCTAssertEqual(
                MemoryMonitorStoragePaths.rootURL(
                    overridePath: value,
                    fallbackRootURL: fallback
                ),
                fallback,
                "override should fall back: \(String(describing: value))"
            )
        }
    }

    func testHistoryAndAuditFileNamesShareTheSameRoot() {
        let root = URL(fileURLWithPath: "/tmp/ui-check/run-1", isDirectory: true)

        XCTAssertEqual(
            MemoryMonitorStoragePaths.historyFileURL(root: root).path,
            "/tmp/ui-check/run-1/history.json"
        )
        XCTAssertEqual(
            MemoryMonitorStoragePaths.auditFileURL(root: root).path,
            "/tmp/ui-check/run-1/actions.jsonl"
        )
        XCTAssertEqual(
            MemoryMonitorStoragePaths.historyFileURL(root: root).deletingLastPathComponent(),
            MemoryMonitorStoragePaths.auditFileURL(root: root).deletingLastPathComponent()
        )
    }
}
