import AppKit
import Combine
import Foundation

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var status = "업데이트를 확인하지 않았습니다"
    @Published private(set) var isBusy = false
    @Published private(set) var availableVersion: String?
    private var pending: PendingUpdate?
    private var timer: Timer?
    private var automaticEnabled = false
    private var automaticWorkspace: URL?
    private let preview: Bool

    struct PendingUpdate: Sendable {
        let workspace: URL
        let version: ReleaseVersion
        let asset: ReleaseAsset
    }

    init(preview: Bool) { self.preview = preview }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }

    func configureAutomatic(_ enabled: Bool, checkImmediately: Bool = true) {
        automaticEnabled = enabled
        if !enabled, let automaticWorkspace {
            try? Data("cancelled".utf8).write(to: automaticWorkspace.appendingPathComponent("cancel"), options: .atomic)
        }
        timer?.invalidate()
        timer = nil
        guard enabled, !preview else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(automatic: true) }
        }
        if checkImmediately { Task { await check(automatic: true) } }
    }

    func check(automatic: Bool = false) async {
        guard !isBusy else { return }
        guard !automatic || automaticEnabled else { return }
        guard !preview else { status = "미리보기에서는 업데이트하지 않습니다"; return }
        isBusy = true
        status = "업데이트 확인 중…"
        clearPending()
        var workspace: URL?
        do {
            let installed = try ReleaseVersion(currentVersion)
            let target = Bundle.main.bundleURL
            try UpdateTrust.validateTarget(target)
            let key = try UpdateTrust.bundledKey(in: target)
            let created = try UpdateInstaller.makeWorkspace()
            workspace = created
            let releaseFile = created.appendingPathComponent("release.json")
            let releaseURL = URL(string: "https://api.github.com/repos/meengi07/chiikawa-agent-pet/releases/latest")!
            try await UpdateDownload.fetch(releaseURL, to: releaseFile, maximumBytes: 1024 * 1024)
            let releaseData = try Data(contentsOf: releaseFile)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: releaseData)
            let version = try release.stableVersion()
            guard version > installed else {
                clearPending()
                status = "최신 버전입니다"
                try? FileManager.default.removeItem(at: created)
                isBusy = false
                return
            }
            let manifestFile = created.appendingPathComponent("updates.json")
            let signatureFile = created.appendingPathComponent("updates.sig")
            let manifestURL = UpdateTrust.canonicalURL(version: version, name: "updates.json")
            let signatureURL = UpdateTrust.canonicalURL(version: version, name: "updates.sig")
            try await UpdateDownload.fetch(manifestURL, to: manifestFile, maximumBytes: 65_536)
            try await UpdateDownload.fetch(signatureURL, to: signatureFile, maximumBytes: 2048)
            let manifest = try Data(contentsOf: manifestFile)
            let signature = try Data(contentsOf: signatureFile)
            let asset = try UpdateTrust.verifiedAsset(manifest: manifest, signature: signature, publicKey: key, version: version)
            clearPending()
            pending = PendingUpdate(workspace: created, version: version, asset: asset)
            availableVersion = version.description
            status = "새 버전 설치 가능"
        } catch {
            if let workspace { try? FileManager.default.removeItem(at: workspace) }
            status = "\(T("업데이트 실패")): \(error.localizedDescription)"
        }
        isBusy = false
        if automatic, automaticEnabled, pending != nil { await install(automatic: true) }
    }

    func install(automatic: Bool = false) async {
        guard !isBusy, allowsInstallation(automatic: automatic), let pending else { return }
        if automatic { automaticWorkspace = pending.workspace }
        defer { automaticWorkspace = nil }
        isBusy = true
        status = "업데이트 다운로드 중…"
        do {
            let package = pending.workspace.appendingPathComponent("package.dmg")
            if FileManager.default.fileExists(atPath: package.path) { try FileManager.default.removeItem(at: package) }
            let packageURL = URL(string: pending.asset.url)!
            try await UpdateDownload.fetch(packageURL, to: package, maximumBytes: pending.asset.size)
            try await Task.detached { try UpdateTrust.verifyPackage(package, asset: pending.asset) }.value
            guard allowsInstallation(automatic: automatic) else {
                status = "자동 업데이트가 취소되었습니다"
                isBusy = false
                return
            }
            try? FileManager.default.removeItem(at: pending.workspace.appendingPathComponent("cancel"))
            status = "업데이트 설치 준비 중…"
            let process = try UpdateInstaller.startHelper(workspace: pending.workspace, target: Bundle.main.bundleURL, version: pending.version)
            let deadline = Date().addingTimeInterval(600)
            let prepared = pending.workspace.appendingPathComponent("prepared")
            while !FileManager.default.fileExists(atPath: prepared.path), process.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard allowsInstallation(automatic: automatic) else {
                try? Data("cancelled".utf8).write(to: pending.workspace.appendingPathComponent("cancel"), options: .atomic)
                let cancellationDeadline = Date().addingTimeInterval(10)
                while process.isRunning, Date() < cancellationDeadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                if !process.isRunning { clearPending() }
                status = "자동 업데이트가 취소되었습니다"
                isBusy = false
                return
            }
            guard FileManager.default.fileExists(atPath: prepared.path), process.isRunning else {
                if process.isRunning { process.terminate() }
                let result = try? String(contentsOf: pending.workspace.appendingPathComponent("result"), encoding: .utf8)
                throw UpdateFailure(result ?? "The update helper could not prepare the replacement. The current app is unchanged.")
            }
            status = "업데이트 후 다시 시작합니다…"
            UserDefaults.standard.synchronize()
            NSApplication.shared.terminate(nil)
        } catch {
            status = "\(T("업데이트 실패")): \(error.localizedDescription)"
            clearPending()
            isBusy = false
        }
    }

    func allowsInstallation(automatic: Bool) -> Bool {
        !preview && (!automatic || automaticEnabled)
    }

    func showRollbackFailure(_ arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: "--update-rollback"), arguments.indices.contains(index + 1) else { return false }
        let workspace = URL(fileURLWithPath: arguments[index + 1])
        do {
            try UpdateInstaller.validateWorkspace(workspace)
            let result = try String(contentsOf: workspace.appendingPathComponent("result"), encoding: .utf8)
            status = "\(T("업데이트 실패")): \(result)"
            return true
        } catch { return false }
    }

    private func clearPending() {
        if let pending { try? FileManager.default.removeItem(at: pending.workspace) }
        pending = nil
        availableVersion = nil
    }
}
