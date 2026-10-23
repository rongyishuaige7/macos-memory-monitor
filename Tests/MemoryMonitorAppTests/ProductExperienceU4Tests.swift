import XCTest
@testable import MemoryMonitorApp
@testable import MemoryMonitorCore

@MainActor
final class ProductExperienceU4Tests: XCTestCase {
    func testAuthorizationSurvivesControllerRecreationWithDisplayMetadata() throws {
        let suite = "u4-auth-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = cleanupApp(1)
        let runtime = FakeCleanupRuntime()
        let first = SmartCleanupController(runtime: runtime, defaults: defaults)
        first.setAuthorized(app, true)

        let second = SmartCleanupController(runtime: runtime, defaults: defaults)
        XCTAssertTrue(second.isAuthorized(app))
        XCTAssertEqual(second.authorizationEntries.first?.displayName, app.name)
        XCTAssertEqual(second.authorizationEntries.first?.state, .notObserved)
    }

    func testNotRunningAuthorizationCanBeRevokedIndividually() throws {
        let suite = "u4-revoke-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = cleanupApp(1)
        let runtime = FakeCleanupRuntime()
        let controller = SmartCleanupController(runtime: runtime, defaults: defaults)
        controller.setAuthorized(app, true)
        let entry = try XCTUnwrap(controller.authorizationEntries.first)
        XCTAssertEqual(entry.state, .notObserved)

        controller.revoke(entry.authorization)
        XCTAssertFalse(controller.isAuthorized(app))
        XCTAssertTrue(controller.authorizationEntries.isEmpty)
        XCTAssertNil(defaults.data(forKey: "smartCleanup.authorizationMetadata.v1"))
    }

    func testIdentityChangedIsExplicitAndDoesNotInheritAuthorization() async throws {
        let suite = "u4-identity-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = cleanupApp(1)
        let changed = CleanupApplication(
            process: original.process,
            authorization: CleanupAuthorization(
                bundleIdentifier: original.authorization.bundleIdentifier,
                bundlePath: original.authorization.bundlePath,
                executablePath: original.authorization.executablePath,
                bundleInode: (original.authorization.bundleInode ?? 0) + 1,
                executableInode: original.authorization.executableInode
            )
        )
        let runtime = FakeCleanupRuntime()
        runtime.observations = [observation(changed)]
        let controller = SmartCleanupController(runtime: runtime, defaults: defaults)
        controller.setAuthorized(original, true)
        controller.refreshApplications()
        await controller.waitUntilRefreshed()

        let entry = try XCTUnwrap(controller.authorizationEntries.first)
        XCTAssertEqual(entry.state, .identityChanged)
        XCTAssertFalse(controller.isAuthorized(changed))
        XCTAssertEqual(controller.authorizationCounts.runningMatched, 0)
    }

    func testOldAuthorizationPreferenceLoadsWithoutMetadata() throws {
        let suite = "u4-old-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = cleanupApp(1)
        defaults.set(try JSONEncoder().encode([app.authorization]), forKey: "smartCleanup.authorizedApplications.v1")
        let controller = SmartCleanupController(runtime: FakeCleanupRuntime(), defaults: defaults)
        XCTAssertTrue(controller.isAuthorized(app))
        XCTAssertEqual(controller.authorizationEntries.first?.displayName, app.authorization.bundleIdentifier)
    }

    func testAuthorizationCountsKeepSavedRunningAndEligibleSeparate() async throws {
        let suite = "u4-counts-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = cleanupApp(1)
        let runtime = FakeCleanupRuntime()
        runtime.observations = [observation(app)]
        let controller = SmartCleanupController(runtime: runtime, defaults: defaults)
        controller.setAuthorized(app, true)
        controller.refreshApplications()
        await controller.waitUntilRefreshed()
        let counts = controller.authorizationCounts
        XCTAssertEqual(counts.total, 1)
        XCTAssertEqual(counts.runningMatched, 1)
        XCTAssertEqual(counts.eligible, 1)
    }
}
