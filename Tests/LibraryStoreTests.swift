import AppKit
import Foundation

@main struct LibraryStoreTests {
    struct Failure: Error { let message: String }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }
    @MainActor static func waitForIdle(_ store: LibraryStore) async throws {
        let deadline = Date().addingTimeInterval(30)
        while store.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(!store.busy, "Background operation timed out")
    }
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("MusicTag-LibraryTests-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let first = root.appendingPathComponent("Artist - First.mp3")
        let second = root.appendingPathComponent("Artist - Second.mp3")
        let readOnly = root.appendingPathComponent("ReadOnly.wave")
        try manager.copyItem(at: fixture, to: first)
        try manager.copyItem(at: fixture, to: second)
        try manager.copyItem(at: fixture.deletingLastPathComponent().appendingPathComponent("roundtrip.wav"), to: readOnly)
        try manager.createSymbolicLink(at: root.appendingPathComponent("linked.mp3"), withDestinationURL: first)
        let store = LibraryStore()
        store.importURLs([root, first])
        try await waitForIdle(store)
        try check(store.tracks.count == 3, "Import must deduplicate real paths and symbolic links")
        for item in store.tracks { print("LOAD \(item.url.lastPathComponent): duration=\(item.duration), issue=\(item.issue ?? "none")") }
        try check(store.tracks.allSatisfy { $0.issue == nil }, "Supported fixtures must not report import errors")
        try check(store.tracks.filter(\.writable).allSatisfy { $0.duration > 0 }, "Writable fixtures must have duration")
        let writable = store.tracks.filter(\.writable)
        let ids = Set(writable.map(\.id))
        store.selection = Set(store.tracks.map(\.id))
        store.tagsFromFilename()
        try check(store.dirtyCount == 2 && store.mixed(\.title), "Batch filename parsing must edit writable files only")
        store.set(\.album, "Batch Album", name: "album")
        try check(store.tracks.filter(\.writable).allSatisfy { $0.tags.album == "Batch Album" && $0.tags.artist == "Artist" }, "Batch edit must preserve unrelated fields")
        try check(store.tracks.first { !$0.writable }?.tags.album == "", "Read-only tracks must remain untouched")
        store.undo()
        try check(store.tracks.allSatisfy { $0.tags.album.isEmpty }, "Undo must restore batch values")
        store.selection = [writable[1].id]
        store.mutate(targetIDs: [writable[0].id]) { $0.lyrics = "Frozen search target" }
        try check(store.tracks.first { $0.id == writable[0].id }?.tags.lyrics == "Frozen search target", "Lookup application must keep its original target")
        try check(store.tracks.first { $0.id == writable[1].id }?.tags.lyrics == "", "Lookup must not edit a new selection")
        store.undo()
        try check(store.tracks.allSatisfy { $0.tags.lyrics.isEmpty }, "Undo must restore the lookup target")
        store.selection = ids
        store.set(\.album, "Saved Album", name: "album")
        store.save(all: true)
        store.set(\.album, "Edit during save", name: "album")
        try await waitForIdle(store)
        try check(store.dirtyCount == 0 && store.alert == nil, "Save must finish cleanly and reject concurrent edits")
        for item in store.tracks where item.writable {
            try check(try TagEngine.read(from: item.url) == item.tags, "Saved file differs from displayed values")
        }
        store.rename(pattern: "same")
        try check(store.alert != nil && manager.fileExists(atPath: first.path) && manager.fileExists(atPath: second.path), "Rename collision must preserve every original")
        store.alert = nil
        store.rename(pattern: "{title} - {artist}")
        try check(store.alert == nil && store.tracks.filter(\.writable).allSatisfy { manager.fileExists(atPath: $0.url.path) }, "Rename must update paths to existing files")
        store.set(\.genre, "Jazz", name: "genre")
        store.revertSelected()
        try check(store.dirtyCount == 0, "Revert must restore last saved tags")
        store.removeSelected()
        try check(store.tracks.count == 1 && store.selection.isEmpty, "Removing music must update selection")
        try check(try manager.contentsOfDirectory(atPath: root.path).count == 4, "Removing from library must preserve files")
        print("PASS library: recursive import, symlink deduplication, duration, mixed batch editing, read-only protection")
        print("PASS editing: undo, frozen lookup targets, concurrent save protection, disk round trip, revert")
        print("PASS files: rename collision preserves originals, successful rename, removal keeps files")
    }
}
