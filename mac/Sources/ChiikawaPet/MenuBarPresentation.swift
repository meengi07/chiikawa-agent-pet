struct MenuBarMetric: Equatable {
    let label: String
    let provider: UsageProvider
    let percent: Double?
}

struct MenuBarPresentation: Equatable {
    let character: PetCharacter
    let mood: PetMood
    let claudePrimary: Double?
    let claudeSecondary: Double?
    let codex: Double?
    var metrics: [MenuBarMetric] = []
    var bars = false
    var compact = false

    var displayedMetrics: [MenuBarMetric] {
        if !metrics.isEmpty { return metrics }
        var defaults = [MenuBarMetric(label: "Claude", provider: .claude, percent: claudePrimary)]
        if let claudeSecondary { defaults.append(MenuBarMetric(label: "Claude", provider: .claude, percent: claudeSecondary)) }
        defaults.append(MenuBarMetric(label: "Codex", provider: .codex, percent: codex))
        return defaults
    }
}
