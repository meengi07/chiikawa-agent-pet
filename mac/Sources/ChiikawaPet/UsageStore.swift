import Combine
import Foundation

struct ProviderDisplay: Sendable {
    let provider: UsageProvider
    var reading: UsageReading?
    var error: String?
}

@MainActor
final class UsageStore: ObservableObject {
    static let defaultPetScale = 0.65
    static let petScaleRange = 0.4...1.2
    @Published private(set) var providers: [ProviderDisplay] = UsageProvider.allCases.map {
        ProviderDisplay(provider: $0)
    }
    @Published private(set) var isRefreshing = false
    @Published var language: AppLanguage {
        didSet { preferences.set(language.rawValue, forKey: "appLanguage") }
    }
    @Published var wanders: Bool {
        didSet { preferences.set(wanders, forKey: "wanders") }
    }
    @Published var selectedCharacter: PetCharacter {
        didSet { preferences.set(selectedCharacter.rawValue, forKey: "petCharacter") }
    }
    @Published private(set) var petScale: Double
    @Published var isPetVisible: Bool {
        didSet { preferences.set(isPetVisible, forKey: "petVisible") }
    }
    @Published var automaticUpdates: Bool {
        didSet { preferences.set(automaticUpdates, forKey: "automaticUpdates") }
    }
    let previewPercent: Double?
    private let usageFetching: any UsageFetching
    private let preferences: UserDefaults

    init(usageFetching: any UsageFetching, previewPercent: Double? = nil, preferences: UserDefaults = .standard) {
        self.usageFetching = usageFetching
        self.previewPercent = previewPercent
        self.preferences = preferences
        language = AppLanguage(rawValue: preferences.string(forKey: "appLanguage") ?? "en") ?? .english
        wanders = preferences.object(forKey: "wanders") as? Bool ?? true
        let savedCharacter = preferences.string(forKey: "petCharacter") ?? ""
        selectedCharacter = PetCharacter(rawValue: savedCharacter) ?? .chiikawa
        let savedScale = preferences.object(forKey: "petScale") as? Double
        if let savedScale, savedScale.isFinite, Self.petScaleRange.contains(savedScale) {
            petScale = savedScale
        } else {
            petScale = Self.defaultPetScale
        }
        isPetVisible = preferences.object(forKey: "petVisible") as? Bool ?? true
        automaticUpdates = preferences.object(forKey: "automaticUpdates") as? Bool ?? false
        if let previewPercent {
            for index in providers.indices {
                let window = try! QuotaWindow(title: "5시간", usedPercent: 100 - previewPercent, resetsAt: nil)
                providers[index].reading = UsageReading(provider: providers[index].provider, windows: [window], fetchedAt: .now)
            }
        }
    }

    var remainingPercent: Double? {
        var lowest: Double?
        for provider in providers where provider.error == nil {
            guard let percent = provider.reading?.remainingPercent else { continue }
            lowest = min(lowest ?? percent, percent)
        }
        return lowest
    }

    var mood: PetMood { .forRemaining(remainingPercent) }

    func setPetScale(_ scale: Double) {
        guard scale.isFinite else { return }
        petScale = min(max(scale, Self.petScaleRange.lowerBound), Self.petScaleRange.upperBound)
        preferences.set(petScale, forKey: "petScale")
    }

    var menuBarTitle: String {
        let claude = menuBarRemaining(for: .claude)
        let codex = menuBarRemaining(for: .codex)
        return "Claude \(claude) · Codex \(codex)"
    }

    var menuBarPresentation: MenuBarPresentation {
        let claude = providers.first { $0.provider == .claude && $0.error == nil }?.reading
        let codex = providers.first { $0.provider == .codex && $0.error == nil }?.reading
        let primary = claude?.windows.first?.remainingPercent
        let secondary = claude.flatMap { $0.windows.count > 1 ? $0.windows[1].remainingPercent : nil }
        return MenuBarPresentation(
            character: selectedCharacter, mood: mood,
            claudePrimary: primary, claudeSecondary: secondary, codex: codex?.remainingPercent
        )
    }

    private func menuBarRemaining(for provider: UsageProvider) -> String {
        guard let display = providers.first(where: { $0.provider == provider }),
              display.error == nil, let percent = display.reading?.remainingPercent else { return "—" }
        return "\(Int(percent.rounded(.down)))%"
    }

    func refresh(allowKeychainPrompt: Bool = false) async {
        guard !isRefreshing, previewPercent == nil else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await withTaskGroup(of: ProviderDisplay.self) { group in
            for provider in UsageProvider.allCases {
                let usageFetching = self.usageFetching
                group.addTask {
                    do {
                        let reading = try await usageFetching.fetch(provider, allowKeychainPrompt: allowKeychainPrompt)
                        return ProviderDisplay(provider: provider, reading: reading)
                    } catch {
                        return ProviderDisplay(provider: provider, error: error.localizedDescription)
                    }
                }
            }
            for await display in group {
                guard let index = providers.firstIndex(where: { $0.provider == display.provider }) else { continue }
                if display.error != nil {
                    providers[index].error = display.error
                } else {
                    providers[index] = display
                }
            }
        }
    }
}
