import AppKit
import XCTest

final class MusicTagUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixtures: UITestFixtures!
    private var session: String!
    private var suite: String { "app.musictag.mac.uitesting.\(session!)" }
    private var batchLookupGate: URL { fixtures.root.appendingPathComponent("release-batch-lookup") }
    private var lookupRequests: URL { fixtures.root.appendingPathComponent("lookup-requests", isDirectory: true) }

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MusicTag-XCUITest-\(session!)")
        fixtures = try UITestFixtures.create(at: root)
        app = XCUIApplication()
        // ASCII fixture input must not request activation of a user's third-party IME.
        app.launchArguments = ["--ui-test-session", session, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["MUSICTAG_UI_TEST_BATCH_LOOKUP_GATE"] = batchLookupGate.path
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

    func testPlaybackControlsFollowSelection() throws {
        try importFolder()
        let playback = app.toolbars.buttons.matching(identifier: "toolbar.play").firstMatch
        let markers = fixtures.songs.map { song in
            table.descendants(matching: .any).matching(identifier: "track.\(song.lastPathComponent).playing").firstMatch
        }
        func expectAction(_ title: String) throws {
            try waitUntil("Playback action: \(title)") {
                playback.exists && playback.isEnabled && playback.label == title
            }
        }
        func expectPlaying(_ index: Int?, timeout: TimeInterval = 10) throws {
            let filename = index.map { fixtures.songs[$0].lastPathComponent } ?? "none"
            try waitUntil("Playing marker: \(filename)", timeout: timeout) {
                markers.indices.allSatisfy { markers[$0].exists == ($0 == index) }
            }
        }

        try selectSong(0)
        try expectAction("播放试听")
        try expectPlaying(nil)
        playback.click()
        try expectAction("停止试听")
        try expectPlaying(0)

        try selectSong(1)
        try expectAction("播放试听")
        try expectPlaying(0)
        try selectSong(0)
        try expectAction("停止试听")
        playback.click()
        try expectAction("播放试听")
        try expectPlaying(nil)

        playback.click()
        try expectAction("停止试听")
        try selectSong(1)
        try expectAction("播放试听")
        playback.click()
        try expectAction("停止试听")
        try expectPlaying(1)
        try selectSong(0)
        try expectAction("播放试听")
        try expectPlaying(1)
        try selectSong(1)
        try expectAction("停止试听")

        row(1).rightClick()
        table.menuItems["停止试听"].click()
        try expectAction("播放试听")
        try expectPlaying(nil)

        playback.click()
        try expectPlaying(1)
        try selectSong(0)
        try expectPlaying(nil, timeout: 25)
    }

    func testSortMenuAndBatchLookupSourcePicker() throws {
        try importFolder()
        try selectSong(0)
        let sort = app.descendants(matching: .any).matching(identifier: "library.sort").firstMatch
        let batch = app.buttons["library.batchLookup"]
        XCTAssertTrue(sort.isEnabled)
        XCTAssertFalse(batch.isEnabled)
        try replace(app.textFields["tag.专辑"], with: "ZZZ Album")
        XCTAssertTrue(sort.isEnabled)
        sort.click()
        let album = app.menuItems["专辑"]
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.click()
        try waitUntil("Album sorting moves the selected song to the end") { self.row(0).frame.minY > self.row(2).frame.minY }

        XCUIElement.perform(withKeyModifiers: .command) { row(2).click() }
        try expectLabel("library.selectionCount", "已选 2 首")
        XCTAssertTrue(batch.isEnabled)
        batch.click()
        let source = app.descendants(matching: .any).matching(identifier: "batchLookup.source").firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()
        let netease = app.menuItems["网易云音乐"]
        XCTAssertTrue(netease.waitForExistence(timeout: 5))
        netease.click()
        XCTAssertTrue(app.buttons["batchLookup.start"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        try waitUntil("Escape closes the source picker sheet") { !source.exists }
        try expectLabel("library.selectionCount", "已选 2 首")
    }

    func testBatchLookupKeepsRowsSeparatedWhileRunningAndAfterwards() throws {
        try importFolder()
        try selectSong(0)
        XCUIElement.perform(withKeyModifiers: .command) { row(2).click() }
        app.buttons["library.batchLookup"].click()

        let sheet = app.sheets.firstMatch
        let source = app.descendants(matching: .any).matching(identifier: "batchLookup.source").firstMatch
        let start = app.buttons["batchLookup.start"]
        let status = app.staticTexts["batchLookup.status"]
        let progress = app.descendants(matching: .any).matching(identifier: "batchLookup.progress").firstMatch
        let notice = app.staticTexts["batchLookup.notice"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let idleHeight = sheet.frame.height
        start.click()
        XCTAssertTrue(app.buttons["停止"].waitForExistence(timeout: 5))
        let runningScreenshot = XCTAttachment(screenshot: sheet.screenshot())
        runningScreenshot.name = "Batch lookup in progress"
        runningScreenshot.lifetime = .keepAlways
        add(runningScreenshot)
        let runningLabel = "正在匹配 1/2 · First Song"
        try expectLabel("batchLookup.status", runningLabel)
        XCTAssertFalse(source.isEnabled)
        XCTAssertTrue(progress.exists)
        XCTAssertGreaterThanOrEqual(status.frame.minY, source.frame.maxY + 4)
        XCTAssertGreaterThanOrEqual(progress.frame.minY, status.frame.maxY + 2)
        XCTAssertGreaterThanOrEqual(notice.frame.minY, progress.frame.maxY + 4)
        XCTAssertEqual(sheet.frame.height, idleHeight, accuracy: 1)

        try Data().write(to: batchLookupGate)
        try expectLabel("batchLookup.status", "已匹配 0 首 · 更新 0 首 · 跳过 2 首")
        let issues = app.scrollViews["batchLookup.issues"]
        XCTAssertTrue(issues.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(status.frame.minY, source.frame.maxY + 4)
        XCTAssertGreaterThanOrEqual(issues.frame.minY, status.frame.maxY + 4)
        XCTAssertGreaterThanOrEqual(notice.frame.minY, issues.frame.maxY + 4)
        let resultsScreenshot = XCTAttachment(screenshot: sheet.screenshot())
        resultsScreenshot.name = "Batch lookup with results"
        resultsScreenshot.lifetime = .keepAlways
        add(resultsScreenshot)

        try FileManager.default.removeItem(at: batchLookupGate)
        start.click()
        XCTAssertTrue(app.buttons["停止"].waitForExistence(timeout: 5))
        app.buttons["停止"].click()
        try expectLabel("batchLookup.status", "已停止批量填充")
        XCTAssertTrue(source.isEnabled)
        XCTAssertTrue(start.isEnabled)
        try verifyAudio()
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

    func testLyricSettingsPreviewAndPersistence() throws {
        try openLyricSettings()
        try configurePlainOriginalLyrics()
        try expectLabel("lyricSettings.preview", plainOriginalLyrics)

        app.terminate()
        app.launch()
        try openLyricSettings()
        try expectToggle("lyricSettings.translationEnabled", enabled: false)
        try expectToggle("lyricSettings.removeTimes", enabled: true)
        try expectToggle("lyricSettings.removeHeaders", enabled: true)
        try expectLabel("lyricSettings.preview", plainOriginalLyrics)

        app.buttons["lyricSettings.reset"].click()
        try expectToggle("lyricSettings.translationEnabled", enabled: true)
        try expectToggle("lyricSettings.removeTimes", enabled: false)
        try expectToggle("lyricSettings.removeHeaders", enabled: false)
    }

    func testAggregateLookupRanksSourcesAndAppliesLyrics() throws {
        try launchWithLookupRequestRecording()
        try importFolder()
        try selectSong(0)
        try searchAggregateFixture()

        let kugouResult = app.staticTexts["Aggregate Fixture (Live)"]
        let qqResult = app.staticTexts["Fixture Loose Match"]
        XCTAssertTrue(kugouResult.waitForExistence(timeout: 5))
        XCTAssertTrue(qqResult.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["酷狗音乐"].exists)
        XCTAssertTrue(app.staticTexts["QQ 音乐"].exists)
        XCTAssertLessThan(kugouResult.frame.minY, qqResult.frame.minY)
        try expectLabel("lookup.status", "找到 2 个结果；搜索失败：网易云音乐")
        XCTAssertEqual(try requestedLookupSources(), ["qq", "netease", "kugou"])
        app.buttons["完成"].click()

        try openLyricSettings()
        for source in ["itunes", "lrclib"] {
            let id = "lookupSettings.source.\(source)"
            try expectToggle(id, enabled: false)
            app.checkBoxes[id].click()
            try expectToggle(id, enabled: true)
        }
        try closeLyricSettings()
        try searchAggregateFixture()

        let iTunesResult = app.staticTexts["Aggregate Fixture"]
        XCTAssertTrue(iTunesResult.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["iTunes"].exists)
        XCTAssertTrue(app.staticTexts["LRCLIB"].exists)
        XCTAssertLessThan(iTunesResult.frame.minY, kugouResult.frame.minY)
        XCTAssertEqual(try requestedLookupSources(), ["qq", "netease", "kugou", "itunes", "lrclib"])

        app.buttons["lookup.previewLyrics"].click()
        try expectLabel("lookup.lyricPreview", "[00:01.00]Lyrics from LRCLIB")
        app.buttons["应用歌词"].click()
        app.buttons["完成"].click()
        try showLyricsEditor()
        try expectValue(findLyricsEditor(), "[00:01.00]Lyrics from LRCLIB")
        app.buttons["toolbar.undo"].firstMatch.click()
        try expectValue(findLyricsEditor(), "")
    }

    func testAggregateLookupOnlyRequestsSavedEnabledSources() throws {
        try launchWithLookupRequestRecording()
        try importFolder()
        try openLyricSettings()
        let defaultSources = ["qq", "netease", "kugou"]
        app.checkBoxes["lookupSettings.source.lrclib"].click()
        try expectToggle("lookupSettings.source.lrclib", enabled: true)
        for source in defaultSources {
            let id = "lookupSettings.source.\(source)"
            try expectToggle(id, enabled: true)
            app.checkBoxes[id].click()
        }
        XCTAssertFalse(app.checkBoxes["lookupSettings.source.lrclib"].isEnabled)

        app.terminate()
        app.launch()
        try openLyricSettings()
        for source in defaultSources + ["itunes", "lrclib"] {
            try expectToggle("lookupSettings.source.\(source)", enabled: source == "lrclib")
        }
        try closeLyricSettings()

        try selectSong(0)
        try searchAggregateFixture()
        XCTAssertTrue(app.staticTexts["Aggregate Fixture Lyrics"].waitForExistence(timeout: 5))
        XCTAssertEqual(try requestedLookupSources(), ["lrclib"])
    }

    func testAggregateSearchBreaksTiesUsingSavedSourceOrder() throws {
        try launchWithLookupRequestRecording()
        try importFolder()
        try selectSong(0)
        try searchAggregateFixture("Aggregate Priority")

        let qqResult = app.staticTexts["QQ 音乐"]
        let kugouResult = app.staticTexts["酷狗音乐"]
        XCTAssertTrue(qqResult.waitForExistence(timeout: 5))
        XCTAssertTrue(kugouResult.waitForExistence(timeout: 5))
        XCTAssertLessThan(qqResult.frame.minY, kugouResult.frame.minY)
        app.buttons["完成"].click()

        try openLyricSettings()
        let moveQQUp = app.buttons["aggregate.moveUp.qq"]
        let moveQQDown = app.buttons["aggregate.moveDown.qq"]
        let moveKugouUp = app.buttons["aggregate.moveUp.kugou"]
        XCTAssertFalse(moveQQUp.isEnabled)
        moveKugouUp.click()
        moveQQDown.click()
        XCTAssertFalse(moveKugouUp.isEnabled)
        XCTAssertTrue(moveQQUp.isEnabled)

        app.terminate()
        app.launch()
        try openLyricSettings()
        XCTAssertFalse(moveKugouUp.isEnabled)
        try expectToggle("lookupSettings.source.kugou", enabled: true)
        try closeLyricSettings()
        try selectSong(0)
        try searchAggregateFixture("Aggregate Priority")
        XCTAssertTrue(kugouResult.waitForExistence(timeout: 5))
        XCTAssertTrue(qqResult.waitForExistence(timeout: 5))
        XCTAssertLessThan(kugouResult.frame.minY, qqResult.frame.minY)
    }

    func testAggregateBatchLookupUsesPriorityAndFallsBack() throws {
        try launchWithLookupRequestRecording(aggregateBatch: true)
        try importFolder()
        try openLyricSettings()
        let moveKugouUp = app.buttons["aggregate.moveUp.kugou"]
        moveKugouUp.click()
        moveKugouUp.click()
        XCTAssertFalse(moveKugouUp.isEnabled)
        try closeLyricSettings()
        try selectSong(0)
        XCUIElement.perform(withKeyModifiers: .command) { row(1).click() }
        try expectLabel("library.selectionCount", "已选 2 首")
        try fillBatchLyrics()
        XCTAssertEqual(try requestedLookupSources(), ["kugou", "qq"])

        app.toolbars.buttons.matching(identifier: "toolbar.saveAll").firstMatch.click()
        try expectLabel("library.status", "已保存 2 首音乐")
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[0]).album, "Kugou Album 1")
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[1]).album, "QQ Fixture Album 2")
        try verifyAudio()
    }

    private func launchWithLookupRequestRecording(aggregateBatch: Bool = false) throws {
        try FileManager.default.createDirectory(at: lookupRequests, withIntermediateDirectories: false)
        app.terminate()
        app.launchEnvironment["MUSICTAG_UI_TEST_LYRICS_FIXTURE"] = "1"
        app.launchEnvironment["MUSICTAG_UI_TEST_LOOKUP_REQUESTS"] = lookupRequests.path
        if aggregateBatch {
            app.launchEnvironment.removeValue(forKey: "MUSICTAG_UI_TEST_BATCH_LOOKUP_GATE")
            app.launchEnvironment["MUSICTAG_UI_TEST_AGGREGATE_PRIORITY"] = "1"
        }
        app.launch()
    }

    private func requestedLookupSources() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: lookupRequests.path))
    }

    private func searchAggregateFixture(_ query: String = "Aggregate Fixture") throws {
        app.toolbars.buttons.matching(NSPredicate(format: "label == %@", "搜索标签")).firstMatch.click()
        let picker = app.descendants(matching: .any).matching(identifier: "lookup.source").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "聚合")
        try replace(app.textFields["标题 / 艺术家 / 专辑"], with: query, tabToCommit: false)
        app.buttons["搜索"].click()
    }

    func testQQLyricsKeepTranslationThroughBatchSave() throws {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "MUSICTAG_UI_TEST_BATCH_LOOKUP_GATE")
        app.launchEnvironment["MUSICTAG_UI_TEST_LYRICS_FIXTURE"] = "1"
        app.launch()
        try openLyricSettings()
        try configurePlainLyrics()
        try expectLabel("lyricSettings.preview", bilingualLyrics)
        let settings = app.windows.containing(.staticText, identifier: "lyricSettings.preview").firstMatch
        settings.buttons["_XCUI:CloseWindow"].click()
        try waitUntil("Settings window closes") { !self.app.staticTexts["lyricSettings.preview"].exists }

        let localLyrics = "[00:00.00]Existing local lyric"
        var tags = try TagEngine.read(from: fixtures.songs[0])
        tags.lyrics = localLyrics
        try TagEngine.write(tags, to: fixtures.songs[0])
        try importFolder()
        try selectSong(0)
        app.toolbars.buttons.matching(NSPredicate(format: "label == %@", "搜索标签")).firstMatch.click()
        try selectLookupSource("QQ 音乐 · 标签 / 封面 / 歌词", picker: "lookup.source")
        let search = app.buttons["搜索"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        let actions = app.descendants(matching: .any).matching(identifier: "lookup.actions").firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        let results = app.scrollViews["lookup.results"]
        XCTAssertTrue(results.exists)
        let trailingInset = results.frame.maxX - actions.frame.maxX
        let resultScreenshot = XCTAttachment(screenshot: results.screenshot())
        resultScreenshot.name = "Search result menu inset (\(trailingInset) pt)"
        resultScreenshot.lifetime = .keepAlways
        add(resultScreenshot)
        XCTAssertGreaterThanOrEqual(trailingInset, 12,
                                    "The result menu should stay clear of the vertical scrollbar")
        actions.click()
        let preview = app.menuItems["预览歌词"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.click()
        try expectLabel("lookup.lyricPreview", qqBilingualLyrics)
        app.buttons["应用歌词"].click()
        app.buttons["完成"].click()
        try showLyricsEditor()
        try expectValue(findLyricsEditor(), qqBilingualLyrics)
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[0]).lyrics, localLyrics)
        app.buttons["toolbar.undo"].firstMatch.click()
        try expectValue(findLyricsEditor(), localLyrics)

        XCUIElement.perform(withKeyModifiers: .command) { row(2).click() }
        try expectLabel("library.selectionCount", "已选 2 首")
        try fillBatchLyrics(source: "QQ 音乐")
        try selectSong(0)
        try expectValue(findLyricsEditor(), qqBilingualLyrics)
        try selectSong(2)
        try expectValue(findLyricsEditor(), qqBilingualLyrics)
        app.buttons["toolbar.undo"].firstMatch.click()
        try waitUntil("Undo clears both unsaved lyric updates") { !self.app.staticTexts["library.dirtyCount"].exists }
        try expectValue(findLyricsEditor(), "")
        try selectSong(0)
        try expectValue(findLyricsEditor(), localLyrics)

        XCUIElement.perform(withKeyModifiers: .command) { row(2).click() }
        try fillBatchLyrics(source: "QQ 音乐")
        app.toolbars.buttons.matching(identifier: "toolbar.saveAll").firstMatch.click()
        try expectLabel("library.status", "已保存 2 首音乐")
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[0]).lyrics, qqBilingualLyrics)
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[1]).lyrics, "")
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[2]).lyrics, qqBilingualLyrics)
        try verifyAudio()

        app.terminate()
        app.launch()
        try expectLabel("library.count", "3 首音乐")
        try selectSong(0)
        try showLyricsEditor()
        try expectValue(findLyricsEditor(), qqBilingualLyrics)
        try selectSong(2)
        try expectValue(findLyricsEditor(), qqBilingualLyrics)
    }

    func testLookupAppliesAllAvailableMetadataWithOneUndo() throws {
        app.terminate()
        app.launchEnvironment["MUSICTAG_UI_TEST_LYRICS_FIXTURE"] = "1"
        app.launch()
        try openLyricSettings()
        try configurePlainLyrics()
        let settings = app.windows.containing(.staticText, identifier: "lyricSettings.preview").firstMatch
        settings.buttons["_XCUI:CloseWindow"].click()
        try waitUntil("Settings window closes") { !self.app.staticTexts["lyricSettings.preview"].exists }

        let song = fixtures.songs[0]
        var local = try TagEngine.read(from: song)
        local.lyrics = "[00:00.00]Existing local lyric"
        local.artwork = try Data(contentsOf: fixtures.cover)
        try TagEngine.write(local, to: song)
        let original = try TagEngine.read(from: song)
        try importFolder()
        try selectSong(0)

        try applyAllFromLookupFixture()
        try expectValue(app.textFields["tag.标题"], "Online Title")
        try expectValue(app.textFields["tag.艺术家"], "Online Artist")
        try expectValue(app.textFields["tag.专辑"], "Online Album")
        try expectLabel("24 × 18", "24 × 18")
        try showLyricsEditor()
        try expectValue(findLyricsEditor(), qqBilingualLyrics)
        XCTAssertEqual(try TagEngine.read(from: song), original)

        app.buttons["toolbar.undo"].firstMatch.click()
        try expectValue(findLyricsEditor(), local.lyrics)
        try expectLabel("32 × 32", "32 × 32")
        app.radioButtons["标签"].click()
        try expectValue(app.textFields["tag.标题"], local.title)
        try expectValue(app.textFields["tag.艺术家"], local.artist)
        try expectValue(app.textFields["tag.专辑"], local.album)
        try waitUntil("One undo clears all unsaved changes") { !self.app.staticTexts["library.dirtyCount"].exists }

        try applyAllFromLookupFixture()
        app.buttons["inspector.save"].click()
        try expectLabel("library.status", "已保存 1 首音乐")
        let saved = try TagEngine.read(from: song)
        XCTAssertEqual(saved.title, "Online Title")
        XCTAssertEqual(saved.artist, "Online Artist")
        XCTAssertEqual(saved.album, "Online Album")
        XCTAssertEqual(saved.lyrics, qqBilingualLyrics)
        let artwork = try XCTUnwrap(saved.artwork)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: artwork))
        XCTAssertEqual(bitmap.pixelsWide, 24)
        XCTAssertEqual(bitmap.pixelsHigh, 18)
        try verifyAudio()
    }

    private func applyAllFromLookupFixture() throws {
        app.toolbars.buttons.matching(NSPredicate(format: "label == %@", "搜索标签")).firstMatch.click()
        let query = app.textFields["标题 / 艺术家 / 专辑"]
        try replace(query, with: "Apply All Fixture", tabToCommit: false)
        app.buttons["搜索"].click()
        let apply = app.buttons["lookup.applyAll"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        apply.click()
        try expectLabel("lookup.status", "已更新 1 首音乐，关闭窗口后保存以写入文件")
        app.buttons["完成"].click()
    }

    func testKugouSingleAndBatchLookupWithUndo() throws {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "MUSICTAG_UI_TEST_BATCH_LOOKUP_GATE")
        app.launchEnvironment["MUSICTAG_UI_TEST_LYRICS_FIXTURE"] = "1"
        app.launch()
        try openLyricSettings()
        try configurePlainLyrics()
        let settings = app.windows.containing(.staticText, identifier: "lyricSettings.preview").firstMatch
        settings.buttons["_XCUI:CloseWindow"].click()
        try waitUntil("Settings window closes") { !self.app.staticTexts["lyricSettings.preview"].exists }

        let original = try TagEngine.read(from: fixtures.songs[0])
        try importFolder()
        try selectSong(0)
        app.toolbars.buttons.matching(NSPredicate(format: "label == %@", "搜索标签")).firstMatch.click()
        try selectLookupSource("酷狗音乐 · 标签 / 封面 / 歌词", picker: "lookup.source")
        app.buttons["搜索"].click()
        let actions = app.descendants(matching: .any).matching(identifier: "lookup.actions").firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.click()
        let preview = app.menuItems["预览歌词"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.click()
        try expectLabel("lookup.lyricPreview", qqBilingualLyrics)
        app.typeKey(.escape, modifierFlags: [])
        try expectLabel("lookup.status", "已取消歌词预览")
        app.buttons["lookup.applyAll"].click()
        try expectLabel("lookup.status", "已更新 1 首音乐，关闭窗口后保存以写入文件")
        app.buttons["完成"].click()
        try expectValue(app.textFields["tag.专辑"], "Kugou Album 1")
        try expectLabel("24 × 18", "24 × 18")
        try showLyricsEditor()
        try expectValue(findLyricsEditor(), qqBilingualLyrics)
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[0]), original)
        app.buttons["toolbar.undo"].firstMatch.click()
        try waitUntil("One undo clears the single update") { !self.app.staticTexts["library.dirtyCount"].exists }
        try expectValue(findLyricsEditor(), original.lyrics)

        XCUIElement.perform(withKeyModifiers: .command) { row(2).click() }
        try fillBatchLyrics(source: "酷狗音乐")
        try selectSong(2)
        try expectValue(findLyricsEditor(), qqBilingualLyrics)
        app.buttons["toolbar.undo"].firstMatch.click()
        try waitUntil("One undo clears both batch updates") { !self.app.staticTexts["library.dirtyCount"].exists }
        XCUIElement.perform(withKeyModifiers: .command) { row(0).click() }
        try fillBatchLyrics(source: "酷狗音乐")
        app.toolbars.buttons.matching(identifier: "toolbar.saveAll").firstMatch.click()
        try expectLabel("library.status", "已保存 2 首音乐")
        for index in [0, 2] {
            let saved = try TagEngine.read(from: fixtures.songs[index])
            XCTAssertEqual(saved.album, "Kugou Album \(index + 1)")
            XCTAssertEqual(saved.lyrics, qqBilingualLyrics)
            let artwork = try XCTUnwrap(saved.artwork)
            XCTAssertEqual(NSBitmapImageRep(data: artwork)?.pixelsWide, 24)
        }
        XCTAssertEqual(try TagEngine.read(from: fixtures.songs[1]).album, "Original Album 2")
        try verifyAudio()
    }

    private func selectLookupSource(_ label: String, picker: String) throws {
        let selector = app.descendants(matching: .any).matching(identifier: picker).firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        selector.click()
        let option = app.menuItems[label]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.click()
    }

    private let qqBilingualLyrics = "First line 第一行\nSecond line 第二行"
    private let bilingualLyrics = "第一行 First line\n第二行 Second line"
    private let plainOriginalLyrics = "第一行\n第二行"

    private func openLyricSettings() throws {
        app.activate()
        app.typeKey(",", modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["lyricSettings.preview"].waitForExistence(timeout: 5))
    }

    private func closeLyricSettings() throws {
        let settings = app.windows.containing(.staticText, identifier: "lyricSettings.preview").firstMatch
        settings.buttons["_XCUI:CloseWindow"].click()
        try waitUntil("Settings window closes") { !self.app.staticTexts["lyricSettings.preview"].exists }
    }

    private func configurePlainOriginalLyrics() throws {
        try expectToggle("lyricSettings.translationEnabled", enabled: true)
        app.checkBoxes["lyricSettings.translationEnabled"].click()
        try expectToggle("lyricSettings.translationEnabled", enabled: false)
        try configurePlainLyrics()
    }

    private func configurePlainLyrics() throws {
        for id in ["lyricSettings.removeTimes", "lyricSettings.removeHeaders"] {
            try expectToggle(id, enabled: false)
            app.checkBoxes[id].click()
            try expectToggle(id, enabled: true)
        }
    }

    private func expectToggle(_ id: String, enabled: Bool) throws {
        let toggle = app.checkBoxes[id]
        try waitUntil("\(id) state is \(enabled)") {
            guard toggle.exists else { return false }
            let value = toggle.value
            return (value as? NSNumber)?.boolValue == enabled || (value as? String) == (enabled ? "1" : "0")
        }
    }

    private func showLyricsEditor() throws {
        let tab = app.radioButtons["歌词"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        _ = try findLyricsEditor()
    }

    private func fillBatchLyrics(source: String? = nil) throws {
        app.buttons["library.batchLookup"].click()
        if let source { try selectLookupSource(source, picker: "batchLookup.source") }
        let start = app.buttons["batchLookup.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        try expectLabel("batchLookup.status", "已匹配 2 首 · 更新 2 首 · 跳过 0 首")
        app.sheets.buttons["关闭"].click()
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
