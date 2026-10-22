import Foundation

/// Immutable build metadata embedded in a signed app bundle before codesigning.
///
/// The provenance file is part of the artifact, not the invoking shell. A
/// report must therefore prefer this value over environment variables supplied
/// by the current checkout: an old bundle cannot be relabelled as a newer
/// commit merely by changing the caller's environment.
public struct BuildProvenance: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let resourceName = "BuildProvenance"

    public let schemaVersion: Int
    public let sourceRevision: String
    public let checkoutState: CompatibilityCheckoutState
    public let buildInputsDigest: String
    public let productVersion: String
    public let productBuild: String
    public let architecture: String
    public let toolchainVersion: String

    public init(
        schemaVersion: Int = BuildProvenance.currentSchemaVersion,
        sourceRevision: String,
        checkoutState: CompatibilityCheckoutState,
        buildInputsDigest: String,
        productVersion: String,
        productBuild: String,
        architecture: String,
        toolchainVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.sourceRevision = sourceRevision
        self.checkoutState = checkoutState
        self.buildInputsDigest = buildInputsDigest
        self.productVersion = productVersion
        self.productBuild = productBuild
        self.architecture = architecture
        self.toolchainVersion = toolchainVersion
    }

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              checkoutState == .clean || checkoutState == .modified,
              Self.isHex(sourceRevision, lengths: 7...64),
              Self.isHex(buildInputsDigest, lengths: 64...64),
              Self.isSafeText(productVersion, limit: 64),
              Self.isSafeText(productBuild, limit: 64),
              Self.isSafeText(architecture, limit: 32),
              Self.isSafeText(toolchainVersion, limit: 128) else {
            return false
        }
        return true
    }

    /// Reads the provenance file from the signed bundle. Missing, malformed,
    /// or partially forged files return nil so callers report an unknown
    /// source rather than trusting the caller's environment.
    public static func load(from bundle: Bundle = .main) -> BuildProvenance? {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: "json"
        ) else {
            return nil
        }
        return load(from: url)
    }

    /// Reads a provenance file from an explicit location. This is useful for
    /// verification tools and tests; production reports use the bundle
    /// overload so the file is covered by the app signature.
    public static func load(from url: URL) -> BuildProvenance? {
        guard let data = try? Data(contentsOf: url),
              data.count <= 64 * 1024,
              let decoded = try? JSONDecoder().decode(BuildProvenance.self, from: data),
              decoded.isValid else {
            return nil
        }
        return decoded
    }

    private static func isHex(_ value: String, lengths: ClosedRange<Int>) -> Bool {
        guard lengths.contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (0x30...0x39).contains(scalar.value)
                || (0x41...0x46).contains(scalar.value)
                || (0x61...0x66).contains(scalar.value)
        }
    }

    private static func isSafeText(_ value: String, limit: Int) -> Bool {
        guard !value.isEmpty, value.count <= limit else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value)
        }
    }
}
