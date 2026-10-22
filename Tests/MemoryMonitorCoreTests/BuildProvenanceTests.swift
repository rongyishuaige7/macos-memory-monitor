import XCTest
@testable import MemoryMonitorCore

final class BuildProvenanceTests: XCTestCase {
    private func makeProvenance(
        revision: String = "abc1234",
        digest: String = String(repeating: "a", count: 64),
        checkoutState: CompatibilityCheckoutState = .clean
    ) -> BuildProvenance {
        BuildProvenance(
            sourceRevision: revision,
            checkoutState: checkoutState,
            buildInputsDigest: digest,
            productVersion: "1.4.2",
            productBuild: "142",
            architecture: "arm64",
            toolchainVersion: "Swift 6.0"
        )
    }

    func testValidProvenanceRoundTripsAndLoadsFromURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildProvenanceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("BuildProvenance.json")
        let provenance = makeProvenance()
        try JSONEncoder().encode(provenance).write(to: url)

        let loaded = try XCTUnwrap(BuildProvenance.load(from: url))
        XCTAssertEqual(loaded, provenance)
        XCTAssertTrue(loaded.isValid)
    }

    func testInvalidProvenanceIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildProvenanceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("BuildProvenance.json")

        for invalid in [
            makeProvenance(revision: "not-a-revision"),
            makeProvenance(digest: "short"),
            makeProvenance(checkoutState: .unknown)
        ] {
            try JSONEncoder().encode(invalid).write(to: url)
            XCTAssertNil(BuildProvenance.load(from: url))
        }
    }

    func testMissingProvenanceIsUnknown() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-provenance-" + UUID().uuidString + ".json")
        XCTAssertNil(BuildProvenance.load(from: url))
    }

    func testLegacyProductReportDecodesWithoutNewFields() throws {
        let json = """
        {
          "version": "1.4.1",
          "build": "141",
          "sourceRevision": "abcdef0",
          "checkoutState": "clean"
        }
        """
        let report = try JSONDecoder().decode(
            CompatibilityProductReport.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(report.version, "1.4.1")
        XCTAssertEqual(report.build, "141")
        XCTAssertEqual(report.sourceRevision, "abcdef0")
        XCTAssertEqual(report.checkoutState, .clean)
        XCTAssertNil(report.buildInputsDigest)
        XCTAssertNil(report.provenanceSource)
    }
}
