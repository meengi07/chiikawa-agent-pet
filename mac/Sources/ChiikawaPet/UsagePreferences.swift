import Carbon
import Foundation

struct MenuPin: Codable, Equatable, Identifiable, Sendable {
    var accountID: String
    var metricID: String
    var id: String { accountID + ":" + metricID }
}

struct RecordedShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
}

enum HistoryPeriod: String, Codable, CaseIterable, Identifiable {
    case today, yesterday, last30
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: T("오늘")
        case .yesterday: T("어제")
        case .last30: T("최근 30일")
        }
    }
    func days(from days: [UsageHistoryDay], now: Date = .now, calendar: Calendar = .current) -> [UsageHistoryDay] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        switch self {
        case .today: start = today; end = today
        case .yesterday:
            start = calendar.date(byAdding: .day, value: -1, to: today)!
            end = start
        case .last30:
            start = calendar.date(byAdding: .day, value: -29, to: today)!
            end = today
        }
        let firstDay = formatter.string(from: start)
        let lastDay = formatter.string(from: end)
        return days.filter { $0.day >= firstDay && $0.day <= lastDay }
    }
}

struct UsagePreferences: Codable, Equatable, Sendable {
    var version = 1
    var moodAccountID = "all"
    var moodMetricID = "all"
    var thresholds: [Double] = [10, 30, 60, 95]
    var paceMood = false
    var menuPins: [MenuPin] = []
    var menuBars = false
    var menuCompact = false
    var countdown = false
    var showPace = false
    var notifications = false
    var paceNotifications = false
    var launchAtLogin = false
    var shortcut: RecordedShortcut? = nil
    var discoverSavedAccounts = false
    var additionalAccounts: [UsageAccount] = []
    var hiddenAccountIDs: [String] = []
    var historyEnabled = false
    var historyPeriod: HistoryPeriod = .last30
    var pricingFile: String? = nil

    static let storageKey = "usageExperience.v1"

    static func load(from defaults: UserDefaults) -> UsagePreferences {
        guard let data = defaults.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(Self.self, from: data), settings.version == 1 else { return Self() }
        settings.normalize()
        return settings
    }

    mutating func normalize() {
        if thresholds.count != 4 || thresholds.contains(where: { !$0.isFinite || !(0...100).contains($0) }) {
            thresholds = [10, 30, 60, 95]
        }
        thresholds.sort()
        var accountIDs = Set<String>()
        additionalAccounts = additionalAccounts.filter { account in
            guard let directory = account.directory, directory.hasPrefix("/"), !directory.contains("\0"),
                  !UsageAccount.defaults.contains(where: { $0.id == account.id }) else { return false }
            return accountIDs.insert(account.id).inserted
        }
        var pins = Set<String>()
        menuPins = menuPins.filter { !$0.accountID.isEmpty && !$0.metricID.isEmpty && pins.insert($0.id).inserted }
        if let shortcut, shortcut.modifiers & UInt32(cmdKey | optionKey | controlKey) == 0 || shortcut.keyCode > 127 { self.shortcut = nil }
        if let pricingFile, !pricingFile.hasPrefix("/") { self.pricingFile = nil }
    }

    func mood(for remaining: Double?) -> PetMood {
        guard let remaining else { return .unknown }
        if remaining <= thresholds[0] { return .crying }
        if remaining < thresholds[1] { return .sad }
        if remaining < thresholds[2] { return .uneasy }
        if remaining < thresholds[3] { return .happy }
        return .delighted
    }
}
