import CryptoKit
import Darwin
import Foundation

struct UsageSnapshotCache: Sendable {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    func save(_ reading: UsageReading, account: UsageAccount, fingerprint: String, now: Date) throws {
        do {
            guard Self.validFingerprint(fingerprint), reading.accountID == account.id,
                  reading.provider == account.provider, reading.source != .diskCache,
                  reading.credentialFingerprint == nil || reading.credentialFingerprint == fingerprint else {
                throw CacheFailure.invalidSnapshot
            }
            let normalized = try Self.normalized(reading, now: now)
            let binding = try Self.binding(account)
            let envelope = Envelope(
                schema: 1, binding: binding, fingerprint: fingerprint,
                fetchedAt: normalized.fetchedAt, windows: normalized.windows,
                extras: normalized.extras, accountLabel: Self.safeMetadata(reading.accountLabel),
                plan: Self.safeMetadata(reading.plan), authSource: Self.safeAuthSource(reading.authSource)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            guard data.count <= 1_048_576 else { throw CacheFailure.invalidSnapshot }
            try prepareDirectory()
            let destination = fileURL(binding: binding)
            if FileManager.default.fileExists(atPath: destination.path) {
                try validateFile(destination)
            }
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CacheFailure.unavailable
            }
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw CacheFailure.unavailable
            }
        } catch let failure as CacheFailure {
            throw failure
        } catch {
            throw CacheFailure.unavailable
        }
    }

    func load(account: UsageAccount, fingerprint: String, now: Date) -> UsageReading? {
        do {
            guard Self.validFingerprint(fingerprint) else { return nil }
            try validateDirectory()
            let binding = try Self.binding(account)
            let file = fileURL(binding: binding)
            try validateFile(file)
            let data = try Data(contentsOf: file)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schema == 1, envelope.binding == binding,
                  envelope.fingerprint == fingerprint else { return nil }
            var reading = UsageReading(provider: account.provider, windows: envelope.windows,
                                       fetchedAt: envelope.fetchedAt)
            reading.extras = envelope.extras
            reading = try Self.normalized(reading, now: now)
            reading.source = .diskCache
            reading.accountID = account.id
            reading.accountLabel = Self.safeMetadata(envelope.accountLabel)
            reading.plan = Self.safeMetadata(envelope.plan)
            reading.authSource = Self.safeAuthSource(envelope.authSource)
            reading.credentialFingerprint = fingerprint
            reading.retryAt = nil
            return reading
        } catch {
            return nil
        }
    }

    private func fileURL(binding: String) -> URL {
        directory.appendingPathComponent("\(binding).json")
    }

    private static func binding(_ account: UsageAccount) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configuration = try encoder.encode(account)
        let digest = SHA256.hash(data: configuration)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func validFingerprint(_ fingerprint: String) -> Bool {
        fingerprint.utf8.count == 64 && fingerprint.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func normalized(_ reading: UsageReading, now: Date) throws -> UsageReading {
        let fetched = reading.fetchedAt.timeIntervalSince1970
        let current = now.timeIntervalSince1970
        let age = current - fetched
        guard fetched.isFinite, current.isFinite, fetched > 0, age >= 0, age <= 86_400 else {
            throw CacheFailure.invalidSnapshot
        }
        var windows: [QuotaWindow] = []
        var metricIDs = Set<String>()
        for window in reading.windows {
            guard !window.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  metricIDs.insert(window.id).inserted,
                  window.remainingPercent.isFinite, (0...100).contains(window.remainingPercent) else {
                throw CacheFailure.invalidSnapshot
            }
            if let duration = window.durationSeconds, !duration.isFinite || duration <= 0 {
                throw CacheFailure.invalidSnapshot
            }
            if let reset = window.resetsAt {
                guard reset.timeIntervalSince1970.isFinite, reset.timeIntervalSince1970 > 0 else {
                    throw CacheFailure.invalidSnapshot
                }
                if reset <= now { continue }
            }
            let normalized = try QuotaWindow(title: window.title, usedPercent: 100 - window.remainingPercent,
                                             resetsAt: window.resetsAt, id: window.id, durationSeconds: window.durationSeconds)
            windows.append(normalized)
        }
        guard !windows.isEmpty else { throw CacheFailure.invalidSnapshot }
        var extraIDs = Set<String>()
        for extra in reading.extras {
            guard !extra.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  extraIDs.insert(extra.id).inserted,
                  extra.amount.isFinite, extra.amount >= 0 else {
                throw CacheFailure.invalidSnapshot
            }
            if let limit = extra.limit, !limit.isFinite || limit < 0 {
                throw CacheFailure.invalidSnapshot
            }
        }
        var normalized = UsageReading(provider: reading.provider, windows: windows, fetchedAt: reading.fetchedAt)
        normalized.extras = reading.extras
        return normalized
    }

    private static func safeMetadata(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.hasPrefix("~"),
              !trimmed.lowercased().contains("bearer "), !trimmed.hasPrefix("sk-"),
              !trimmed.hasPrefix("eyJ") else { return nil }
        return trimmed
    }

    private static func safeAuthSource(_ text: String?) -> String? {
        guard let text else { return nil }
        switch text {
        case "Claude credential file", "Claude Code keychain", "Claude Swap session file",
             "Claude Swap session keychain", "Claude Swap vault file", "Claude Swap vault keychain",
             "Codex auth file", "Codex home keychain", "Codex Swap auth file": return text
        default: return nil
        }
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CacheFailure.unavailable
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try validateDirectory()
    }

    private func validateDirectory() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw CacheFailure.unavailable
        }
    }

    private func validateFile(_ file: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 1_048_576 else {
            throw CacheFailure.unavailable
        }
    }

    private struct Envelope: Codable {
        let schema: Int
        let binding: String
        let fingerprint: String
        let fetchedAt: Date
        let windows: [QuotaWindow]
        let extras: [UsageExtra]
        let accountLabel: String?
        let plan: String?
        let authSource: String?
    }

    private enum CacheFailure: Error {
        case invalidSnapshot
        case unavailable
    }
}
