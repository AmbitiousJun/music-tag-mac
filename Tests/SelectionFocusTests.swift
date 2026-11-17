import AppKit
import AVFoundation
import SwiftUI
@testable import MusicTag

// A command-line UI test has no foreground window. Expose its hosted window so
// selection observers see the same key window they would see in the running app.
@MainActor final class SelectionTestApplication: NSApplication {
    var hostedWindow: NSWindow?
    override var keyWindow: NSWindow? { hostedWindow ?? super.keyWindow }
}

@main struct SelectionFocusTests {
    struct Failure: Error { let message: String }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    @MainActor static func settle() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    @MainActor static func musicTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.numberOfColumns == 5 { return table }
        return view.subviews.lazy.compactMap { musicTable(in: $0) }.first
    }

    @MainActor static func run() async throws {
        let app = SelectionTestApplication.shared as! SelectionTestApplication
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("MusicTag-SelectionTests-\(UUID())")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)!
        buffer.frameLength = 800
        buffer.floatChannelData![0].initialize(repeating: 0, count: 800)
        for name in ["First", "Second", "Third"] {
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent("\(name).wav"), settings: format.settings)
            try file.write(from: buffer)
        }

        let suite = "MusicTag-SelectionTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        app.hostedWindow = window
        window.contentView = NSHostingView(rootView: MainView().environmentObject(store))
        defer {
            window.orderOut(nil)
            window.contentView = nil
            app.hostedWindow = nil
        }
        // Lay out the empty library before importing, matching the folder picker flow.
        window.contentView?.layoutSubtreeIfNeeded()
        try await settle()
        store.importURLs([directory])
        let deadline = Date().addingTimeInterval(15)
        while store.busy && Date() < deadline { try await settle() }
        try check(!store.busy && store.tracks.count == 3, "Directory import did not finish")
        try await settle()
        window.contentView?.layoutSubtreeIfNeeded()
        guard let table = musicTable(in: window.contentView!), table.numberOfRows == 3 else {
            throw Failure(message: "The imported music table was not rendered")
        }
        let ids = store.visible.map(\.id)
        try check(store.selection == [ids[0]], "Import must initially select the first song")
        try check(window.makeFirstResponder(table), "The music table must accept keyboard focus")

        // Drive the real NSTableView selection delegate, without opening a context menu.
        for row in [1, 2, 0, 1] {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            try await settle()
            try check(store.selection == [ids[row]], "Native row selection must update the editor target")
            try check(store.first?.id == ids[row], "The inspector must follow the selected song")
            try check(window.firstResponder === table, "Changing songs must retain the table's focus")
        }
        print("PASS selection: directory import, initial selection, repeated row changes, inspector target, table focus")

        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        try await settle()
        try check(store.selection == Set([ids[0], ids[2]]), "Native multiselection must reach the store")
        try check(window.firstResponder === table, "Multiselection must retain table focus")
        store.set(\.album, "Selected songs", name: "album")
        try await settle()
        try check(store.selected.allSatisfy { $0.tags.album == "Selected songs" }, "Editing must apply to the selected songs")
        try check(store.tracks.first { $0.id == ids[1] }?.tags.album == "", "Editing must preserve unselected songs")
        try check(window.firstResponder === table, "Refreshing edited rows must retain table focus")
        print("PASS editing: native multiselection, selected targets, unselected song preservation, focus after refresh")
    }

    @MainActor static func main() async {
        do { try await run() }
        catch {
            fputs("FAIL selection focus: \(error)\n", stderr)
            exit(1)
        }
    }
}
