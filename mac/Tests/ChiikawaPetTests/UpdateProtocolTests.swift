import CryptoKit
import Foundation
import Testing
@testable import ChiikawaPet

struct UpdateProtocolTests {
    @Test @MainActor func optingOutStopsAutomaticApplyButNotManualInstallation() {
        let updates = UpdateController(preview: false)
        updates.configureAutomatic(true, checkImmediately: false)
        #expect(updates.allowsInstallation(automatic: true))
        updates.configureAutomatic(false, checkImmediately: false)
        #expect(!updates.allowsInstallation(automatic: true))
        #expect(updates.allowsInstallation(automatic: false))
        let preview = UpdateController(preview: true)
        preview.configureAutomatic(true, checkImmediately: false)
        #expect(!preview.allowsInstallation(automatic: true))
        #expect(!preview.allowsInstallation(automatic: false))
    }

    @Test(arguments: ["1.2", "01.2.3", "1.02.3", "1.2.03", "1.2.65536", "1.2.3-beta", "v1.2.3", "1.2.3\n", "-1.2.3", "1..3"])
    func rejectsMalformedVersions(_ text: String) {
        #expect(throws: (any Error).self) { try ReleaseVersion(text) }
    }

    @Test func comparesNumericallyAndRejectsUnstableTags() throws {
        #expect(try ReleaseVersion("1.10.0") > ReleaseVersion("1.9.99"))
        #expect(try ReleaseVersion("2.0.0") > ReleaseVersion("1.65535.65535"))
        #expect(throws: (any Error).self) { try GitHubRelease(tag_name: "v1.2.3", draft: true, prerelease: false).stableVersion() }
        #expect(throws: (any Error).self) { try GitHubRelease(tag_name: "v1.2.3", draft: false, prerelease: true).stableVersion() }
        #expect(throws: (any Error).self) { try GitHubRelease(tag_name: "1.2.3", draft: false, prerelease: false).stableVersion() }
    }

    @Test func signatureCoversOriginalBytesAndPinnedKey() throws {
        let signer = P256.Signing.PrivateKey()
        let version = try ReleaseVersion("1.2.0")
        let manifest = try fixtureManifest()
        let signature = try signer.signature(for: manifest).derRepresentation.base64EncodedData()
        let asset = try UpdateTrust.verifiedAsset(manifest: manifest, signature: signature, publicKey: signer.publicKey.pemRepresentation, version: version)
        #expect(asset.name == "ChiikawaPet-1.2.0-mac-\(UpdateTrust.architecture).dmg")
        var modified = manifest
        modified.append(0x20)
        #expect(throws: (any Error).self) {
            try UpdateTrust.verifiedAsset(manifest: modified, signature: signature, publicKey: signer.publicKey.pemRepresentation, version: version)
        }
        let otherKey = P256.Signing.PrivateKey()
        #expect(throws: (any Error).self) {
            try UpdateTrust.verifiedAsset(manifest: manifest, signature: signature, publicKey: otherKey.publicKey.pemRepresentation, version: version)
        }
        #expect(throws: (any Error).self) {
            try UpdateTrust.verifiedAsset(manifest: manifest, signature: signature, publicKey: signer.publicKey.pemRepresentation, version: ReleaseVersion("1.2.1"))
        }
    }

    @Test func rejectsSignedDuplicateNamesAndNoncanonicalAssetPaths() throws {
        let signer = P256.Signing.PrivateKey()
        let version = try ReleaseVersion("1.2.0")
        for manifest in [try fixtureManifest(duplicate: true), try fixtureManifest(url: "https://evil.example/package.dmg"),
                         try fixtureManifest(url: "https://github.com/meengi07/chiikawa-agent-pet/releases/download/v1.2.0/../package.dmg")] {
            let signature = try signer.signature(for: manifest).derRepresentation.base64EncodedData()
            #expect(throws: (any Error).self) {
                try UpdateTrust.verifiedAsset(manifest: manifest, signature: signature, publicKey: signer.publicKey.pemRepresentation, version: version)
            }
        }
    }

    @Test(arguments: ["http://github.com/asset", "https://github.com.evil.example/a", "https://user:password@github.com/a", "https://github.com:8443/a", "file:///tmp/update.dmg"])
    func rejectsUntrustedRedirects(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(!UpdateTrust.allowedDownloadURL(url))
    }

    @Test func verifiesDiskSizeAndHashBeforeMount() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("package".utf8).write(to: file)
        let digest = try UpdateTrust.fileDigest(file)
        let asset = ReleaseAsset(name: "package", url: "unused", sha256: digest, size: 7)
        try UpdateTrust.verifyPackage(file, asset: asset)
        try Data("changed".utf8).write(to: file)
        #expect(throws: (any Error).self) { try UpdateTrust.verifyPackage(file, asset: asset) }
        try Data("short".utf8).write(to: file)
        #expect(throws: (any Error).self) { try UpdateTrust.verifyPackage(file, asset: asset) }
    }

    @Test func rejectsSymlinkTargetsAndEscapingBundleLinks() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Pet with 공백.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try UpdateTrust.validateTarget(app)
        let link = root.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        #expect(throws: (any Error).self) { try UpdateTrust.validateTarget(link) }
        let escaping = app.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: escaping, withDestinationURL: root)
        #expect(throws: (any Error).self) { try UpdateInstaller.validateBundleLinks(app) }
    }

    @Test @MainActor func automaticUpdatesDefaultOffPersistAndPreviewStaysOffline() async throws {
        let suite = "UpdatePreferences.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = UsageStore(usageFetching: UsageClient(), preferences: preferences)
        #expect(!first.automaticUpdates)
        first.automaticUpdates = true
        let second = UsageStore(usageFetching: UsageClient(), preferences: preferences)
        #expect(second.automaticUpdates)
        let updates = UpdateController(preview: true)
        updates.configureAutomatic(true)
        await updates.check()
        #expect(!updates.isBusy)
        #expect(updates.availableVersion == nil)
        #expect(updates.status == "미리보기에서는 업데이트하지 않습니다")
    }

    private func fixtureManifest(duplicate: Bool = false, url: String? = nil) throws -> Data {
        let name = "ChiikawaPet-1.2.0-mac-\(UpdateTrust.architecture).dmg"
        let asset = ReleaseAsset(name: name, url: url ?? "https://github.com/meengi07/chiikawa-agent-pet/releases/download/v1.2.0/\(name)", sha256: String(repeating: "a", count: 64), size: 7)
        let manifest = ReleaseManifest(schemaVersion: 1, version: "1.2.0", assets: duplicate ? [asset, asset] : [asset])
        return try JSONEncoder().encode(manifest)
    }
}
