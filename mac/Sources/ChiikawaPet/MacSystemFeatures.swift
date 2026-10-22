import AppKit
import Carbon
import Darwin
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class MacSystemFeatures: NSObject, UNUserNotificationCenterDelegate {
    var openPanel: (@MainActor () -> Void)?
    var togglePanel: (@MainActor () -> Void)?
    var failure: (@MainActor (String) -> Void)?
    var notificationsEnabled = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var notificationCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    var launchAtLoginEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    func configureNotifications() { notificationCenter?.delegate = self }

    func requestNotificationPermission() async -> String? {
        guard let notificationCenter else { return T("알림은 설치된 앱에서만 사용할 수 있습니다.") }
        do {
            let allowed = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            return allowed ? nil : T("알림 권한이 없습니다. 시스템 설정에서 알림을 허용하세요.")
        } catch { return T("알림 권한을 요청하지 못했습니다. 시스템 설정을 확인하세요.") }
    }

    func notify(events: [UsageAlertEvent]) async {
        guard notificationsEnabled, let notificationCenter, !events.isEmpty else { return }
        let authorized = await withCheckedContinuation { continuation in
            notificationCenter.getNotificationSettings { settings in
                let status = settings.authorizationStatus
                continuation.resume(returning: status == .authorized || status == .provisional)
            }
        }
        guard notificationsEnabled else { return }
        guard authorized else {
            failure?(T("알림 권한이 없습니다. 시스템 설정에서 알림을 허용하세요."))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = T("사용량 알림")
        content.body = events.map { "\(T($0.metricTitle)): \(T($0.message))" }.joined(separator: "\n")
        content.threadIdentifier = "usage-alerts"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do { try await notificationCenter.add(request) }
        catch { failure?(T("사용량 알림을 표시하지 못했습니다.")) }
    }

    func clearNotifications() {
        notificationCenter?.removeAllPendingNotificationRequests()
        notificationCenter?.removeAllDeliveredNotifications()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { openPanel?() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                let status = SMAppService.mainApp.status
                if status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
                if SMAppService.mainApp.status == .requiresApproval {
                    return T("로그인 항목을 시스템 설정에서 승인하세요.")
                }
                guard SMAppService.mainApp.status == .enabled else { return T("로그인 시 시작을 등록하지 못했습니다.") }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch { return T("로그인 항목을 변경하지 못했습니다. 시스템 설정을 확인하세요.") }
    }

    func register(_ shortcut: RecordedShortcut?) -> String? {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        guard let shortcut else { return nil }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let features = Unmanaged<MacSystemFeatures>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in features.togglePanel?() }
            return noErr
        }, 1, &eventType, context, &handler)
        guard installed == noErr else { return T("전역 단축키 처리기를 등록하지 못했습니다.") }
        let identity = EventHotKeyID(signature: 0x43504B54, id: 1)
        let registered = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identity, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler); self.handler = nil }
            return T("단축키가 사용 중이거나 등록할 수 없습니다. 다른 조합을 기록하세요.")
        }
        return nil
    }

    func stop() { _ = register(nil) }
}

struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: RecordedShortcut?
    var onRecord: (RecordedShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecordingButton {
        let button = ShortcutRecordingButton(frame: .zero)
        button.onRecord = onRecord
        return button
    }

    func updateNSView(_ button: ShortcutRecordingButton, context: Context) {
        button.onRecord = onRecord
        button.isEnabled = context.environment.isEnabled
        if !button.recording { button.title = shortcut?.label ?? T("단축키 기록") }
        button.setAccessibilityLabel(T("전역 단축키 기록"))
    }
}

final class ShortcutRecordingButton: NSButton {
    var onRecord: ((RecordedShortcut?) -> Void)?
    private(set) var recording = false
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func beginRecording() {
        recording = true
        title = T("조합 누르기 · Esc 취소")
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = T("단축키 기록"); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
            title = T("⌘ / ⌃ / ⌥ 조합이 필요합니다")
            return
        }
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        label += event.charactersIgnoringModifiers?.uppercased() ?? "#\(event.keyCode)"
        let shortcut = RecordedShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
        recording = false
        title = label
        onRecord?(shortcut)
    }
}

final class AppInstanceLease {
    private let lockFile: URL
    private var descriptor: Int32 = -1
    private(set) var ownerProcessIdentifier: pid_t?

    init(lockFile: URL) { self.lockFile = lockFile }
    deinit { if descriptor >= 0 { close(descriptor) } }

    func acquire() throws -> Bool {
        if descriptor >= 0 { return true }
        let opened = open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard opened >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(opened, LOCK_EX | LOCK_NB) == 0 {
            let identifier = Data(String(getpid()).utf8)
            guard ftruncate(opened, 0) == 0 else {
                let failure = errno
                close(opened)
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
            let count = identifier.withUnsafeBytes { pwrite(opened, $0.baseAddress, $0.count, 0) }
            guard count == identifier.count else {
                close(opened)
                throw POSIXError(.EIO)
            }
            descriptor = opened
            ownerProcessIdentifier = getpid()
            return true
        }
        let failure = errno
        if failure == EWOULDBLOCK {
            var buffer = [UInt8](repeating: 0, count: 32)
            let count = buffer.withUnsafeMutableBytes { pread(opened, $0.baseAddress, $0.count, 0) }
            close(opened)
            if count > 0, let identifier = pid_t(String(decoding: buffer.prefix(count), as: UTF8.self)), identifier > 0 {
                ownerProcessIdentifier = identifier
            } else {
                ownerProcessIdentifier = nil
            }
            return false
        }
        close(opened)
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }
}

@MainActor
enum AppInstanceGuard {
    private static var lease: AppInstanceLease?
    static var ownerProcessIdentifier: pid_t? { lease?.ownerProcessIdentifier }

    static func acquire() throws -> Bool {
        if let lease { return try lease.acquire() }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("ChiikawaPet", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let created = AppInstanceLease(lockFile: directory.appendingPathComponent("instance.lock"))
        lease = created
        return try created.acquire()
    }
}
