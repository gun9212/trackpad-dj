import Foundation
import XCTest
@testable import TrackpadDJ

final class HotCueStoreTests: XCTestCase {
    private let id = TrackID(digest: String(repeating: "a", count: 64))

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testRoundTripAndOlderSaveCannotReplaceNewerRevision() async throws {
        let dir = try directory()
        let store = HotCueStore(directory: dir)
        try await store.save([0, 12.25, nil, 99], for: id, revision: 2)
        try await store.save([nil, nil, nil, nil], for: id, revision: 1)
        let restored = try await HotCueStore(directory: dir).load(id)
        XCTAssertEqual(restored, [0, 12.25, nil, 99])
    }

    func testCorruptFileIsPreserved() async throws {
        let dir = try directory()
        let url = dir.appendingPathComponent(id.digest + ".json")
        let original = Data("not JSON".utf8)
        try original.write(to: url)
        let store = HotCueStore(directory: dir)
        do {
            try await store.save([1, nil, nil, nil], for: id, revision: 1)
            XCTFail("Corrupt file must not be overwritten")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFingerprintFollowsContentNotFileName() throws {
        let dir = try directory()
        let a = dir.appendingPathComponent("a.wav")
        let b = dir.appendingPathComponent("b.wav")
        try Data("first track".utf8).write(to: a)
        let original = try TrackID.fingerprint(url: a)
        try FileManager.default.moveItem(at: a, to: b)
        XCTAssertEqual(original, try TrackID.fingerprint(url: b))
        try Data("second track".utf8).write(to: b)
        XCTAssertNotEqual(original, try TrackID.fingerprint(url: b))
    }

    @MainActor
    func testLibraryRestoresAndFlushesLatestEdits() async throws {
        let dir = try directory()
        let library = HotCueLibrary(store: HotCueStore(directory: dir))
        await library.restore(id)
        library.update([1, nil, nil, nil], for: id)
        library.update([2, 3, nil, nil], for: id)
        XCTAssertNotNil(library.status(for: id))
        let flushed = await library.flush()
        XCTAssertTrue(flushed)
        let next = HotCueLibrary(store: HotCueStore(directory: dir))
        await next.restore(id)
        XCTAssertEqual(next.cues(for: id), [2, 3, nil, nil])
        XCTAssertNil(library.status(for: id))
    }

    @MainActor
    func testSaveFailureKeepsSessionCuesAndReportsUnsaved() async throws {
        let dir = try directory().appendingPathComponent("not-a-directory")
        try Data().write(to: dir)
        let library = HotCueLibrary(store: HotCueStore(directory: dir))
        await library.restore(id)
        library.update([5, nil, nil, nil], for: id)
        let flushed = await library.flush()
        XCTAssertFalse(flushed)
        XCTAssertEqual(library.cues(for: id), [5, nil, nil, nil])
        XCTAssertTrue(library.status(for: id)?.contains("NOT SAVED") == true)
    }
}
