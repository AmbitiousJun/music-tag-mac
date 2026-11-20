import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct TrackItem: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var tags: AudioTags
    var savedTags: AudioTags
    var duration: Double
    var size: Int64
    var sampleRate: Double
    var channels: Int
    var issue: String?
    var isDirty: Bool { tags != savedTags }
    var title: String { tags.title.isEmpty ? url.deletingPathExtension().lastPathComponent : tags.title }
    var filenameTags: (artist: String?, title: String) {
        let name = url.deletingPathExtension().lastPathComponent
        guard let separator = name.range(of: " - ") else { return (nil, name) }
        return (String(name[..<separator.lowerBound]), String(name[separator.upperBound...]))
    }
    var format: String { url.pathExtension.uppercased() }
    var writable: Bool { TagEngine.canWrite(url) }
    var time: String { duration.isFinite && duration > 0 ? String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) : "—" }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "全部音乐", modified = "待保存", noCover = "缺少封面", noLyrics = "缺少歌词"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .all: return "music.note.list"; case .modified: return "square.and.pencil"; case .noCover: return "photo"; case .noLyrics: return "text.alignleft" }
    }
}

struct TagField: Identifiable {
    let name: String
    let key: WritableKeyPath<AudioTags, String>
    var id: String { name }
    static let all = [TagField(name: "标题", key: \.title), .init(name: "艺术家", key: \.artist), .init(name: "专辑", key: \.album), .init(name: "专辑艺术家", key: \.albumArtist), .init(name: "作曲家", key: \.composer), .init(name: "作词家", key: \.lyricist), .init(name: "流派", key: \.genre), .init(name: "年份", key: \.year), .init(name: "音轨", key: \.track), .init(name: "碟号", key: \.disc), .init(name: "备注", key: \.comment)]
}

@MainActor final class LibraryStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared: LibraryStore = {
        #if UI_TESTING
        // Only the Xcode test build accepts an isolated session. The shipping
        // swiftc build never reads this argument or changes its defaults domain.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--ui-test-session"),
           arguments.indices.contains(index + 1),
           let session = UUID(uuidString: arguments[index + 1]),
           let defaults = UserDefaults(suiteName: "app.musictag.mac.uitesting.\(session.uuidString)") {
            return LibraryStore(defaults: defaults)
        }
        #endif
        return LibraryStore()
    }()
    static let readableExtensions: Set<String> = ["mp3", "flac", "m4a", "mp4", "wav", "wave", "aif", "aiff", "aifc", "aac", "caf", "ogg", "opus", "wma", "ape", "wv", "dsf", "dff"]
    @Published var tracks: [TrackItem] = []
    @Published var selection = Set<UUID>()
    @Published var filter: LibraryFilter = .all
    @Published var query = ""
    @Published var status = "将音乐拖入窗口，开始整理标签"
    @Published var busy = false
    @Published var alert: String?
    @Published var showLookup = false
    @Published var showRename = false
    @Published private var playingTrackID: UUID?
    @Published var sortMode = 0
    private var player: AVAudioPlayer?
    private var undoHistory: [[UUID: AudioTags]] = []
    private var lastEditKey = ""
    private var lastEditTime = Date.distantPast
    private static let lastDirectoryPathsKey = "lastImportedDirectoryPaths"
    private let defaults: UserDefaults
    private var didAttemptDirectoryRestore = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    func restoreLastDirectories() {
        guard !didAttemptDirectoryRestore else { return }
        didAttemptDirectoryRestore = true
        // An explicit file-open request at launch takes precedence over restoration.
        guard tracks.isEmpty, !busy else { return }
        let directories = (defaults.stringArray(forKey: Self.lastDirectoryPathsKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter(Self.isExistingDirectory)
        if !directories.isEmpty { importURLs(directories, rememberDirectories: false) }
    }

    var selected: [TrackItem] { tracks.filter { selection.contains($0.id) } }
    var first: TrackItem? { selected.first }
    var isSelectionPlaying: Bool { playingTrackID.map { $0 == first?.id } ?? false }
    var playbackActionTitle: String { isSelectionPlaying ? "停止试听" : "播放试听" }
    var dirtyCount: Int { tracks.filter(\.isDirty).count }
    var hasWritableSelection: Bool { selected.contains(where: \.writable) }
    var canUndo: Bool { !undoHistory.isEmpty }
    var visible: [TrackItem] {
        let result = tracks.filter { item in
            let included: Bool
            switch filter { case .all: included = true; case .modified: included = item.isDirty; case .noCover: included = item.tags.artwork == nil; case .noLyrics: included = item.tags.lyrics.isEmpty }
            return included && (query.isEmpty || [item.title, item.tags.artist, item.tags.album, item.url.lastPathComponent].contains { $0.localizedCaseInsensitiveContains(query) })
        }
        return result.sorted {
            let a = sortMode == 1 ? $0.tags.artist : sortMode == 2 ? $0.tags.album : $0.url.lastPathComponent
            let b = sortMode == 1 ? $1.tags.artist : sortMode == 2 ? $1.tags.album : $1.url.lastPathComponent
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }
    func count(_ filter: LibraryFilter) -> Int {
        switch filter { case .all: return tracks.count; case .modified: return dirtyCount; case .noCover: return tracks.filter { $0.tags.artwork == nil }.count; case .noLyrics: return tracks.filter { $0.tags.lyrics.isEmpty }.count }
    }
    func common(_ key: KeyPath<AudioTags, String>) -> String {
        guard let first = selected.first else { return "" }
        let value = first.tags[keyPath: key]
        return selected.allSatisfy { $0.tags[keyPath: key] == value } ? value : ""
    }
    func mixed(_ key: KeyPath<AudioTags, String>) -> Bool {
        guard let first = selected.first else { return false }
        return selected.contains { $0.tags[keyPath: key] != first.tags[keyPath: key] }
    }
    func binding(_ field: TagField) -> Binding<String> {
        Binding(get: { self.common(field.key) }, set: { self.set(field.key, $0, name: field.name) })
    }
    func remember(_ key: String = UUID().uuidString, targetIDs: Set<UUID>? = nil) {
        if key != lastEditKey || Date().timeIntervalSince(lastEditTime) > 1.5 {
            undoHistory.append(Dictionary(uniqueKeysWithValues: tracks.filter { (targetIDs ?? selection).contains($0.id) }.map { ($0.id, $0.tags) }))
            if undoHistory.count > 40 { undoHistory.removeFirst() }
        }
        lastEditKey = key
        lastEditTime = Date()
    }
    func set(_ key: WritableKeyPath<AudioTags, String>, _ value: String, name: String) {
        guard !busy, hasWritableSelection else { return }
        // SwiftUI may write an unchanged value when an editor gains/loses
        // focus. Such callbacks must not consume an undo step.
        guard tracks.contains(where: { selection.contains($0.id) && $0.writable && $0.tags[keyPath: key] != value }) else { return }
        remember(name + selection.map(\.uuidString).sorted().joined())
        for i in tracks.indices where selection.contains(tracks[i].id) && tracks[i].writable { tracks[i].tags[keyPath: key] = value }
    }
    func mutate(targetIDs: Set<UUID>? = nil, _ body: (inout AudioTags) -> Void) {
        mutateTracks(targetIDs: targetIDs ?? selection) { _, tags in body(&tags) }
    }
    @discardableResult
    func mutateTracks(targetIDs: Set<UUID>, _ body: (UUID, inout AudioTags) -> Void) -> Int {
        guard !busy, !targetIDs.isEmpty else { return 0 }
        var updated = tracks
        var changed = Set<UUID>()
        for index in updated.indices where targetIDs.contains(updated[index].id) && updated[index].writable {
            body(updated[index].id, &updated[index].tags)
            if updated[index].tags != tracks[index].tags { changed.insert(updated[index].id) }
        }
        guard !changed.isEmpty else { return 0 }
        remember(targetIDs: changed)
        tracks = updated
        return changed.count
    }
    func undo() {
        guard !busy else { return }
        guard let values = undoHistory.popLast() else { return }
        for i in tracks.indices { if let tags = values[tracks[i].id] { tracks[i].tags = tags } }
        lastEditKey = ""
        status = "已撤销上一次标签修改"
    }
    func revertSelected() {
        guard !busy else { return }
        remember()
        for i in tracks.indices where selection.contains(tracks[i].id) { tracks[i].tags = tracks[i].savedTags }
    }
    func openFiles(folder: Bool = false) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = folder ? "选择音乐文件夹，将递归导入其中的音频文件" : "选择音乐文件或文件夹"
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }
    func importURLs(_ urls: [URL], rememberDirectories: Bool = true) {
        guard !busy else { status = "请等待当前操作完成后再添加音乐"; return }
        if rememberDirectories {
            let paths = urls.filter(Self.isExistingDirectory).map { $0.standardizedFileURL.path }
            if !paths.isEmpty { defaults.set(paths, forKey: Self.lastDirectoryPathsKey) }
        }
        busy = true
        status = "正在读取音乐…"
        let known = Set(tracks.map { $0.url.standardizedFileURL.path })
        Task {
            let imported = await Task.detached(priority: .userInitiated) {
                var paths: [URL] = []
                for url in urls {
                    var directory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                            for case let file as URL in enumerator where Self.readableExtensions.contains(file.pathExtension.lowercased()) { paths.append(file) }
                        }
                    } else if Self.readableExtensions.contains(url.pathExtension.lowercased()) { paths.append(url) }
                }
                var seen = known
                var added: [TrackItem] = []
                for path in paths.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                    let url = path.standardizedFileURL.resolvingSymlinksInPath()
                    guard seen.insert(url.path).inserted else { continue }
                    added.append(await Self.load(url))
                }
                return added
            }.value
            self.tracks.append(contentsOf: imported)
            if self.selection.isEmpty, let item = imported.first { self.selection = [item.id] }
            self.status = imported.isEmpty ? "未发现新的音乐文件" : "已添加 \(imported.count) 首音乐"
            self.busy = false
        }
    }
    nonisolated static func load(_ url: URL) async -> TrackItem {
        var tags = AudioTags()
        var issue: String?
        if TagEngine.canWrite(url) { do { tags = try TagEngine.read(from: url) } catch { issue = error.localizedDescription } }
        let asset = AVURLAsset(url: url)
        if !TagEngine.canWrite(url) {
            for item in (try? await asset.load(.commonMetadata)) ?? [] {
                guard let key = item.commonKey else { continue }
                if key == .commonKeyTitle { tags.title = (try? await item.load(.stringValue)) ?? tags.title }
                if key == .commonKeyArtist { tags.artist = (try? await item.load(.stringValue)) ?? tags.artist }
                if key == .commonKeyAlbumName { tags.album = (try? await item.load(.stringValue)) ?? tags.album }
                if key == .commonKeyArtwork { tags.artwork = try? await item.load(.dataValue) }
            }
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        var sampleRate = 0.0, channels = 0
        if let audio = try? AVAudioFile(forReading: url) { sampleRate = audio.fileFormat.sampleRate; channels = Int(audio.fileFormat.channelCount) }
        let duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        return TrackItem(id: UUID(), url: url, tags: tags, savedTags: tags, duration: duration.isFinite ? duration : 0, size: size, sampleRate: sampleRate, channels: channels, issue: issue)
    }
    func save(all: Bool = false) {
        guard !busy else { return }
        let pending = tracks.filter { $0.isDirty && (all || selection.contains($0.id)) }
        guard !pending.isEmpty else { status = "没有需要保存的修改"; return }
        busy = true
        status = "正在保存 \(pending.count) 首音乐…"
        DispatchQueue.global(qos: .userInitiated).async {
            var saved: [UUID: AudioTags] = [:], errors: [String] = []
            for item in pending {
                do { try TagEngine.write(item.tags, to: item.url); saved[item.id] = item.tags }
                catch { errors.append("\(item.url.lastPathComponent)：\(error.localizedDescription)") }
            }
            let savedTags = saved, failures = errors
            DispatchQueue.main.async { [savedTags, failures] in
                for i in self.tracks.indices {
                    if let tags = savedTags[self.tracks[i].id] {
                        self.tracks[i].savedTags = tags
                        self.tracks[i].issue = nil
                        self.tracks[i].size = ((try? FileManager.default.attributesOfItem(atPath: self.tracks[i].url.path)[.size]) as? NSNumber)?.int64Value ?? self.tracks[i].size
                    }
                }
                self.busy = false
                self.status = "已保存 \(savedTags.count) 首音乐" + (failures.isEmpty ? "" : "，\(failures.count) 首失败")
                if !failures.isEmpty { self.alert = failures.joined(separator: "\n\n") }
            }
        }
    }
    func removeSelected() {
        guard !busy else { return }
        if selected.contains(where: \.isDirty) && !confirm("移除选中的音乐？", detail: "选中音乐的未保存修改将被丢弃。音乐文件保留在原位置。") { return }
        if let id = playingTrackID, selection.contains(id) { stopPlayback() }
        tracks.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }
    func reveal() { if let first = first { NSWorkspace.shared.activateFileViewerSelecting([first.url]) } }
    func togglePlayback() {
        guard let track = first else { return }
        let shouldStop = playingTrackID == track.id
        stopPlayback()
        guard !shouldStop else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: track.url)
            player.delegate = self
            guard player.play() else { return }
            self.player = player
            playingTrackID = track.id
        } catch { alert = "系统无法试听此格式：\(error.localizedDescription)" }
    }
    private func stopPlayback() {
        guard let player else { return }
        player.stop()
        self.player = nil
        playingTrackID = nil
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player { self.stopPlayback() }
        }
    }
    func chooseArtwork() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importArtwork(url) }
    }
    func importArtwork(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 30 * 1024 * 1024, let image = NSImage(data: data), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { throw AppError.message("请选择有效的图片（不超过 30 MB）") }
            mutate { $0.artwork = jpeg }
        } catch { alert = error.localizedDescription }
    }
    func exportArtwork() {
        guard let data = first?.tags.artwork else { return }
        let isPNG = data.prefix(4) == Data([137, 80, 78, 71])
        let panel = NSSavePanel(); panel.nameFieldStringValue = "cover." + (isPNG ? "png" : "jpg"); panel.allowedContentTypes = isPNG ? [.png] : [.jpeg]
        if panel.runModal() == .OK, let url = panel.url { do { try data.write(to: url, options: .atomic) } catch { alert = error.localizedDescription } }
    }
    func importLyrics() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "lrc") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { let text = try String(contentsOf: url); set(\.lyrics, text, name: "导入歌词") } catch { alert = error.localizedDescription }
        }
    }
    func exportLyrics() {
        guard !selected.isEmpty else { return }
        if selected.count == 1, let first = first {
            let panel = NSSavePanel(); panel.nameFieldStringValue = first.url.deletingPathExtension().lastPathComponent + ".lrc"
            if panel.runModal() == .OK, let url = panel.url { do { try first.tags.lyrics.write(to: url, atomically: true, encoding: .utf8) } catch { alert = error.localizedDescription } }
        } else {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.message = "选择歌词导出目录；同名文件将跳过"
            if panel.runModal() == .OK, let root = panel.url {
                var count = 0, skipped = 0
                for item in selected where !item.tags.lyrics.isEmpty {
                    let target = root.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + ".lrc")
                    if FileManager.default.fileExists(atPath: target.path) { skipped += 1; continue }
                    do { try item.tags.lyrics.write(to: target, atomically: true, encoding: .utf8); count += 1 } catch { alert = error.localizedDescription }
                }
                status = "已导出 \(count) 份歌词，跳过 \(skipped) 个同名文件"
            }
        }
    }
    func transformChinese(traditional: Bool) {
        let transform = StringTransform(traditional ? "Hans-Hant" : "Hant-Hans")
        mutate { tags in
            for field in TagField.all { tags[keyPath: field.key] = tags[keyPath: field.key].applyingTransform(transform, reverse: false) ?? tags[keyPath: field.key] }
            tags.lyrics = tags.lyrics.applyingTransform(transform, reverse: false) ?? tags.lyrics
        }
    }
    func cleanLyrics(removeTimes: Bool) {
        mutate { tags in
            if removeTimes { tags.lyrics = tags.lyrics.replacingOccurrences(of: "\\[\\d{1,3}:\\d{2}(?:[.:]\\d{1,3})?\\]", with: "", options: .regularExpression) }
            else { tags.lyrics = tags.lyrics.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n") }
        }
    }
    func tagsFromFilename() {
        guard !busy, hasWritableSelection else { return }
        remember()
        for i in tracks.indices where selection.contains(tracks[i].id) && tracks[i].writable {
            let filename = tracks[i].filenameTags
            if let artist = filename.artist { tracks[i].tags.artist = artist }
            tracks[i].tags.title = filename.title
        }
        status = "已从文件名填充标签；保存后写入文件"
    }
    func renamed(_ item: TrackItem, pattern: String) -> String {
        var name = pattern
        for (key, value) in [("title", item.tags.title), ("artist", item.tags.artist), ("album", item.tags.album), ("track", item.tags.track.components(separatedBy: "/").first ?? ""), ("year", item.tags.year)] { name = name.replacingOccurrences(of: "{\(key)}", with: value) }
        name = name.replacingOccurrences(of: "[/\\\\:\\x00-\\x1F]", with: "_", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? item.url.lastPathComponent : name + "." + item.url.pathExtension
    }
    func rename(pattern: String) {
        guard !busy else { return }
        let items = selected
        var targets = Set<String>()
        for item in items {
            let url = item.url.deletingLastPathComponent().appendingPathComponent(renamed(item, pattern: pattern))
            guard targets.insert(url.path.lowercased()).inserted, url == item.url || !FileManager.default.fileExists(atPath: url.path) else { alert = "存在同名目标文件：\(url.lastPathComponent)。请调整命名模板。"; return }
            guard url.lastPathComponent.utf8.count <= 255, url.lastPathComponent != ".", url.lastPathComponent != ".." else { alert = "文件名过长或无效"; return }
        }
        var count = 0
        for i in tracks.indices where selection.contains(tracks[i].id) {
            let target = tracks[i].url.deletingLastPathComponent().appendingPathComponent(renamed(tracks[i], pattern: pattern))
            if target == tracks[i].url { continue }
            do { try FileManager.default.moveItem(at: tracks[i].url, to: target); tracks[i].url = target; count += 1 } catch { alert = error.localizedDescription; break }
        }
        status = "已重命名 \(count) 个文件"
        showRename = false
    }
    func confirm(_ title: String, detail: String) -> Bool {
        let panel = NSAlert(); panel.messageText = title; panel.informativeText = detail; panel.addButton(withTitle: "继续"); panel.addButton(withTitle: "取消")
        return panel.runModal() == .alertFirstButtonReturn
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
