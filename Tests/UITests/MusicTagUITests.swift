import AppKit
import XCTest

final class MusicTagUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixtures: UITestFixtures!
    private var session: String!
    private var suite: String { "app.musictag.mac.uitesting.\(session!)" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MusicTag-XCUITest-\(session!)")
        fixtures = try UITestFixtures.create(at: root)
        app = XCUIApplication()
        // ASCII fixture input must not request activation of a user's third-party IME.
        app.launchArguments = ["--ui-test-session", session, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        try expectLabel("library.count", "0 首音乐")
    }

    override func tearDownWithError() throws {
        if app?.state == .runningForeground || app?.state == .runningBackground {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Final app state"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Accessibility tree"
            tree.lifetime = .keepAlways
            add(tree)
            app.terminate()
        }
        if let fixtures {
            if testRun?.hasSucceeded == false {
                for case let url as URL in FileManager.default.enumerator(at: fixtures.root, includingPropertiesForKeys: [.isRegularFileKey])! {
                    if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        let attachment = XCTAttachment(contentsOfFile: url)
                        attachment.name = url.lastPathComponent
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
            try FileManager.default.removeItem(at: fixtures.root)
        }
        if session != nil { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    func testFolderImportSelectionSearchAndDuplicates() throws {
        // Exercise cancellation and the real folder picker before importing.
        app.typeKey("o", modifierFlags: [.command, .shift])
        let cancel = app.buttons["CancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        try expectLabel("library.count", "0 首音乐")
        try importFolder()
        try expectValue(app.textFields["tag.标题"], "First Song")
        try selectSong(1)
        try expectValue(app.textFields["tag.标题"], "Second Song")
        app.typeKey(.downArrow, modifierFlags: [])
        try expectValue(app.textFields["tag.标题"], "Third Song")
        app.typeKey(.upArrow, modifierFlags: [.shift])
        try expectLabel("library.selectionCount", "已选 2 首")
        try selectSong(0)
        XCUIElement.perform(withKeyModifiers: .command) { row(2).click() }
        try expectLabel("library.selectionCount", "已选 2 首")
        try replace(app.textFields["library.search"], with: "Second")
        try waitUntil("Search must narrow the native table") { self.table.tableRows.count == 1 }
        XCTAssertTrue(row(1).exists)
        try replace(app.textFields["library.search"], with: "")
        try waitUntil("Clearing search restores all rows") { self.table.tableRows.count == 3 }
        try importFolder()
        try expectLabel("library.status", "未发现新的音乐文件")
        try expectLabel("library.count", "3 首音乐")
        try verifyAudio()
    }

    func testFileImportDoesNotRememberItsParentFolder() throws {
        app.typeKey("o", modifierFlags: [.command])
        try choosePath(fixtures.songs[1])
        try expectLabel("library.count", "1 首音乐")
        try expectValue(app.textFields["tag.标题"], "Second Song")
        try expectValue(app.textFields["tag.艺术家"], "Artist 2")
        XCTAssertEqual(table.tableRows.count, 1)
        try verifyAudio()
        app.terminate()
        app.launch()
        app.activate()
        try expectLabel("library.count", "0 首音乐")
    }

    func testBatchEditingUndoRevertAndSaveScopes() throws {
        try importFolder()
        try selectSong(0)
        XCUIElement.perform(withKeyModifiers: .command) { row(2).click() }
        try expectLabel("library.selectionCount", "已选 2 首")
        try replace(app.textFields["tag.专辑"], with: "Batch Album")
        try expectLabel("library.dirtyCount", "2 首待保存")
        app.buttons["toolbar.undo"].firstMatch.click()
        try waitUntil("Undo restores both songs") { !self.app.staticTexts["library.dirtyCount"].exists }
        try replace(app.textFields["tag.专辑"], with: "Batch Album")
        app.buttons["inspector.revert"].click()
        try waitUntil("Revert restores the saved values") { !self.app.staticTexts["library.dirtyCount"].exists }
        try replace(app.textFields["tag.专辑"], with: "Batch Album")
        try selectSong(1)
        try expectValue(app.textFields["tag.专辑"], "Original Album 2")
        try replace(app.textFields["tag.标题"], with: "Saved Second")
        app.typeKey("s", modifierFlags: [.command])
        try expectLabel("library.status", "已保存 1 首音乐")
        try expectLabel("library.dirtyCount", "2 首待保存")
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[1]).title, "Saved Second")
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[0]).album, "Original Album 1")
        app.typeKey("s", modifierFlags: [.command, .shift])
        try expectLabel("library.status", "已保存 2 首音乐")
        try waitUntil("All changes were saved") { !self.app.staticTexts["library.dirtyCount"].exists }
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[0]).album, "Batch Album")
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[2]).album, "Batch Album")
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[1]).album, "Original Album 2")
        try verifyAudio()
        app.terminate()
        app.launch()
        app.activate()
        try expectLabel("library.count", "3 首音乐")
        try selectSong(1)
        try expectValue(app.textFields["tag.标题"], "Saved Second")
        try expectValue(app.textFields["tag.专辑"], "Original Album 2")
        try selectSong(2)
        try expectValue(app.textFields["tag.专辑"], "Batch Album")
    }

    func testArtworkLyricsExportAndPersistence() throws {
        try importFolder()
        try selectSong(0)
        app.buttons["artwork.choose"].click()
        try choosePath(fixtures.cover)
        app.menuBars.menuBarItems["音乐"].click()
        app.menuItems["导入歌词…"].click()
        try choosePath(fixtures.lyrics)
        app.radioButtons["歌词"].click()
        let imported = try String(contentsOf: fixtures.lyrics)
        let editor = try findLyricsEditor()
        try expectValue(editor, imported)
        let text = imported + "[00:02.00]Edited in the lyrics editor\n"
        try replace(editor, with: text, tabToCommit: false)
        app.buttons["inspector.save"].click()
        try expectLabel("library.status", "已保存 1 首音乐")
        let tags = try TagEngine.read(from: fixtures.songs[0])
        XCTAssertEqual(tags.lyrics, text)
        let image = try XCTUnwrap(tags.artwork)
        XCTAssertNotNil(NSImage(data: image))
        app.menuBars.menuBarItems["音乐"].click()
        app.menuItems["导出歌词…"].click()
        let export = fixtures.root.appendingPathComponent("export.lrc")
        try choosePath(export, saving: true)
        try waitUntil("Lyrics export creates a file") { FileManager.default.fileExists(atPath: export.path) }
        XCTAssertEqual(try String(contentsOf: export), text)
        try verifyAudio()
        app.terminate()
        app.launch()
        app.activate()
        try expectLabel("library.count", "3 首音乐")
        try selectSong(0)
        app.radioButtons["歌词"].click()
        try expectValue(findLyricsEditor(), text)
        XCTAssertFalse(app.buttons["inspector.save"].isEnabled)
    }

    func testRenameContextMenuAndRemovePreservesFiles() throws {
        try importFolder()
        try selectSong(0)
        row(0).rightClick()
        table.menuItems["标签 → 文件名…"].click()
        let pattern = app.textFields["rename.pattern"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 5))
        try replace(pattern, with: "{title}")
        app.buttons["重命名 1 个文件"].click()
        let renamed = fixtures.songs[0].deletingLastPathComponent().appendingPathComponent("First Song.wav")
        try waitUntil("Rename updates the original file") { FileManager.default.fileExists(atPath: renamed.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtures.songs[0].path))
        XCTAssertEqual(try UITestFixtures.audioHash(at: renamed), fixtures.audioHashes[0])
        let renamedRow = table.staticTexts["track.First Song.wav.filename"]
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 5))
        renamedRow.rightClick()
        table.menuItems["从列表移除"].click()
        try expectLabel("library.count", "2 首音乐")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(try TagEngine.read(from: renamed).title, "First Song")
    }

    func testUnsavedQuitCanReturnToEditingOrDiscard() throws {
        try importFolder()
        try replace(app.textFields["tag.标题"], with: "Unsaved title")
        app.typeKey("q", modifierFlags: [.command])
        let back = app.dialogs.buttons["返回编辑"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.click()
        try expectValue(app.textFields["tag.标题"], "Unsaved title")
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[0]).title, "First Song")
        app.typeKey("q", modifierFlags: [.command])
        let discard = app.dialogs.buttons["丢弃并退出"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        app.activate()
        try expectLabel("library.count", "3 首音乐")
        try expectValue(app.textFields["tag.标题"], "First Song")
        try verifyAudio()
    }

    private var table: XCUIElement { app.tables["library.table"] }

    private func findLyricsEditor() throws -> XCUIElement {
        // SwiftUI exposes the identifier on the text view on macOS 15 and on
        // its enclosing scroll view on macOS 13.
        let editor = app.textViews["tag.lyrics"]
        let enclosedEditor = app.scrollViews["tag.lyrics"].textViews.firstMatch
        try waitUntil("The lyrics text editor appears") { editor.exists || enclosedEditor.exists }
        return editor.exists ? editor : enclosedEditor
    }

    private func row(_ index: Int) -> XCUIElement {
        table.staticTexts["track.\(fixtures.songs[index].lastPathComponent).filename"]
    }
    private func selectSong(_ index: Int) throws {
        app.activate()
        let target = row(index)
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.click()
        try expectLabel("library.selectionCount", "已选 1 首")
    }
    private func importFolder() throws {
        app.activate()
        app.typeKey("o", modifierFlags: [.command, .shift])
        try choosePath(fixtures.music)
        try expectLabel("library.count", "3 首音乐")
        try waitUntil("Native table renders all imported songs") { self.table.tableRows.count == 3 }
    }
    private func choosePath(_ url: URL, saving: Bool = false) throws {
        app.activate()
        let action = app.buttons["OKButton"]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.activate()
        app.typeText(saving ? url.deletingLastPathComponent().path : url.path)
        app.typeKey(.return, modifierFlags: [])
        if saving {
            let filename = app.textFields["saveAsNameTextField"]
            try replace(filename, with: url.lastPathComponent)
        }
        try waitUntil("File panel confirms \(url.lastPathComponent)", timeout: 25) {
            action.exists && action.isEnabled
        }
        if action.isHittable { action.click() }
        else {
            // macOS 15 can report an enabled, visible native panel button as
            // not hittable. Anchor to that identified button's actual frame,
            // then still require panel dismissal and verify the file result.
            XCTAssertFalse(action.frame.isEmpty)
            action.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        try waitUntil("File panel closes") { !action.exists }
        XCTAssertFalse(app.sheets.buttons["好"].exists, "Unexpected operation alert after selecting a fixture")
    }
    private func replace(_ field: XCUIElement, with text: String, tabToCommit: Bool = true) throws {
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey("a", modifierFlags: [.command])
        // Replacing a selection is one edit. A separate Delete can produce an
        // extra undo group on slower hosts, especially for mixed-value fields.
        if text.isEmpty { app.typeKey(.delete, modifierFlags: []) }
        else { field.typeText(text) }
        if tabToCommit { app.typeKey(.tab, modifierFlags: []) }
        try expectValue(field, text)
    }
    private func expectLabel(_ identifier: String, _ label: String) throws {
        let element = app.staticTexts[identifier]
        // AppKit exposes static text as AXValue; SwiftUI may expose AXLabel.
        try waitUntil("\(identifier) = \(label)") {
            element.exists && (element.label == label || (element.value as? String) == label)
        }
    }
    private func expectValue(_ element: XCUIElement, _ value: String) throws {
        try waitUntil("Expected field value: \(value)") { element.exists && (element.value as? String) == value }
    }
    private func waitUntil(_ message: String, timeout: TimeInterval = 10, _ condition: () -> Bool) throws {
        // Query XCUIElement on the test's calling thread. On a slower runner,
        // a predicate evaluated by XCTWaiter can still be resolving a large
        // file panel snapshot when the wait times out.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.25)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw UITestFixtures.FixtureError.invalid(message)
    }
    private func verifyAudio() throws {
        for (url, hash) in zip(fixtures.songs, fixtures.audioHashes) {
            XCTAssertEqual(try UITestFixtures.audioHash(at: url), hash, "PCM changed: \(url.lastPathComponent)")
        }
    }
}
