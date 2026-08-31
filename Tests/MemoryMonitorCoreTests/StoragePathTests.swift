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

    func testProductionIsolatedRootNeverUsesAnUntrustedTMPDIRAnchor() {
        let environment = [
            "TMPDIR": "/Users/example/persistent-data",
            MemoryMonitorStoragePaths.overrideEnvironmentKey:
                "/Users/example/persistent-data/fixture"
        ]

        XCTAssertNil(
            MemoryMonitorStoragePaths.isolatedRootURL(environment: environment)
        )

        var trustedEnvironment = environment
        trustedEnvironment[MemoryMonitorStoragePaths.overrideEnvironmentKey] =
            "/tmp/memory-monitor-ui-check/fixture"
        XCTAssertEqual(
            MemoryMonitorStoragePaths.isolatedRootURL(environment: trustedEnvironment)?.path,
            "/tmp/memory-monitor-ui-check/fixture"
        )
    }

    func testIsolatedRootAcceptsPhysicalDarwinTemporaryAliases() {
        let userTemporaryRoot = FileManager.default.temporaryDirectory.path
        let physicalUserTemporaryRoot = userTemporaryRoot.hasPrefix("/private/")
            ? userTemporaryRoot
            : "/private" + userTemporaryRoot
        for path in [
            "/private/tmp/memory-monitor-ui-check/fixture",
            physicalUserTemporaryRoot + "/memory-monitor-ui-check/fixture"
        ] {
            let expected = URL(fileURLWithPath: path, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            XCTAssertEqual(
                MemoryMonitorStoragePaths.isolatedRootURL(
                    environment: [
                        MemoryMonitorStoragePaths.overrideEnvironmentKey: path
                    ]
                ),
                expected,
                "physical temporary alias should resolve consistently: \(path)"
            )
        }
    }

    func testIsolatedRootIgnoresAnUntrustedTMPDIRAnchor() throws {
        let trustedRoot = "/var/folders/test-user/T"
        let trustedRoots = [trustedRoot, "/tmp"]
        let siblingEnvironment = [
            "TMPDIR": "/Users/example/memory-monitor",
            MemoryMonitorStoragePaths.overrideEnvironmentKey:
                "\(trustedRoot)/run/storage"
        ]

        XCTAssertEqual(
            MemoryMonitorStoragePaths.isolatedRootURL(
                environment: siblingEnvironment,
                trustedTemporaryRoots: trustedRoots
            )?.path,
            "\(trustedRoot)/run/storage"
        )

        let untrustedEnvironment = [
            "TMPDIR": "/Users/example/memory-monitor",
            MemoryMonitorStoragePaths.overrideEnvironmentKey:
                "/Users/example/memory-monitor/fixture"
        ]
        XCTAssertNil(
            MemoryMonitorStoragePaths.isolatedRootURL(
                environment: untrustedEnvironment,
                trustedTemporaryRoots: trustedRoots
            )
        )

        for value in [
            trustedRoot,
            "/tmp",
            "\(trustedRoot)ish/run/storage"
        ] {
            var invalidEnvironment = siblingEnvironment
            invalidEnvironment[MemoryMonitorStoragePaths.overrideEnvironmentKey] = value
            XCTAssertNil(
                MemoryMonitorStoragePaths.isolatedRootURL(
                    environment: invalidEnvironment,
                    trustedTemporaryRoots: trustedRoots
                ),
                "trusted root itself or a prefix collision must be rejected: \(value)"
            )
        }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMonitorTrustedRoot-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let inRootTarget = base.appendingPathComponent("in-root-target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inRootTarget,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let inRootLink = base.appendingPathComponent("in-root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: inRootLink,
            withDestinationURL: inRootTarget
        )
        XCTAssertNotNil(
            MemoryMonitorStoragePaths.isolatedRootURL(
                environment: [
                    MemoryMonitorStoragePaths.overrideEnvironmentKey:
                        inRootLink.appendingPathComponent("fixture", isDirectory: true).path
                ],
                trustedTemporaryRoots: [base.path]
            ),
            "Core may resolve a symlink when its target remains inside the trusted root"
        )

        let link = base.appendingPathComponent("outside-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: URL(fileURLWithPath: "/Users/example")
        )
        let symlinkEnvironment = [
            MemoryMonitorStoragePaths.overrideEnvironmentKey:
                link.appendingPathComponent("fixture", isDirectory: true).path
        ]
        XCTAssertNil(
            MemoryMonitorStoragePaths.isolatedRootURL(
                environment: symlinkEnvironment,
                trustedTemporaryRoots: [base.path]
            )
        )
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
