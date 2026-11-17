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
    @MainActor static func testDirectoryRestore(fixture: URL, root: URL, defaults: UserDefaults) async throws {
        let manager = FileManager.default
        let firstDirectory = root.appendingPathComponent("First Library")
        let nested = firstDirectory.appendingPathComponent("Nested")
        let secondDirectory = root.appendingPathComponent("Second Library")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try manager.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let firstSong = nested.appendingPathComponent("first.mp3")
        let secondSong = secondDirectory.appendingPathComponent("second.mp3")
        try manager.copyItem(at: fixture, to: firstSong)
        try manager.copyItem(at: fixture, to: secondSong)

        let fresh = LibraryStore(defaults: defaults)
        fresh.restoreLastDirectories()
        try check(fresh.tracks.isEmpty && !fresh.busy && fresh.alert == nil, "First launch must stay empty without a saved directory")

        let original = LibraryStore(defaults: defaults)
        original.importURLs([firstDirectory])
        try await waitForIdle(original)
        original.set(\.title, "Unsaved title", name: "title")
        let restored = LibraryStore(defaults: defaults)
        restored.restoreLastDirectories()
        try await waitForIdle(restored)
        try check(restored.tracks.map(\.url) == [firstSong], "A new store must recursively restore the last directory")
        try check(restored.dirtyCount == 0 && restored.first?.tags.title != "Unsaved title", "Restoration must read tags from disk")
        restored.restoreLastDirectories()
        try check(!restored.busy && restored.tracks.count == 1, "Startup restoration must run only once")

        original.importURLs([secondDirectory])
        try await waitForIdle(original)
        original.importURLs([firstSong])
        try await waitForIdle(original)
        let latest = LibraryStore(defaults: defaults)
        latest.restoreLastDirectories()
        try await waitForIdle(latest)
        try check(latest.tracks.map(\.url) == [secondSong], "The latest directory must replace the previous one; file imports must preserve it")

        original.importURLs([firstDirectory, secondDirectory])
        try await waitForIdle(original)
        let multiple = LibraryStore(defaults: defaults)
        multiple.restoreLastDirectories()
        try await waitForIdle(multiple)
        try check(Set(multiple.tracks.map(\.url)) == Set([firstSong, secondSong]), "All directories in the last selection must be restored")
        try manager.removeItem(at: firstDirectory)
        let partiallyMissing = LibraryStore(defaults: defaults)
        partiallyMissing.restoreLastDirectories()
        try await waitForIdle(partiallyMissing)
        try check(partiallyMissing.tracks.map(\.url) == [secondSong], "Missing directories must not prevent existing directories from loading")
        try manager.removeItem(at: secondDirectory)
        let missing = LibraryStore(defaults: defaults)
        missing.restoreLastDirectories()
        try check(missing.tracks.isEmpty && !missing.busy && missing.alert == nil, "Deleted directories must leave an empty library without an alert")
        try Data().write(to: secondDirectory)
        let replaced = LibraryStore(defaults: defaults)
        replaced.restoreLastDirectories()
        try check(replaced.tracks.isEmpty && !replaced.busy, "A file replacing the saved directory must not be imported")
        try manager.removeItem(at: secondDirectory)
        try manager.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let empty = LibraryStore(defaults: defaults)
        empty.restoreLastDirectories()
        try await waitForIdle(empty)
        try check(empty.tracks.isEmpty && empty.alert == nil, "Existing empty directories must restore cleanly")
        try manager.copyItem(at: fixture, to: secondSong)
        let rescanned = LibraryStore(defaults: defaults)
        rescanned.restoreLastDirectories()
        try await waitForIdle(rescanned)
        try check(rescanned.tracks.map(\.url) == [secondSong], "Restoration must rescan current directory contents")

        let explicit = LibraryStore(defaults: defaults)
        explicit.importURLs([fixture])
        explicit.restoreLastDirectories()
        try await waitForIdle(explicit)
        try check(explicit.tracks.map(\.url) == [fixture], "An explicit launch import must take precedence over restoration")
        print("PASS restoration: first launch, relaunch, latest selection, file imports, multiple directories, missing/replaced/empty directories, rescan, one-time startup")
    }
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("MusicTag-LibraryTests-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let suiteName = "MusicTag-LibraryTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoreRoot = root.appendingPathComponent("RestoreTests")
        try await testDirectoryRestore(fixture: fixture, root: restoreRoot, defaults: defaults)
        try manager.removeItem(at: restoreRoot)
        let first = root.appendingPathComponent("Artist - First.mp3")
        let second = root.appendingPathComponent("Artist - Second.mp3")
        let readOnly = root.appendingPathComponent("ReadOnly.wave")
        try manager.copyItem(at: fixture, to: first)
        try manager.copyItem(at: fixture, to: second)
        try manager.copyItem(at: fixture.deletingLastPathComponent().appendingPathComponent("roundtrip.wav"), to: readOnly)
        try manager.createSymbolicLink(at: root.appendingPathComponent("linked.mp3"), withDestinationURL: first)
        let store = LibraryStore(defaults: defaults)
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
