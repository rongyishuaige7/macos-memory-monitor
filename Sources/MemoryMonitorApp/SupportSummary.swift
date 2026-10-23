import Darwin
import Foundation
import MemoryMonitorCore

/// A deliberately small support artifact. It must never contain process
/// names, paths, PIDs, host names, raw logs, or user history content.
struct SupportSummary: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let productVersion: String
    let productBuild: String
    let operatingSystem: String
    let architecture: String
    let historyStatus: HistoryInspectionStatus
    let historyFormat: HistoryStorageFormat
    let recordCount: Int
    let segmentCount: Int
    let journalRecordCount: Int
    let issueCodes: [String]

    init(
        generatedAt: Date,
        productVersion: String,
        productBuild: String,
        operatingSystem: String,
        architecture: String,
        report: HistoryInspectionReport
    ) {
        self.schemaVersion = 1
        self.generatedAt = generatedAt
        self.productVersion = productVersion
        self.productBuild = productBuild
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.historyStatus = report.status
        self.historyFormat = report.format
        self.recordCount = report.recordCount
        self.segmentCount = report.segmentCount
        self.journalRecordCount = report.journalRecordCount
        self.issueCodes = report.issues.map(\.code).sorted()
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum SupportSummaryExporter {
    enum ExportError: Error, Equatable {
        case alreadyExists
        case writeFailed
    }

    static func write(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw ExportError.alreadyExists }
            throw ExportError.writeFailed
        }
        defer { close(descriptor) }
        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: written), data.count - written)
            }
            if result <= 0 {
                if errno == EINTR { continue }
                try? FileManager.default.removeItem(at: url)
                throw ExportError.writeFailed
            }
            written += result
        }
    }
}
