import AppKit
import Combine
import SwiftUI

@main
struct ChiikawaPetApp {
    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--apply-update") {
            guard arguments.indices.contains(index + 1) else { exit(64) }
            let workspace = URL(fileURLWithPath: arguments[index + 1])
            let status = await UpdateInstaller.runHelper(workspace: workspace)
            exit(status)
        }
        if arguments.contains("--usage") {
            let usageClient = UsageClient()
            for account in UsageAccount.defaults {
                let provider = account.provider
                do {
                    let reading = try await usageClient.fetch(account, allowKeychainPrompt: false)
                    for window in reading.windows {
                        print("\(provider.rawValue) · \(T(window.title)): \(window.remainingPercent)% remaining")
                    }
                } catch {
                    print("\(provider.rawValue): \(T(UsageStore.safeError(error)))")
                }
            }
            return
        }
        var previewPercent: Double?
        if let index = arguments.firstIndex(of: "--preview") {
            guard arguments.indices.contains(index + 1),
                  let percent = Double(arguments[index + 1]), percent.isFinite,
                  (0...100).contains(percent) else {
                fputs("--preview requires a remaining percentage from 0 to 100\n", stderr)
                exit(64)
            }
            previewPercent = percent
        }
        let application = NSApplication.shared
        if previewPercent == nil {
            do {
                guard try AppInstanceGuard.acquire() else {
                    if let identifier = AppInstanceGuard.ownerProcessIdentifier {
                        NSRunningApplication(processIdentifier: identifier)?.activate(options: [.activateAllWindows])
                    }
                    return
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = T("앱 중복 실행 보호를 준비하지 못했습니다.")
                alert.informativeText = T("앱 지원 폴더의 권한을 확인한 뒤 다시 실행하세요.")
                alert.runModal()
                return
            }
        }
        let delegate = PetAppDelegate(previewPercent: previewPercent, showUsageOnLaunch: arguments.contains("--show-usage"))
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        runApplication(application, keeping: delegate)
    }

    @MainActor
    private static func runApplication(_ application: NSApplication, keeping delegate: PetAppDelegate) {
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class PetAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: UsageStore
    private let updater: UpdateController
    private let showUsageOnLaunch: Bool
    private var petWindow: NSPanel!
    private var usageWindow: NSPanel?
    private var petView: DraggablePetView!
    private var statusItem: NSStatusItem!
    private var animationTimer: Timer?
    private var refreshTimer: Timer?
    private var observation: AnyCancellable?
    private var clickMonitor: Any?
    private var appliedPetVisibility: Bool?
    private var appliedMenuPresentation: MenuBarPresentation?
    private var appearanceObservation: NSKeyValueObservation?
    private var direction: CGFloat = -1
    private var isDragging = false
    private var appliedLanguage = AppLanguage.current

    init(previewPercent: Double?, showUsageOnLaunch: Bool) {
        store = UsageStore(usageFetching: UsageClient(), previewPercent: previewPercent)
        updater = UpdateController(preview: previewPercent != nil)
        self.showUsageOnLaunch = showUsageOnLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let saved = UserDefaults.standard
        let origin = saved.object(forKey: "petX") == nil
            ? NSPoint(x: screen.maxX - 190, y: screen.minY + 55)
            : NSPoint(x: saved.double(forKey: "petX"), y: saved.double(forKey: "petY"))
        let petSize = NSSize(width: 148 * store.petScale, height: 164 * store.petScale)
        petWindow = NSPanel(contentRect: NSRect(origin: origin, size: petSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        petWindow.title = T("\(store.selectedCharacter.name) 펫")
        petWindow.setAccessibilityRole(.window)
        petWindow.setAccessibilitySubrole(.floatingWindow)
        petWindow.level = .floating
        petWindow.isOpaque = false
        petWindow.backgroundColor = .clear
        petWindow.hasShadow = false
        petWindow.hidesOnDeactivate = false
        petWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        petWindow.isReleasedWhenClosed = false
        petView = DraggablePetView(frame: NSRect(origin: .zero, size: petWindow.frame.size))
        petView.autoresizingMask = [.width, .height]
        petView.animationEnabled = store.isPetVisible
        petView.owner = self
        petView.remainingPercent = store.remainingPercent
        petView.character = store.selectedCharacter
        petWindow.contentView = petView
        constrainPetToScreens()
        observation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updatePetPresentation()
            }
        }
        let statusName = "ChiikawaPetUsage"
        statusItem = NSStatusBar.system.statusItem(withLength: 0)
        statusItem.autosaveName = statusName
        statusItem.length = MenuBarArtwork.width + 12
        statusItem.isVisible = true
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleNone
        statusItem.menu = makeMenu()
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateMenuBarArtwork(force: true) }
        }
        updatePetPresentation()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.store.refresh() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged), name: NSWorkspace.didWakeNotification, object: nil)
        store.configureSystemFeatures(openPanel: { [weak self] in
            guard let self else { return }
            if self.usageWindow?.isVisible != true { self.toggleUsage() }
        }, togglePanel: { [weak self] in self?.toggleUsage() })
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reduceMotionChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        Task { await store.refresh(); await store.loadHistory() }
        if showUsageOnLaunch { toggleUsage() }
        let rolledBack = updater.showRollbackFailure(CommandLine.arguments)
        updater.configureAutomatic(store.automaticUpdates, checkImmediately: !rolledBack)
        UpdateInstaller.acknowledgeRelaunch(CommandLine.arguments)
    }

    func applicationWillTerminate(_ notification: Notification) {
        animationTimer?.invalidate()
        refreshTimer?.invalidate()
        store.systemFeatures.stop()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        savePosition()
    }

    func beginDragging() { isDragging = true }
    func endDragging() { isDragging = false; constrainPetToScreens(); savePosition() }

    func movePet(to origin: NSPoint) {
        petWindow.setFrameOrigin(origin)
        constrainPetToScreens()
    }

    private func updatePetPresentation() {
        if appliedLanguage != store.language {
            appliedLanguage = store.language
            statusItem.menu = makeMenu()
            let wasOpen = usageWindow?.isVisible == true
            closeUsage()
            if wasOpen { toggleUsage() }
        }
        petView.language = store.language
        petView.remainingPercent = store.remainingPercent
        petView.moodOverride = store.mood
        petView.character = store.selectedCharacter
        petWindow.title = T("\(store.selectedCharacter.name) 펫")
        usageWindow?.title = T("\(store.selectedCharacter.name) 사용량")
        resizePet()
        updatePetVisibility()
        let usageTitle = store.menuBarTitle
        let description = T("\(store.selectedCharacter.name) · \(usageTitle) · \(store.isPetVisible ? "펫 표시 중" : "펫 숨김")")
        updateMenuBarArtwork()
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
    }

    private func updateMenuBarArtwork(force: Bool = false) {
        let presentation = store.menuBarPresentation
        guard force || presentation != appliedMenuPresentation, let button = statusItem.button else { return }
        appliedMenuPresentation = presentation
        statusItem.length = MenuBarArtwork.width(for: presentation) + 12
        button.image = MenuBarArtwork.image(for: presentation, appearance: button.effectiveAppearance)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(toggleUsage) {
                item.title = T("\(store.selectedCharacter.name) · 사용량 보기")
            } else if item.action == #selector(selectCharacter), let name = item.representedObject as? String {
                item.state = name == store.selectedCharacter.rawValue ? .on : .off
            } else if item.action == #selector(selectPetSize), let scale = item.representedObject as? NSNumber {
                item.state = abs(scale.doubleValue - store.petScale) < 0.0001 ? .on : .off
            } else if item.action == #selector(togglePetVisibility) {
                item.state = store.isPetVisible ? .on : .off
            } else if item.action == #selector(toggleWandering) {
                item.state = store.wanders ? .on : .off
            } else if item.action == #selector(checkForUpdates) {
                item.isEnabled = !updater.isBusy && store.previewPercent == nil
            } else if item.action == #selector(installUpdate) {
                item.title = "\(T("업데이트 설치")) \(updater.availableVersion ?? "")"
                item.isEnabled = !updater.isBusy && updater.availableVersion != nil
            } else if item.action == #selector(toggleAutomaticUpdates) {
                item.state = store.automaticUpdates ? .on : .off
                item.isEnabled = store.previewPercent == nil
            } else if item.identifier?.rawValue == "update-status" {
                item.title = "\(T("현재 버전")) \(updater.currentVersion) · \(T(updater.status))"
            }
        }
    }

    private func resizePet() {
        let size = NSSize(width: 148 * store.petScale, height: 164 * store.petScale)
        let frame = petWindow.frame
        guard frame.size != size else { return }
        let resized = NSRect(
            x: frame.midX - size.width / 2, y: frame.minY,
            width: size.width, height: size.height
        )
        petWindow.setFrame(resized, display: true)
        constrainPetToScreens()
        savePosition()
    }

    private func updatePetVisibility() {
        guard appliedPetVisibility != store.isPetVisible else { return }
        appliedPetVisibility = store.isPetVisible
        petView.animationEnabled = store.isPetVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animationTimer?.invalidate()
        animationTimer = nil
        if store.isPetVisible {
            petWindow.orderFrontRegardless()
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.walk() }
            }
        } else {
            petWindow.orderOut(nil)
        }
    }

    private var statusButtonFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let rectangle = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectangle)
    }

    @objc func toggleUsage() {
        if usageWindow?.isVisible == true { closeUsage(); return }
        let usagePanel = UsagePanel(store: store)
        let contentView = NSHostingView(rootView: usagePanel.content)
        let usesStatusAnchor = !store.isPetVisible
        let anchorScreen = usesStatusAnchor ? statusItem.button?.window?.screen : petWindow.screen
        let screen = anchorScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? petWindow.frame
        let anchor: NSRect
        if usesStatusAnchor {
            anchor = statusButtonFrame ?? NSRect(x: screen.midX, y: screen.maxY, width: 0, height: 0)
        } else {
            anchor = petWindow.frame
        }
        let height = min(contentView.fittingSize.height, max(1, screen.height - 24))
        let hostingView = NSHostingView(rootView: usagePanel.frame(height: height))
        let panel = UsageWindow(contentRect: NSRect(x: 0, y: 0, width: UsagePanel.width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = T("\(store.selectedCharacter.name) 사용량")
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView
        let preferredX = anchor.midX - UsagePanel.width / 2
        let x = min(max(preferredX, screen.minX + 12), screen.maxX - UsagePanel.width - 12)
        let preferredY: CGFloat
        if usesStatusAnchor {
            preferredY = anchor.minY - height - 8
        } else {
            let above = anchor.maxY + 8
            preferredY = above + height <= screen.maxY - 12 ? above : anchor.minY - height - 8
        }
        let y = min(max(preferredY, screen.minY + 12), screen.maxY - height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        usageWindow = panel
        panel.makeKeyAndOrderFront(nil)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismissUsageIfOutside() }
        }
    }

    private func dismissUsageIfOutside() {
        if NSApp.modalWindow != nil { return }
        let mouse = NSEvent.mouseLocation
        if usageWindow?.frame.contains(mouse) == true { return }
        if store.isPetVisible && petWindow.frame.contains(mouse) { return }
        if statusButtonFrame?.contains(mouse) == true { return }
        closeUsage()
    }

    func closeUsage() {
        usageWindow?.close()
        usageWindow = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
    }

    func showContextMenu(with event: NSEvent) { NSMenu.popUpContextMenu(makeMenu(), with: event, for: petView) }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: T("\(store.selectedCharacter.name) · 사용량 보기"), action: #selector(toggleUsage), keyEquivalent: "")
        menu.addItem(withTitle: T("사용량 새로고침 / 연결"), action: #selector(refreshUsage), keyEquivalent: "")
        let languages = NSMenu()
        for language in AppLanguage.allCases {
            let item = languages.addItem(withTitle: language.title, action: #selector(selectLanguage), keyEquivalent: "")
            item.representedObject = language.rawValue
            item.target = self
            item.state = language == store.language ? .on : .off
        }
        menu.addItem(withTitle: "Language / 언어", action: nil, keyEquivalent: "").submenu = languages
        let characters = NSMenu()
        characters.delegate = self
        for character in PetCharacter.allCases {
            let choice = characters.addItem(withTitle: character.name, action: #selector(selectCharacter), keyEquivalent: "")
            choice.representedObject = character.rawValue
            choice.state = character == store.selectedCharacter ? .on : .off
            choice.target = self
        }
        let characterMenu = menu.addItem(withTitle: T("펫 종류"), action: nil, keyEquivalent: "")
        characterMenu.submenu = characters
        let sizes = NSMenu()
        sizes.delegate = self
        for percent in [40, 55, 65, 80, 100, 120] {
            let title = percent == 65 ? T("65% (기본)") : "\(percent)%"
            let choice = sizes.addItem(withTitle: title, action: #selector(selectPetSize), keyEquivalent: "")
            let scale = Double(percent) / 100
            choice.representedObject = NSNumber(value: scale)
            choice.state = abs(store.petScale - scale) < 0.0001 ? .on : .off
            choice.target = self
        }
        let sizeMenu = menu.addItem(withTitle: T("펫 크기"), action: nil, keyEquivalent: "")
        sizeMenu.submenu = sizes
        let visibility = menu.addItem(withTitle: T("펫 표시"), action: #selector(togglePetVisibility), keyEquivalent: "")
        visibility.state = store.isPetVisible ? .on : .off
        menu.addItem(.separator())
        let wander = menu.addItem(withTitle: T("느긋하게 산책하기"), action: #selector(toggleWandering), keyEquivalent: "")
        wander.state = store.wanders ? .on : .off
        menu.addItem(withTitle: T("화면 가운데로 데려오기"), action: #selector(centerPet), keyEquivalent: "")
        menu.addItem(.separator())
        let updateStatus = menu.addItem(withTitle: "\(T("현재 버전")) \(updater.currentVersion) · \(T(updater.status))", action: nil, keyEquivalent: "")
        updateStatus.identifier = NSUserInterfaceItemIdentifier("update-status")
        updateStatus.isEnabled = false
        menu.addItem(withTitle: T("업데이트 확인…"), action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: T("업데이트 설치"), action: #selector(installUpdate), keyEquivalent: "")
        let automatic = menu.addItem(withTitle: T("자동 업데이트 (6시간마다)"), action: #selector(toggleAutomaticUpdates), keyEquivalent: "")
        automatic.state = store.automaticUpdates ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: T("펫 종료"), action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String, let language = AppLanguage(rawValue: code) else { return }
        store.language = language
    }

    @objc private func checkForUpdates() {
        Task {
            await updater.check()
            guard let version = updater.availableVersion else { return }
            let alert = NSAlert()
            alert.messageText = "\(T("새 버전 설치 가능")): \(version)"
            alert.informativeText = T("설치하면 펫이 다시 시작됩니다. 설정과 로그인 정보는 유지됩니다.")
            alert.addButton(withTitle: T("업데이트 설치"))
            alert.addButton(withTitle: T("나중에"))
            if alert.runModal() == .alertFirstButtonReturn { await updater.install() }
        }
    }
    @objc private func installUpdate() { Task { await updater.install() } }
    @objc private func toggleAutomaticUpdates() {
        store.automaticUpdates.toggle()
        updater.configureAutomatic(store.automaticUpdates)
    }

    @objc private func refreshUsage() { Task { await store.refresh(allowKeychainPrompt: true) } }
    @objc private func toggleWandering() { store.wanders.toggle() }
    @objc private func togglePetVisibility() { store.isPetVisible.toggle() }
    @objc private func selectPetSize(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? NSNumber else { return }
        store.setPetScale(scale.doubleValue)
    }
    @objc private func selectCharacter(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let character = PetCharacter(rawValue: name) else { return }
        store.selectedCharacter = character
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func centerPet() {
        let screen = NSScreen.main?.visibleFrame ?? petWindow.frame
        store.isPetVisible = true
        movePet(to: NSPoint(x: screen.midX - petWindow.frame.width / 2, y: screen.minY + 60))
        savePosition()
    }
    @objc private func screenChanged() { constrainPetToScreens(); closeUsage() }
    @objc private func reduceMotionChanged() {
        petView.animationEnabled = store.isPetVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func walk() {
        guard store.isPetVisible, store.wanders, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !isDragging, usageWindow == nil,
              !NSEvent.mouseLocation.isNear(petWindow.frame, padding: 24) else { return }
        let screen = petWindow.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        var origin = petWindow.frame.origin
        origin.x += direction * 0.65
        if origin.x < screen.minX + 12 { origin.x = screen.minX + 12; direction = 1 }
        if origin.x + petWindow.frame.width > screen.maxX - 12 {
            origin.x = screen.maxX - petWindow.frame.width - 12; direction = -1
        }
        petWindow.setFrameOrigin(origin)
    }

    private func constrainPetToScreens() {
        let frames = NSScreen.screens.map(\.visibleFrame)
        guard let fallback = frames.first else { return }
        let frame = petWindow.frame
        let screen = frames.first { $0.intersects(frame) } ?? fallback
        let x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        let y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        petWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func savePosition() {
        UserDefaults.standard.set(petWindow.frame.minX, forKey: "petX")
        UserDefaults.standard.set(petWindow.frame.minY, forKey: "petY")
    }
}

final class UsageWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class DraggablePetView: PixelPetView {
    weak var owner: PetAppDelegate?
    private var clickLocation = NSPoint.zero
    private var originalOrigin = NSPoint.zero
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        clickLocation = NSEvent.mouseLocation
        originalOrigin = window?.frame.origin ?? .zero
        dragged = false
        owner?.beginDragging()
    }
    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let deltaX = mouse.x - clickLocation.x
        let deltaY = mouse.y - clickLocation.y
        if hypot(deltaX, deltaY) > 3 {
            dragged = true
            owner?.closeUsage()
        }
        owner?.movePet(to: NSPoint(x: originalOrigin.x + deltaX, y: originalOrigin.y + deltaY))
    }
    override func mouseUp(with event: NSEvent) {
        owner?.endDragging()
        if !dragged { owner?.toggleUsage() }
    }
    override func rightMouseDown(with event: NSEvent) { owner?.showContextMenu(with: event) }
    override func accessibilityPerformPress() -> Bool { owner?.toggleUsage(); return true }
}

private extension NSPoint {
    func isNear(_ rectangle: NSRect, padding: CGFloat) -> Bool {
        rectangle.insetBy(dx: -padding, dy: -padding).contains(self)
    }
}
