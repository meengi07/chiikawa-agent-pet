import AppKit
import Darwin
import Foundation

struct UpdateApplyRequest: Codable, Sendable {
    let target: String
    let currentVersion: String
    let version: String
    let parentPID: Int32
    let preview: Bool
}

enum UpdateInstaller {
    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.chiikawa.agent-pet/Updates", isDirectory: true)
    }

    static func makeWorkspace() throws -> URL {
        let root = cacheRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else {
            throw UpdateFailure("The update cache must not be a symbolic link.")
        }
        let workspace = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return workspace
    }

    static func validateWorkspace(_ workspace: URL) throws {
        let root = cacheRoot.standardizedFileURL
        guard workspace.deletingLastPathComponent().standardizedFileURL == root,
              UUID(uuidString: workspace.lastPathComponent) != nil,
              workspace.path == workspace.resolvingSymlinksInPath().path else {
            throw UpdateFailure("Invalid update workspace.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: workspace.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw UpdateFailure("The update workspace is not private.")
        }
    }

    static func readWorkspaceFile(_ workspace: URL, name: String, limit: Int) throws -> Data {
        let file = workspace.appendingPathComponent(name)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(limit),
              file.path == file.resolvingSymlinksInPath().path else {
            throw UpdateFailure("An update input is too large or is not a regular file.")
        }
        return try Data(contentsOf: file)
    }

    static func runTool(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw UpdateFailure("The update tool timed out: \(executable).")
        }
        guard process.terminationStatus == 0 else {
            throw UpdateFailure("The update tool failed: \(executable) (\(process.terminationStatus)). The old app is retained.")
        }
    }

    static func prepare(_ workspace: URL, request: UpdateApplyRequest) throws -> URL {
        try validateWorkspace(workspace)
        let target = URL(fileURLWithPath: request.target)
        try UpdateTrust.validateTarget(target)
        let installedVersion = try UpdateTrust.appVersion(target)
        let expectedCurrent = try ReleaseVersion(request.currentVersion)
        let version = try ReleaseVersion(request.version)
        guard installedVersion == expectedCurrent, version > installedVersion else {
            throw UpdateFailure("The update is not newer than the installed app.")
        }
        let executable = target.appendingPathComponent("Contents/MacOS/ChiikawaPet")
        let helper = workspace.appendingPathComponent("Updater")
        let executableDigest = try UpdateTrust.fileDigest(executable)
        let helperDigest = try UpdateTrust.fileDigest(helper)
        guard helperDigest == executableDigest else { throw UpdateFailure("The update helper does not match the installed app.") }
        let key = try UpdateTrust.bundledKey(in: target)
        let manifest = try readWorkspaceFile(workspace, name: "updates.json", limit: 65_536)
        let signature = try readWorkspaceFile(workspace, name: "updates.sig", limit: 2048)
        let asset = try UpdateTrust.verifiedAsset(manifest: manifest, signature: signature, publicKey: key, version: version)
        let package = workspace.appendingPathComponent("package.dmg")
        try UpdateTrust.verifyPackage(package, asset: asset)
        let mount = workspace.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        try runTool("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, package.path])
        defer { try? runTool("/usr/bin/hdiutil", ["detach", mount.path], timeout: 30) }
        let incoming = mount.appendingPathComponent("ChiikawaPet.app", isDirectory: true)
        let incomingVersion = try UpdateTrust.appVersion(incoming)
        guard incomingVersion == version, incoming.path == incoming.resolvingSymlinksInPath().path else {
            throw UpdateFailure("The package app identity or version is invalid.")
        }
        try validateBundleLinks(incoming)
        try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", incoming.path])
        let staging = target.deletingLastPathComponent().appendingPathComponent(".ChiikawaPet-stage-\(workspace.lastPathComponent).app")
        guard !FileManager.default.fileExists(atPath: staging.path) else { throw UpdateFailure("The staging path already exists.") }
        do {
            try runTool("/usr/bin/ditto", [incoming.path, staging.path])
            let copiedVersion = try UpdateTrust.appVersion(staging)
            guard copiedVersion == version else { throw UpdateFailure("The staged app version is invalid.") }
            try validateBundleLinks(staging)
            try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", staging.path])
            let stagedKey = try UpdateTrust.bundledKey(in: staging)
            guard stagedKey == key else { throw UpdateFailure("The update unexpectedly changes the pinned release key.") }
            return staging
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func validateBundleLinks(_ app: URL) throws {
        guard let entries = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw UpdateFailure("Cannot inspect the update app.")
        }
        for case let entry as URL in entries {
            let resolved = entry.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(app.path + "/") else { throw UpdateFailure("The update bundle contains an escaping symbolic link.") }
        }
    }

    @MainActor
    static func startHelper(workspace: URL, target: URL, version: ReleaseVersion, preview: Bool = false) throws -> Process {
        try UpdateTrust.validateTarget(target)
        let current = try UpdateTrust.appVersion(target)
        let request = UpdateApplyRequest(target: target.path, currentVersion: current.description,
                                         version: version.description, parentPID: getpid(), preview: preview)
        let bytes = try JSONEncoder().encode(request)
        try bytes.write(to: workspace.appendingPathComponent("request.json"), options: .atomic)
        let executable = target.appendingPathComponent("Contents/MacOS/ChiikawaPet")
        let helper = workspace.appendingPathComponent("Updater")
        try FileManager.default.copyItem(at: executable, to: helper)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--apply-update", workspace.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    @MainActor
    static func runHelper(workspace: URL) async -> Int32 {
        var staging: URL?
        var exitedRequest: UpdateApplyRequest?
        var trustedWorkspace = false
        var lockDescriptor: Int32 = -1
        defer { if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor) } }
        do {
            try validateWorkspace(workspace)
            trustedWorkspace = true
            lockDescriptor = open(cacheRoot.appendingPathComponent("apply.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw UpdateFailure("Another update installation is already running.")
            }
            let bytes = try readWorkspaceFile(workspace, name: "request.json", limit: 8192)
            let request = try JSONDecoder().decode(UpdateApplyRequest.self, from: bytes)
            guard request.parentPID > 1, request.parentPID != getpid(),
                  let parent = NSRunningApplication(processIdentifier: request.parentPID),
                  parent.executableURL?.standardizedFileURL.path == request.target + "/Contents/MacOS/ChiikawaPet" else {
                throw UpdateFailure("The running app does not match the update target.")
            }
            let prepared = try await Task.detached { try prepare(workspace, request: request) }.value
            staging = prepared
            let cancellation = workspace.appendingPathComponent("cancel")
            guard !FileManager.default.fileExists(atPath: cancellation.path) else { throw UpdateFailure("Automatic update cancelled.") }
            try Data("prepared".utf8).write(to: workspace.appendingPathComponent("prepared"), options: .atomic)
            let deadline = Date().addingTimeInterval(60)
            while kill(request.parentPID, 0) == 0, Date() < deadline {
                guard !FileManager.default.fileExists(atPath: cancellation.path) else { throw UpdateFailure("Automatic update cancelled.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard kill(request.parentPID, 0) != 0 else { throw UpdateFailure("The running app did not exit. Update cancelled.") }
            guard !FileManager.default.fileExists(atPath: cancellation.path) else { throw UpdateFailure("Automatic update cancelled.") }
            exitedRequest = request
            let target = URL(fileURLWithPath: request.target)
            let current = try UpdateTrust.appVersion(target)
            guard current.description == request.currentVersion else { throw UpdateFailure("The installed app changed during the update.") }
            try UpdateTrust.validateTarget(target)
            let backup = target.deletingLastPathComponent().appendingPathComponent(".ChiikawaPet-backup-\(workspace.lastPathComponent).app")
            guard !FileManager.default.fileExists(atPath: backup.path) else { throw UpdateFailure("The update backup path already exists.") }
            try FileManager.default.moveItem(at: target, to: backup)
            var launched: NSRunningApplication?
            do {
                try FileManager.default.moveItem(at: prepared, to: target)
                staging = nil
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = ["--update-relaunch", workspace.path]
                if request.preview { configuration.arguments += ["--preview", "50"] }
                configuration.createsNewApplicationInstance = true
                configuration.activates = false
                launched = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
                let launchDeadline = Date().addingTimeInterval(45)
                let ready = workspace.appendingPathComponent("relaunch-ready")
                while !FileManager.default.fileExists(atPath: ready.path), launched?.isTerminated == false, Date() < launchDeadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard FileManager.default.fileExists(atPath: ready.path), launched?.isTerminated == false else {
                    throw UpdateFailure("The updated app failed to start; restoring the previous app.")
                }
                try Data("installed \(request.version)".utf8).write(to: workspace.appendingPathComponent("result"), options: .atomic)
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.removeItem(at: workspace.appendingPathComponent("package.dmg"))
                return 0
            } catch {
                if let launched, !launched.isTerminated {
                    launched.terminate()
                    let stopDeadline = Date().addingTimeInterval(5)
                    while !launched.isTerminated, Date() < stopDeadline { try? await Task.sleep(for: .milliseconds(100)) }
                    if !launched.isTerminated { launched.forceTerminate() }
                }
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: backup, to: target)
                try? Data("failed: \(error.localizedDescription)".utf8).write(to: workspace.appendingPathComponent("result"), options: .atomic)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.arguments = ["--update-rollback", workspace.path]
                if request.preview { configuration.arguments += ["--preview", "50"] }
                _ = try? await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
                throw error
            }
        } catch {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            let message = "failed: \(error.localizedDescription)"
            if trustedWorkspace {
                try? Data(message.utf8).write(to: workspace.appendingPathComponent("result"), options: .atomic)
            }
            if let request = exitedRequest {
                let target = URL(fileURLWithPath: request.target)
                let stillRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == target.path && !$0.isTerminated }
                if !stillRunning, let version = try? UpdateTrust.appVersion(target), version.description == request.currentVersion {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    configuration.arguments = ["--update-rollback", workspace.path]
                    if request.preview { configuration.arguments += ["--preview", "50"] }
                    _ = try? await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
                }
            }
            return 1
        }
    }

    @MainActor
    static func acknowledgeRelaunch(_ arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--update-relaunch"), arguments.indices.contains(index + 1) else { return }
        let workspace = URL(fileURLWithPath: arguments[index + 1])
        do {
            try validateWorkspace(workspace)
            let bytes = try Data(contentsOf: workspace.appendingPathComponent("request.json"))
            let request = try JSONDecoder().decode(UpdateApplyRequest.self, from: bytes)
            guard Bundle.main.bundleURL.path == request.target,
                  Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == request.version else { return }
            try Data("ready".utf8).write(to: workspace.appendingPathComponent("relaunch-ready"), options: .atomic)
        } catch { return }
    }
}
