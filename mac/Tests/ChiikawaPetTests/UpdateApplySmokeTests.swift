import AppKit
import Foundation
import Testing
@testable import ChiikawaPet

struct UpdateApplySmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PET_UPDATE_SMOKE_APP"] != nil))
    @MainActor func signedPackageReplacesAndRelaunchesThrowawayApp() async throws {
        let environment = ProcessInfo.processInfo.environment
        let appPath = try #require(environment["PET_UPDATE_SMOKE_APP"])
        let manifestPath = try #require(environment["PET_UPDATE_SMOKE_MANIFEST"])
        let signaturePath = try #require(environment["PET_UPDATE_SMOKE_SIGNATURE"])
        let packagePath = try #require(environment["PET_UPDATE_SMOKE_PACKAGE"])
        let app = URL(fileURLWithPath: appPath)
        let manifest = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let signature = try Data(contentsOf: URL(fileURLWithPath: signaturePath))
        let version = try UpdateTrust.appVersion(app)
        let key = try UpdateTrust.bundledKey(in: app)
        let asset = try UpdateTrust.verifiedAsset(manifest: manifest, signature: signature, publicKey: key, version: version)
        try UpdateTrust.verifyPackage(URL(fileURLWithPath: packagePath), asset: asset)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Pet Update Smoke 공백 \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("ChiikawaPet.app")
        try UpdateInstaller.runTool("/usr/bin/ditto", [app.path, target.path])
        try UpdateInstaller.runTool("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleShortVersionString 0.0.0", target.appendingPathComponent("Contents/Info.plist").path])
        try UpdateInstaller.runTool("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleVersion 0.0.0", target.appendingPathComponent("Contents/Info.plist").path])
        try UpdateInstaller.runTool("/usr/bin/codesign", ["--force", "--sign", "-", target.path])
        let originalDigest = try UpdateTrust.fileDigest(target.appendingPathComponent("Contents/Info.plist"))
        let preferences = try #require(UserDefaults(suiteName: UpdateTrust.bundleIdentifier))
        let sentinelKey = "updateSmokeSentinel"
        let previousSentinel = preferences.object(forKey: sentinelKey)
        let sentinel = UUID().uuidString
        preferences.set(sentinel, forKey: sentinelKey)
        preferences.synchronize()
        var workspaces: [URL] = []
        defer {
            for running in NSWorkspace.shared.runningApplications where running.bundleURL?.standardizedFileURL == target.standardizedFileURL {
                running.forceTerminate()
            }
            if let previousSentinel { preferences.set(previousSentinel, forKey: sentinelKey) }
            else { preferences.removeObject(forKey: sentinelKey) }
            preferences.synchronize()
            try? FileManager.default.removeItem(at: root)
            for workspace in workspaces { try? FileManager.default.removeItem(at: workspace) }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--preview", "50"]
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        var old = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
        try await Task.sleep(for: .seconds(2))
        #expect(!old.isTerminated)

        for failure in ["signature", "hash", "downgrade", "cancel"] {
            let workspace = try UpdateInstaller.makeWorkspace()
            workspaces.append(workspace)
            let requestVersion = failure == "downgrade" ? "0.0.0" : version.description
            let request = UpdateApplyRequest(target: target.path, currentVersion: "0.0.0", version: requestVersion, parentPID: old.processIdentifier, preview: true)
            var manifestBytes = manifest
            if failure == "signature" { manifestBytes.append(0x20) }
            let helper = try prepareHelper(workspace, target: target, request: request, manifest: manifestBytes, signature: signature, package: packagePath)
            if failure == "hash" {
                let file = try FileHandle(forWritingTo: workspace.appendingPathComponent("package.dmg"))
                try file.write(contentsOf: Data([0, 1, 2, 3]))
                try file.close()
            }
            if failure == "cancel" {
                try Data("cancelled".utf8).write(to: workspace.appendingPathComponent("cancel"), options: .atomic)
            }
            try helper.run()
            try await waitForExit(helper, seconds: 180)
            #expect(helper.terminationStatus != 0)
            #expect(!old.isTerminated)
            #expect(try UpdateTrust.fileDigest(target.appendingPathComponent("Contents/Info.plist")) == originalDigest)
        }

        let rollbackWorkspace = try UpdateInstaller.makeWorkspace()
        workspaces.append(rollbackWorkspace)
        let rollbackRequest = UpdateApplyRequest(target: target.path, currentVersion: "0.0.0", version: version.description, parentPID: old.processIdentifier, preview: true)
        let rollbackHelper = try prepareHelper(rollbackWorkspace, target: target, request: rollbackRequest, manifest: manifest, signature: signature, package: packagePath)
        try rollbackHelper.run()
        let rollbackPrepared = rollbackWorkspace.appendingPathComponent("prepared")
        let rollbackDeadline = Date().addingTimeInterval(600)
        while !FileManager.default.fileExists(atPath: rollbackPrepared.path), rollbackHelper.isRunning, Date() < rollbackDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(FileManager.default.fileExists(atPath: rollbackPrepared.path))
        let stagedExecutable = target.deletingLastPathComponent()
            .appendingPathComponent(".ChiikawaPet-stage-\(rollbackWorkspace.lastPathComponent).app/Contents/MacOS/ChiikawaPet")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedExecutable.path)
        old.terminate()
        try await waitForExit(rollbackHelper, seconds: 120)
        #expect(rollbackHelper.terminationStatus != 0)
        #expect(try UpdateTrust.fileDigest(target.appendingPathComponent("Contents/Info.plist")) == originalDigest)
        old = try #require(NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL && !$0.isTerminated })

        let workspace = try UpdateInstaller.makeWorkspace()
        workspaces.append(workspace)
        let request = UpdateApplyRequest(target: target.path, currentVersion: "0.0.0", version: version.description, parentPID: old.processIdentifier, preview: true)
        let helper = try prepareHelper(workspace, target: target, request: request, manifest: manifest, signature: signature, package: packagePath)
        try helper.run()
        let prepared = workspace.appendingPathComponent("prepared")
        let deadline = Date().addingTimeInterval(600)
        while !FileManager.default.fileExists(atPath: prepared.path), helper.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let resultFile = workspace.appendingPathComponent("result")
        let earlyResult = try? String(contentsOf: resultFile, encoding: .utf8)
        try #require(FileManager.default.fileExists(atPath: prepared.path), "Helper did not prepare: \(earlyResult ?? "no result")")
        old.terminate()
        try await waitForExit(helper, seconds: 120)
        let result = try String(contentsOf: resultFile, encoding: .utf8)
        #expect(helper.terminationStatus == 0, "\(result)")
        #expect(result == "installed \(version)")
        #expect(try UpdateTrust.appVersion(target) == version)
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("relaunch-ready").path))
        let restarted = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL && $0.processIdentifier != old.processIdentifier }
        #expect(restarted != nil)
        let restoredPreferences = try #require(UserDefaults(suiteName: UpdateTrust.bundleIdentifier))
        #expect(restoredPreferences.string(forKey: sentinelKey) == sentinel)
        print("Verified real macOS package swap/relaunch: \(version), launch-failure rollback, signature/hash/downgrade rejection, settings sentinel preserved.")
    }

    @MainActor private func prepareHelper(_ workspace: URL, target: URL, request: UpdateApplyRequest,
                                          manifest: Data, signature: Data, package: String) throws -> Process {
        try manifest.write(to: workspace.appendingPathComponent("updates.json"))
        try signature.write(to: workspace.appendingPathComponent("updates.sig"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: package), to: workspace.appendingPathComponent("package.dmg"))
        let bytes = try JSONEncoder().encode(request)
        try bytes.write(to: workspace.appendingPathComponent("request.json"))
        let helper = workspace.appendingPathComponent("Updater")
        try FileManager.default.copyItem(at: target.appendingPathComponent("Contents/MacOS/ChiikawaPet"), to: helper)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--apply-update", workspace.path]
        return process
    }

    @MainActor private func waitForExit(_ process: Process, seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning {
            process.terminate()
            throw UpdateFailure("The real apply smoke helper timed out.")
        }
    }
}
