import Foundation
import CoreGraphics
import Testing
@testable import ChiikawaPet

struct CharacterTests {
    @Test @MainActor func allCharacterMenuBarSpritesRender() {
        for character in PetCharacter.allCases {
            for mood in [PetMood.delighted, .happy, .uneasy, .sad, .crying, .unknown] {
                let image = PixelPetView.menuBarImage(character: character, mood: mood)
                #expect(image.size.width == 20 && image.size.height == 20)
            }
        }
    }

    @Test @MainActor func momongaFramesHaveTransparentBorders() throws {
        let frames = try #require(PixelPetView.frames[.momonga])
        #expect(frames.count == 48)
        for frame in frames {
            #expect(frame.width == 64 && frame.height == 80)
            let context = try #require(CGContext(data: nil, width: 64, height: 80,
                bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 64, height: 80))
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            for y in 0..<80 {
                for x in [0, 1, 62, 63] {
                    #expect(pixels[(y * 64 + x) * 4 + 3] <= 1)
                }
            }
            for x in 0..<64 {
                for y in [0, 1, 78, 79] {
                    #expect(pixels[(y * 64 + x) * 4 + 3] <= 1)
                }
            }
            // Feet remain near the shared ground baseline, rather than floating above it.
            let hasFeetAtBaseline = (73...76).contains { y in
                (0..<64).contains { x in pixels[(y * 64 + x) * 4 + 3] > 128 }
            }
            #expect(hasFeetAtBaseline)
        }
    }

    @Test @MainActor func selectionAndWanderingPersistAcrossStoreRecreation() throws {
        let suiteName = "CharacterTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = UsageStore(usageFetching: UsageClient(), preferences: preferences)
        #expect(store.selectedCharacter == .chiikawa)
        #expect(store.wanders)
        store.wanders = false

        for character in PetCharacter.allCases {
            store.selectedCharacter = character
            let reopenedPreferences = try #require(UserDefaults(suiteName: suiteName))
            let restored = UsageStore(usageFetching: UsageClient(), preferences: reopenedPreferences)
            #expect(restored.selectedCharacter == character)
            #expect(!restored.wanders)
        }
    }

    @Test @MainActor func invalidSavedCharacterFallsBackSafely() throws {
        let suiteName = "CharacterTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let invalidCharacters: [Any] = ["removed-character", "", "HACHIWARE", 42]
        for invalid in invalidCharacters {
            preferences.set(invalid, forKey: "petCharacter")
            let store = UsageStore(usageFetching: UsageClient(), preferences: preferences)
            #expect(store.selectedCharacter == .chiikawa)
        }
    }

    @Test(arguments: [90.0, 89.0]) @MainActor
    func selectionPreservesDecodedQuotaAndCryingBoundary(claudeUsedPercent: Double) async throws {
        let suiteName = "CharacterTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let claudeUsage = Data("{\"five_hour\":{\"utilization\":20},\"seven_day_sonnet\":{\"utilization\":\(claudeUsedPercent)}}".utf8)
        let codexUsage = Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}}}"#.utf8)
        let usageFetching = CharacterFixtureUsage(claudeUsage: claudeUsage, codexUsage: codexUsage)
        let store = UsageStore(usageFetching: usageFetching, preferences: preferences)
        await store.refresh()
        let remainingPercent = 100 - claudeUsedPercent
        let expectedMood: PetMood = claudeUsedPercent == 90 ? .crying : .sad
        #expect(store.remainingPercent == remainingPercent)
        #expect(store.mood == expectedMood)
        let readings = store.providers.compactMap(\.reading)
        #expect(readings.count == 2)

        for character in PetCharacter.allCases {
            store.selectedCharacter = character
            #expect(store.remainingPercent == remainingPercent)
            #expect(store.mood == expectedMood)
            for original in readings {
                let current = try #require(store.providers.first { $0.provider == original.provider }?.reading)
                #expect(current.windows == original.windows)
                #expect(current.fetchedAt == original.fetchedAt)
            }
        }
    }
}

private struct CharacterFixtureUsage: UsageFetching {
    let claudeUsage: Data
    let codexUsage: Data

    func cached(_ account: UsageAccount) async -> UsageReading? { nil }

    func fetch(_ account: UsageAccount, allowKeychainPrompt: Bool) async throws -> UsageReading {
        let provider = account.provider
        let now = Date()
        switch provider {
        case .claude: return try UsageClient.decodeClaude(claudeUsage, now: now)
        case .codex: return try UsageClient.decodeCodex(codexUsage, now: now)
        }
    }
}
