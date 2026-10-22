import Combine
import Foundation

struct AccountUsageAlerts {
    private struct Entry {
        let identity: String
        var policy = UsageAlertPolicy()
    }
    private var entries: [String: Entry] = [:]

    mutating func invalidate(accountID: String) { entries[accountID] = nil }

    mutating func evaluate(accountID: String, reading: UsageReading, now: Date,
                           thresholds: [Double], paceEnabled: Bool) -> [UsageAlertEvent] {
        guard reading.isCurrent(at: now), reading.retryAt == nil else { return [] }
        let identity: String
        if let verified = reading.accountIdentity, !verified.isEmpty {
            identity = "verified:" + verified
        } else if let fingerprint = reading.credentialFingerprint, !fingerprint.isEmpty {
            identity = "credential:" + fingerprint
        } else {
            invalidate(accountID: accountID)
            return []
        }
        var current = entries[accountID] ?? Entry(identity: identity)
        if current.identity != identity { current = Entry(identity: identity) }
        let events = current.policy.evaluate(accountID: accountID + ":" + identity, reading: reading,
            now: now, thresholds: thresholds, paceEnabled: paceEnabled)
        entries[accountID] = current
        return events
    }
}

struct ProviderDisplay: Sendable, Identifiable {
    let account: UsageAccount
    var provider: UsageProvider { account.provider }
    var id: String { account.id }
    var reading: UsageReading?
    var error: String?
    var retryAt: Date?
    var attemptedAt: Date?
    var discardsPreviousReading = false

    var currentReading: UsageReading? {
        guard error == nil, let reading, reading.isCurrent(at: .now) else { return nil }
        return reading
    }
}

struct HomeHistory: Identifiable, Sendable {
    let id: String
    let provider: UsageProvider
    let label: String
    var summary: UsageHistorySummary?
    var error: String?
}

@MainActor
final class UsageStore: ObservableObject {
    static let defaultPetScale = 0.65
    static let petScaleRange = 0.4...1.2
    @Published private(set) var providers = UsageAccount.defaults.map { ProviderDisplay(account: $0) }
    @Published private(set) var isRefreshing = false
    @Published var language: AppLanguage { didSet { preferences.set(language.rawValue, forKey: "appLanguage") } }
    @Published var wanders: Bool { didSet { preferences.set(wanders, forKey: "wanders") } }
    @Published var selectedCharacter: PetCharacter { didSet { preferences.set(selectedCharacter.rawValue, forKey: "petCharacter") } }
    @Published private(set) var petScale: Double
    @Published var isPetVisible: Bool { didSet { preferences.set(isPetVisible, forKey: "petVisible") } }
    @Published var automaticUpdates: Bool { didSet { preferences.set(automaticUpdates, forKey: "automaticUpdates") } }
    @Published var settings: UsagePreferences {
        didSet {
            let encoded = try? JSONEncoder().encode(settings)
            preferences.set(encoded, forKey: UsagePreferences.storageKey)
        }
    }
    @Published private(set) var systemError: String?
    @Published private(set) var histories: [HomeHistory] = []
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var discoveryWarning: String?
    let previewPercent: Double?
    let systemFeatures = MacSystemFeatures()
    private let usageFetching: any UsageFetching
    private let preferences: UserDefaults
    private var alertPolicy = AccountUsageAlerts()
    private var accountGeneration = 0
    private var historyGeneration = 0
    private var historyScan: Task<UsageHistorySummary, Error>?

    init(usageFetching: any UsageFetching, previewPercent: Double? = nil, preferences: UserDefaults = .standard) {
        self.usageFetching = usageFetching
        self.previewPercent = previewPercent
        self.preferences = preferences
        settings = UsagePreferences.load(from: preferences)
        language = AppLanguage(rawValue: preferences.string(forKey: "appLanguage") ?? "en") ?? .english
        wanders = preferences.object(forKey: "wanders") as? Bool ?? true
        selectedCharacter = PetCharacter(rawValue: preferences.string(forKey: "petCharacter") ?? "") ?? .chiikawa
        let savedScale = preferences.object(forKey: "petScale") as? Double
        petScale = savedScale.flatMap { $0.isFinite && Self.petScaleRange.contains($0) ? $0 : nil } ?? Self.defaultPetScale
        isPetVisible = preferences.object(forKey: "petVisible") as? Bool ?? true
        automaticUpdates = preferences.object(forKey: "automaticUpdates") as? Bool ?? false
        if let previewPercent {
            for index in providers.indices {
                let window = try! QuotaWindow(title: "5시간", usedPercent: 100 - previewPercent, resetsAt: nil, id: "session")
                providers[index].reading = UsageReading(provider: providers[index].provider, windows: [window], fetchedAt: .now)
            }
        } else {
            reloadAccounts()
        }
    }

    var visibleProviders: [ProviderDisplay] { providers.filter { !settings.hiddenAccountIDs.contains($0.id) } }

    var moodCulprit: (display: ProviderDisplay, window: QuotaWindow)? {
        var culprit: (display: ProviderDisplay, window: QuotaWindow)?
        var worstRank = Int.max
        for display in providers {
            guard settings.moodAccountID == "all" || settings.moodAccountID == display.id || settings.moodAccountID == display.provider.rawValue,
                  let reading = display.currentReading else { continue }
            for window in reading.windows {
                guard settings.moodMetricID == "all" || settings.moodMetricID == window.id else { continue }
                let expression = expression(for: window, measuredAt: reading.fetchedAt)
                let rank: Int
                switch expression {
                case .crying: rank = 0
                case .sad: rank = 1
                case .uneasy: rank = 2
                case .happy: rank = 3
                case .delighted: rank = 4
                case .unknown: rank = 5
                }
                if rank < worstRank || (rank == worstRank && window.remainingPercent < (culprit?.window.remainingPercent ?? .infinity)) {
                    worstRank = rank
                    culprit = (display, window)
                }
            }
        }
        return culprit
    }
    var remainingPercent: Double? { moodCulprit?.window.remainingPercent }
    var mood: PetMood {
        guard let culprit = moodCulprit, let reading = culprit.display.currentReading else { return .unknown }
        return expression(for: culprit.window, measuredAt: reading.fetchedAt)
    }

    private func expression(for window: QuotaWindow, measuredAt: Date) -> PetMood {
        let remainingMood = settings.mood(for: window.remainingPercent)
        guard settings.paceMood else { return remainingMood }
        let severity = UsagePace.projection(for: window, measuredAt: measuredAt, now: .now)?.severity ?? 0
        if severity >= 2 { return .crying }
        if severity == 1 && (remainingMood == .happy || remainingMood == .delighted) { return .uneasy }
        return remainingMood
    }

    func setPetScale(_ scale: Double) {
        guard scale.isFinite else { return }
        petScale = min(max(scale, Self.petScaleRange.lowerBound), Self.petScaleRange.upperBound)
        preferences.set(petScale, forKey: "petScale")
    }

    var menuBarTitle: String {
        if settings.menuPins.isEmpty {
            return UsageProvider.allCases.map { provider in
                let remaining = providers.first { $0.provider == provider }?.currentReading?.remainingPercent
                return "\(provider.rawValue) \(remaining.map { "\(Int($0.rounded(.down)))%" } ?? "—")"
            }.joined(separator: " · ")
        }
        return menuBarPresentation.metrics.map { "\($0.label) \($0.percent.map { "\(Int($0.rounded(.down)))%" } ?? "—")" }.joined(separator: " · ")
    }

    var menuBarPresentation: MenuBarPresentation {
        let claude = providers.first { $0.provider == .claude }?.currentReading
        let codex = providers.first { $0.provider == .codex }?.currentReading
        var metrics: [MenuBarMetric] = []
        for pin in settings.menuPins {
            let display = providers.first { $0.id == pin.accountID }
            let window = display?.currentReading?.windows.first { $0.id == pin.metricID }
            metrics.append(MenuBarMetric(label: "\(display?.account.label ?? T("연결 필요")) · \(window.map { T($0.title) } ?? pin.metricID)", provider: display?.provider ?? .claude, percent: window?.remainingPercent))
        }
        return MenuBarPresentation(character: selectedCharacter, mood: mood,
            claudePrimary: claude?.windows.first?.remainingPercent,
            claudeSecondary: claude.flatMap { $0.windows.count > 1 ? $0.windows[1].remainingPercent : nil },
            codex: codex?.remainingPercent, metrics: metrics, bars: settings.menuBars, compact: settings.menuCompact)
    }

    func reloadAccounts() {
        accountGeneration += 1
        let discovered = UsageAccountDiscovery.discoverWithWarnings(includeSaved: settings.discoverSavedAccounts, additional: settings.additionalAccounts)
        discoveryWarning = discovered.warnings.isEmpty ? nil : discovered.warnings.map { T($0) }.joined(separator: "\n")
        providers = discovered.accounts.map { account in
            providers.first(where: { $0.account == account }) ?? ProviderDisplay(account: account)
        }
        alertPolicy = AccountUsageAlerts()
    }

    func addHome(provider: UsageProvider, directory: URL) {
        let path = directory.standardizedFileURL.path
        guard !settings.additionalAccounts.contains(where: { $0.provider == provider && $0.directory == path }) else { return }
        let number = settings.additionalAccounts.filter { $0.provider == provider }.count + 1
        let account = UsageAccount(id: UUID().uuidString, provider: provider, label: "\(provider.rawValue) · \(T("추가 홈")) \(number)", directory: path)
        settings.additionalAccounts.append(account)
        reloadAccounts()
        Task { await refresh(); await loadHistory() }
    }

    func removeHome(id: String) {
        settings.additionalAccounts.removeAll { $0.id == id }
        settings.hiddenAccountIDs.removeAll { $0 == id }
        settings.menuPins.removeAll { $0.accountID == id }
        if settings.moodAccountID == id { settings.moodAccountID = "all" }
        reloadAccounts()
        Task { await loadHistory() }
    }

    func refresh(allowKeychainPrompt: Bool = false) async {
        guard !isRefreshing, previewPercent == nil else { return }
        isRefreshing = true
        let generation = accountGeneration
        defer {
            isRefreshing = false
            if generation != accountGeneration { Task { await refresh() } }
        }
        for display in providers where display.reading == nil {
            if let cached = await usageFetching.cached(display.account), generation == accountGeneration,
               let index = providers.firstIndex(where: { $0.id == display.id }) {
                providers[index].reading = cached
            }
        }
        guard generation == accountGeneration else { return }
        await withTaskGroup(of: ProviderDisplay.self) { group in
            for display in providers {
                let usageFetching = self.usageFetching
                group.addTask {
                    var result = ProviderDisplay(account: display.account, attemptedAt: .now)
                    do {
                        result.reading = try await usageFetching.fetch(display.account, allowKeychainPrompt: allowKeychainPrompt)
                        result.retryAt = result.reading?.retryAt
                    } catch {
                        result.error = Self.safeError(error)
                        if case UsageFailure.cooldown(let date) = error { result.retryAt = date }
                        if case UsageFailure.identityMismatch = error { result.discardsPreviousReading = true }
                        if case UsageDataFailure.identityUnavailable = error { result.discardsPreviousReading = true }
                        if case UsageFailure.accountChanged(let retry) = error {
                            result.discardsPreviousReading = true
                            result.retryAt = retry
                        }
                    }
                    return result
                }
            }
            var events: [UsageAlertEvent] = []
            for await display in group {
                guard generation == accountGeneration, let index = providers.firstIndex(where: { $0.id == display.id }) else { continue }
                if display.error != nil {
                    if display.discardsPreviousReading {
                        providers[index].reading = nil
                        alertPolicy.invalidate(accountID: display.id)
                    }
                    providers[index].error = display.error
                    providers[index].retryAt = display.retryAt
                    providers[index].attemptedAt = display.attemptedAt
                } else {
                    providers[index] = display
                    if settings.notifications, let reading = display.reading {
                        let accountEvents = alertPolicy.evaluate(accountID: display.id, reading: reading, now: .now,
                            thresholds: Array(settings.thresholds.prefix(2)), paceEnabled: settings.paceNotifications)
                        for event in accountEvents {
                            events.append(UsageAlertEvent(id: event.id,
                                metricTitle: "\(display.provider.rawValue) #\(index + 1) · \(T(event.metricTitle))", message: event.message))
                        }
                    }
                }
            }
            if !events.isEmpty { await systemFeatures.notify(events: events) }
        }
    }

    nonisolated static func safeError(_ error: Error) -> String {
        if let failure = error as? UsageFailure { return failure.localizedDescription }
        if let failure = error as? UsageDataFailure { return failure.localizedDescription }
        if let failure = error as? URLError {
            return failure.code == .timedOut ? "사용량 조회 시간이 초과되었습니다. 다시 새로고침하세요." : "사용량 서버에 연결할 수 없습니다. 네트워크를 확인하세요."
        }
        return "사용량을 읽을 수 없습니다. 연결 설정을 확인하세요."
    }

    func configureSystemFeatures(openPanel: @escaping @MainActor () -> Void, togglePanel: @escaping @MainActor () -> Void) {
        guard previewPercent == nil else { return }
        systemFeatures.openPanel = openPanel
        systemFeatures.togglePanel = togglePanel
        systemFeatures.failure = { [weak self] text in self?.systemError = text }
        systemFeatures.configureNotifications()
        systemFeatures.notificationsEnabled = settings.notifications
        var failures: [String] = []
        if let shortcut = settings.shortcut, let failure = systemFeatures.register(shortcut) { failures.append(failure) }
        if settings.launchAtLogin, let failure = systemFeatures.setLaunchAtLogin(true) { failures.append(failure) }
        settings.launchAtLogin = systemFeatures.launchAtLoginEnabled
        systemError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func setNotifications(_ enabled: Bool) {
        guard previewPercent == nil else { return }
        settings.notifications = enabled
        systemFeatures.notificationsEnabled = enabled
        alertPolicy = AccountUsageAlerts()
        guard enabled else { systemFeatures.clearNotifications(); return }
        Task {
            if let failure = await systemFeatures.requestNotificationPermission() {
                systemError = failure
                settings.notifications = false
                systemFeatures.notificationsEnabled = false
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard previewPercent == nil else { return }
        systemError = systemFeatures.setLaunchAtLogin(enabled)
        settings.launchAtLogin = systemFeatures.launchAtLoginEnabled
    }

    func setShortcut(_ shortcut: RecordedShortcut?) {
        guard previewPercent == nil else { return }
        systemError = systemFeatures.register(shortcut)
        settings.shortcut = shortcut
    }

    func resetExperience() {
        guard previewPercent == nil else { return }
        setNotifications(false)
        let loginFailure = systemFeatures.setLaunchAtLogin(false)
        setShortcut(nil)
        settings = UsagePreferences()
        settings.launchAtLogin = systemFeatures.launchAtLoginEnabled
        systemError = loginFailure
        histories = []
        isLoadingHistory = false
        historyGeneration += 1
        historyScan?.cancel()
        historyScan = nil
        reloadAccounts()
        Task { await refresh() }
    }

    func loadHistory() async {
        historyGeneration += 1
        historyScan?.cancel()
        historyScan = nil
        let generation = historyGeneration
        histories = []
        isLoadingHistory = false
        guard settings.historyEnabled, previewPercent == nil else { return }
        isLoadingHistory = true
        defer { if generation == historyGeneration { isLoadingHistory = false } }
        var seen = Set<String>()
        let pricingFile = settings.pricingFile.map { URL(fileURLWithPath: $0) }
        for display in providers {
            let account = display.account
            let canonical: URL
            do {
                canonical = try UsageAccountDiscovery.configDirectory(for: account).standardizedFileURL.resolvingSymlinksInPath()
            } catch {
                histories.append(HomeHistory(id: account.id, provider: account.provider, label: account.label,
                    error: T("사용 기록을 읽을 수 없습니다. 홈과 가격 파일을 확인하세요.")))
                continue
            }
            let identity = account.provider.rawValue + canonical.path
            guard seen.insert(identity).inserted else { continue }
            var history = HomeHistory(id: identity, provider: account.provider, label: account.label)
            let scan = Task {
                try await LocalUsageHistory.scan(provider: account.provider, directory: canonical, pricingFile: pricingFile)
            }
            historyScan = scan
            do { history.summary = try await scan.value }
            catch { history.error = T("사용 기록을 읽을 수 없습니다. 홈과 가격 파일을 확인하세요.") }
            guard generation == historyGeneration, settings.historyEnabled else { return }
            historyScan = nil
            histories.append(history)
        }
    }

    var diagnosticText: String {
        var lines = ["Chiikawa Pet · sanitized usage diagnostics", "No credentials, account identifiers, home paths or log content included."]
        for (index, display) in providers.enumerated() {
            lines.append("\(display.provider.rawValue) #\(index + 1): \(display.error == nil ? "available" : "unavailable")")
            if let reading = display.reading {
                lines.append("source=\(reading.source.rawValue), current=\(display.currentReading != nil), measured=\(ISO8601DateFormatter().string(from: reading.fetchedAt)), metrics=\(reading.windows.count)")
            }
            if let retry = display.retryAt { lines.append("retry=\(ISO8601DateFormatter().string(from: retry))") }
        }
        return lines.joined(separator: "\n")
    }
}
