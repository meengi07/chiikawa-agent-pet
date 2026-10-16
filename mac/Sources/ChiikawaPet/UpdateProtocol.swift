import CryptoKit
import Foundation

struct ReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: UInt16
    let minor: UInt16
    let patch: UInt16
    var description: String { "\(major).\(minor).\(patch)" }

    init(_ text: String) throws {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { throw UpdateFailure("Invalid release version.") }
        var numbers: [UInt16] = []
        for component in components {
            guard !component.isEmpty, component.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  component.count == 1 || component.first != "0", let number = UInt16(component) else {
                throw UpdateFailure("Invalid release version.")
            }
            numbers.append(number)
        }
        major = numbers[0]; minor = numbers[1]; patch = numbers[2]
    }

    static func < (left: Self, right: Self) -> Bool {
        if left.major != right.major { return left.major < right.major }
        if left.minor != right.minor { return left.minor < right.minor }
        return left.patch < right.patch
    }
}

struct UpdateFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ReleaseAsset: Codable, Sendable {
    let name: String
    let url: String
    let sha256: String
    let size: Int64
}

struct ReleaseManifest: Codable, Sendable {
    let schemaVersion: Int
    let version: String
    let assets: [ReleaseAsset]
}

struct GitHubRelease: Decodable, Sendable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool

    func stableVersion() throws -> ReleaseVersion {
        guard !draft, !prerelease, tag_name.hasPrefix("v") else {
            throw UpdateFailure("The latest release is not a stable release.")
        }
        return try ReleaseVersion(String(tag_name.dropFirst()))
    }
}

enum UpdateTrust {
    static let maximumPackageSize: Int64 = 512 * 1024 * 1024
    static let releaseRoot = "https://github.com/meengi07/chiikawa-agent-pet/releases/download/"
    static let bundleIdentifier = "local.chiikawa.agent-pet"
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }

    static func allowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host else { return false }
        return ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host)
    }

    static func canonicalURL(version: ReleaseVersion, name: String) -> URL {
        URL(string: "\(releaseRoot)v\(version)/\(name)")!
    }

    static func verifiedAsset(manifest: Data, signature: Data, publicKey: String,
                              version: ReleaseVersion, architecture: String = architecture) throws -> ReleaseAsset {
        guard manifest.count <= 65_536, signature.count <= 2048,
              let signatureText = String(data: signature, encoding: .utf8) else {
            throw UpdateFailure("The update manifest is too large or malformed.")
        }
        let compactSignature = signatureText.filter { !$0.isWhitespace }
        guard let signatureBytes = Data(base64Encoded: compactSignature) else {
            throw UpdateFailure("The update signature is malformed.")
        }
        let key = try P256.Signing.PublicKey(pemRepresentation: publicKey)
        let signed = try P256.Signing.ECDSASignature(derRepresentation: signatureBytes)
        guard key.isValidSignature(signed, for: manifest) else {
            throw UpdateFailure("Update signature verification failed. The current app has not been changed.")
        }
        let decoded = try JSONDecoder().decode(ReleaseManifest.self, from: manifest)
        guard decoded.schemaVersion == 1, decoded.version == version.description else {
            throw UpdateFailure("The signed manifest does not match this release.")
        }
        var names = Set<String>()
        for asset in decoded.assets {
            guard names.insert(asset.name).inserted else { throw UpdateFailure("Duplicate update asset names.") }
        }
        guard ["arm64", "x86_64"].contains(architecture) else {
            throw UpdateFailure("Automatic installation is not supported on this Mac architecture.")
        }
        let name = "ChiikawaPet-\(version)-mac-\(architecture).dmg"
        guard let asset = decoded.assets.first(where: { $0.name == name }),
              asset.url == canonicalURL(version: version, name: name).absoluteString,
              asset.sha256.count == 64,
              asset.sha256.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }),
              asset.size > 0, asset.size <= maximumPackageSize else {
            throw UpdateFailure("The signed release does not contain a valid package for this Mac.")
        }
        return asset
    }

    static func fileDigest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyPackage(_ file: URL, asset: ReleaseAsset) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == asset.size else {
            throw UpdateFailure("The downloaded package has the wrong size.")
        }
        let digest = try fileDigest(file)
        guard digest == asset.sha256 else { throw UpdateFailure("The downloaded package failed SHA-256 verification.") }
    }

    static func validateTarget(_ target: URL) throws {
        guard target.isFileURL, target.pathExtension == "app", target.path == target.standardizedFileURL.path,
              target.path == target.resolvingSymlinksInPath().path,
              !target.path.hasPrefix("/Volumes/"), !target.path.contains("/AppTranslocation/") else {
            throw UpdateFailure("Move ChiikawaPet.app to a writable Applications folder, then check again.")
        }
        let parent = target.deletingLastPathComponent()
        let keys: Set<URLResourceKey> = [.volumeIsReadOnlyKey, .isWritableKey]
        let volume = try parent.resourceValues(forKeys: keys)
        guard volume.volumeIsReadOnly != true, FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: target.path) else {
            throw UpdateFailure("The app folder is read-only. Move the app to a folder you can write, then retry.")
        }
    }

    static func appVersion(_ app: URL) throws -> ReleaseVersion {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        let bytes = try Data(contentsOf: infoURL)
        let info = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier,
              info?["CFBundleExecutable"] as? String == "ChiikawaPet",
              let version = info?["CFBundleShortVersionString"] as? String else {
            throw UpdateFailure("The app bundle identity is invalid.")
        }
        return try ReleaseVersion(version)
    }

    static func bundledKey(in app: URL) throws -> String {
        let key = app.appendingPathComponent("Contents/Resources/ChiikawaPet_ChiikawaPet.bundle/UPDATE_PUBLIC_KEY")
        return try String(contentsOf: key, encoding: .utf8)
    }
}
