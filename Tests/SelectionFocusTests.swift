import AppKit
import AVFoundation
import SwiftUI
@testable import MusicTag

@main struct SelectionFocusTests {
    struct Failure: Error { let message: String }

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }

    @MainActor static func settle() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    @MainActor static func musicTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.numberOfColumns == 5 { return table }
        return view.subviews.lazy.compactMap { musicTable(in: $0) }.first
    }

    @MainActor static func click(row: Int, column: Int = 0, modifiers: NSEvent.ModifierFlags = [], in table: NSTableView, window: NSWindow) {
        table.scrollColumnToVisible(column)
        table.scrollRowToVisible(row)
        let rowRect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: table.rect(ofColumn: column).midX, y: rowRect.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers, timestamp: timestamp,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: modifiers, timestamp: timestamp + 0.01,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
    }

    @MainActor static func arrow(down: Bool, window: NSWindow) {
        let character = down ? "\u{F701}" : "\u{F700}"
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: character, charactersIgnoringModifiers: character,
                                    isARepeat: false, keyCode: down ? 125 : 126)!
        NSApp.postEvent(event, atStart: false)
    }

    @MainActor static func menu(row: Int, table: NSTableView, window: NSWindow) -> NSMenu? {
        let point = table.convert(NSPoint(x: 20, y: table.rect(ofRow: row).midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
        return table.menu(for: event)
    }

    @MainActor static func run() async throws {
        let app = NSApplication.shared
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
        window.contentView = NSHostingView(rootView: MainView().environmentObject(store))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil)
            window.contentView = nil
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
        try check(window.isKeyWindow, "Mouse tests require a key window in a macOS desktop session")
        try check(window.makeFirstResponder(table), "The music table must accept keyboard focus")

        // Route clicks through the hosted window, including hit testing and tracking.
        for column in 0..<5 {
            for row in [1, 2, 0] {
                click(row: row, column: column, in: table, window: window)
                try await settle()
                try check(store.selection == [ids[row]], "Clicking column \(column) must select song \(row); native indexes: \(Array(table.selectedRowIndexes)), key window: \(window.isKeyWindow), active: \(app.isActive)")
                try check(store.first?.id == ids[row], "The inspector must follow the selected song")
                try check(window.firstResponder === table, "Changing songs must retain the table's focus")
            }
        }
        arrow(down: true, window: window)
        try await settle()
        try check(store.selection == [ids[1]], "Down arrow must select the next song")
        arrow(down: false, window: window)
        try await settle()
        try check(store.selection == [ids[0]], "Up arrow must select the previous song")
        print("PASS selection: import, mouse clicks in all five columns, inspector target, arrow keys, focus")

        click(row: 2, modifiers: .shift, in: table, window: window)
        try await settle()
        try check(store.selection == Set(ids), "Shift-click must select a range")
        click(row: 1, modifiers: .command, in: table, window: window)
        try await settle()
        try check(store.selection == Set([ids[0], ids[2]]), "Native multiselection must reach the store")
        try check(window.firstResponder === table, "Multiselection must retain table focus")
        store.set(\.album, "Selected songs", name: "album")
        try await settle()
        try check(store.selected.allSatisfy { $0.tags.album == "Selected songs" }, "Editing must apply to the selected songs")
        try check(store.tracks.first { $0.id == ids[1] }?.tags.album == "", "Editing must preserve unselected songs")
        try check(window.firstResponder === table, "Refreshing edited rows must retain table focus")
        print("PASS editing: Shift/Command clicks, batch edit targets, unselected preservation, focus after refresh")

        try check(menu(row: 2, table: table, window: window) != nil && store.selection == Set([ids[0], ids[2]]),
                  "Right-clicking a selected row must preserve multiselection")
        guard let context = menu(row: 1, table: table, window: window) else {
            throw Failure(message: "Right-clicking a song must produce a menu")
        }
        try check(store.selection == [ids[1]], "The context menu must target the right-clicked song")
        context.performActionForItem(at: context.indexOfItem(withTitle: "从列表移除"))
        try await settle()
        try check(table.numberOfRows == 2 && store.selection.isEmpty, "Menu removal must update rows and selection")
        try check((try manager.contentsOfDirectory(atPath: directory.path)).count == 3, "Removing a row must preserve music files")
        store.query = "Third"
        try await settle()
        try check(table.numberOfRows == 1, "Search must update native rows")
        click(row: 0, in: table, window: window)
        try await settle()
        try check(store.selection == [ids[2]], "Clicking filtered rows must use the visible song ID")
        store.query = ""
        try await settle()
        try check(table.selectedRow == store.visible.firstIndex { $0.id == ids[2] }, "Clearing search must preserve selection by ID")
        store.set(\.artist, "A", name: "artist")
        store.selection = [ids[0]]
        store.set(\.artist, "Z", name: "artist")
        store.sortMode = 1
        try await settle()
        try check(table.selectedRow == 1 && store.visible[1].id == ids[0], "Sorting must preserve selection by ID")
        click(row: 0, in: table, window: window)
        try await settle()
        try check(store.selection == [ids[2]], "Clicking sorted rows must target the visible song")
        print("PASS rows: context targets, multiselection menus, removal, file preservation, filtering, sorting")
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch {
                fputs("FAIL selection focus: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
