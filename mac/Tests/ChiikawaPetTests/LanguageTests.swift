import Foundation
import Testing
@testable import ChiikawaPet

struct LanguageTests {
    @Test @MainActor func languageDefaultsAndPersists() throws {
        let suite = "LanguageTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = UsageStore(usageFetching: UsageClient(), preferences: preferences)
        #expect(store.language == .english)
        store.language = .korean
        #expect(UsageStore(usageFetching: UsageClient(), preferences: preferences).language == .korean)
        preferences.set("invalid", forKey: "appLanguage")
        #expect(UsageStore(usageFetching: UsageClient(), preferences: preferences).language == .english)
    }

}
