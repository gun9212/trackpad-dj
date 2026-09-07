import CryptoKit
import Foundation

enum HotCueSlot: Int, CaseIterable, Codable, Sendable {
    case one = 1, two, three, four
    var index: Int { rawValue - 1 }
}

struct TrackID: Hashable, Codable, Sendable {
    let digest: String

    static func fingerprint(url: URL) throws -> TrackID {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return TrackID(digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

enum HotCueStorageError: LocalizedError {
    case invalidFile
    var errorDescription: String? { "Hot cue file is invalid or unsupported; original file preserved." }
}

/// Serialized file access. A bad existing file is never replaced by a new empty document.
actor HotCueStore {
    private struct Document: Codable {
        let version: Int
        let trackID: TrackID
        let positions: [Double?]
    }
    private let directory: URL
    private var latestRevision: [TrackID: UInt64] = [:]

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TrackpadDJ/HotCues", isDirectory: true)) {
        self.directory = directory
    }

    func load(_ id: TrackID) throws -> [Double?] {
        let url = try fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return Array(repeating: nil, count: 4) }
        let doc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard doc.version == 1, doc.trackID == id, doc.positions.count == 4,
              doc.positions.compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw HotCueStorageError.invalidFile
        }
        return doc.positions
    }

    func save(_ positions: [Double?], for id: TrackID, revision: UInt64) throws {
        guard revision >= latestRevision[id, default: 0] else { return }
        latestRevision[id] = revision
        _ = try load(id) // Validate existing data before any overwrite.
        guard positions.count == 4,
              positions.compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw HotCueStorageError.invalidFile
        }
        let data = try JSONEncoder().encode(Document(version: 1, trackID: id, positions: positions))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(id), options: .atomic)
    }

    private func fileURL(_ id: TrackID) throws -> URL {
        guard id.digest.count == 64, id.digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw HotCueStorageError.invalidFile
        }
        return directory.appendingPathComponent(id.digest).appendingPathExtension("json")
    }
}

/// Main-actor cache shared by both decks; disk completions cannot overwrite newer edits.
@MainActor
final class HotCueLibrary {
    private let store: HotCueStore
    private var positions: [TrackID: [Double?]] = [:]
    private var revisions: [TrackID: UInt64] = [:]
    private var errors: [TrackID: String] = [:]
    private var dirty: Set<TrackID> = []
    private var pending: [UUID: Task<Void, Never>] = [:]

    init(store: HotCueStore = HotCueStore()) { self.store = store }

    func restore(_ id: TrackID) async {
        guard positions[id] == nil else { return }
        do {
            let restored = try await store.load(id)
            if positions[id] == nil { positions[id] = restored }
        } catch {
            if positions[id] == nil {
                positions[id] = Array(repeating: nil, count: 4)
                errors[id] = error.localizedDescription
            }
        }
    }

    func cues(for id: TrackID) -> [Double?] { positions[id] ?? Array(repeating: nil, count: 4) }

    func status(for id: TrackID) -> String? {
        if let error = errors[id] { return "HOT CUE NOT SAVED · \(error)" }
        return dirty.contains(id) ? "SAVING HOT CUES…" : nil
    }

    func update(_ cues: [Double?], for id: TrackID) {
        positions[id] = cues
        revisions[id, default: 0] &+= 1
        dirty.insert(id)
        save(id)
    }

    private func save(_ id: TrackID) {
        let revision = revisions[id, default: 0]
        let cues = cues(for: id)
        let token = UUID()
        pending[token] = Task { [self] in
            defer { pending[token] = nil }
            do {
                try await store.save(cues, for: id, revision: revision)
                if revisions[id, default: 0] == revision {
                    dirty.remove(id)
                    errors[id] = nil
                }
            } catch {
                if revisions[id, default: 0] == revision { errors[id] = error.localizedDescription }
            }
        }
    }

    func flush() async -> Bool {
        for id in dirty { save(id) }
        while !pending.isEmpty {
            let tasks = Array(pending.values)
            for task in tasks { await task.value }
        }
        return dirty.isEmpty
    }
}
