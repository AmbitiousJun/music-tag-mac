import AppKit
import SwiftUI

private struct LyricPreview: Identifiable {
    let id: String
    let title: String
    let text: String
}

struct LookupView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var query = ""
    @State private var source: LookupSource = .qq
    @State private var country = "CN"
    @State private var songs: [CatalogSong] = []
    @State private var lyrics: [LyricResult] = []
    @State private var pending = false
    @State private var message = "输入标题和艺术家，搜索并预览后应用到选中的音乐。"
    @State private var selectedLyric: LyricResult?
    @State private var preview: LyricPreview?
    @State private var task: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var targetIDs = Set<UUID>()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("寻找音乐的细节").font(.title2).fontWeight(.semibold)
                    Text("为所选 \(targetIDs.count) 首音乐查找标签、封面与歌词").foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.showLookup = false } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("来源", selection: $source) {
                    Text("QQ 音乐 · 标签 / 封面 / 歌词").tag(LookupSource.qq)
                    Text("网易云音乐 · 标签 / 封面 / 歌词").tag(LookupSource.netease)
                    Text("iTunes · 标签与封面").tag(LookupSource.itunes)
                    Text("LRCLIB · 歌词").tag(LookupSource.lrclib)
                }.labelsHidden().frame(width: 290)
                if source == .itunes { Picker("地区", selection: $country) { Text("中国").tag("CN"); Text("美国").tag("US"); Text("日本").tag("JP"); Text("英国").tag("GB") }.frame(width: 110).disabled(pending) }
                Spacer()
            }
            HStack {
                TextField("标题 / 艺术家 / 专辑", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
                Button("搜索") { search() }.buttonStyle(.borderedProminent).disabled(pending || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if pending { Button("取消") { cancel(); message = "已取消" } }
            }
            HStack(spacing: 8) { if pending { ProgressView().controlSize(.small) }; Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Divider()
            if source != .lrclib {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(songs) { song in
                            HStack(spacing: 14) {
                                AsyncImage(url: song.artworkURL) { image in image.resizable().aspectRatio(contentMode: .fit) } placeholder: { Image(systemName: "music.note").font(.title2).foregroundStyle(.tertiary) }.frame(width: 56, height: 56).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(song.trackName ?? "未知标题").fontWeight(.medium)
                                    Text("\(song.artistName ?? "") · \(song.collectionName ?? "")").font(.caption).foregroundStyle(.secondary)
                                    Text([song.releaseDate.map { String($0.prefix(4)) }, song.primaryGenreName, song.trackNumber.map { "音轨 \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 10)
                                VStack(spacing: 7) {
                                    Button("应用标签") { applySong(song) }.disabled(pending)
                                    Button("应用封面") { applyArtwork(song) }.disabled(pending || (song.artworkURL == nil && song.source != .netease))
                                    if song.source == .qq || song.source == .netease { Button("预览歌词") { previewLyrics(song) }.disabled(pending) }
                                }.controlSize(.small)
                            }.padding(.vertical, 12)
                            Divider()
                        }
                    }
                }
            } else {
                HSplitView {
                    List(lyrics, selection: Binding<Int?>(get: { selectedLyric?.id }, set: { id in selectedLyric = lyrics.first { $0.id == id } })) { lyric in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(lyric.trackName).fontWeight(.medium)
                            Text(lyric.artistName).font(.caption).foregroundStyle(.secondary)
                            Label(lyric.syncedLyrics == nil ? "纯文本歌词" : "同步歌词 LRC", systemImage: "text.alignleft").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(lyric.id)
                    }.frame(minWidth: 200, idealWidth: 240)
                    ScrollView { Text(selectedLyric?.lyrics ?? "选择一个结果预览歌词").font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(minWidth: 290)
                }
                HStack { Spacer(); Button("应用所选歌词") { if let lyric = selectedLyric { applyLyrics(lyric.lyrics) } }.buttonStyle(.borderedProminent).disabled(pending || selectedLyric == nil || selectedLyric?.lyrics.isEmpty == true) }
            }
            Spacer(minLength: 0)
            HStack {
                Text("搜索词发送至所选来源；封面从来源加载；应用后仍需保存。").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Link(source.name, destination: source.website).font(.caption)
                Button("完成") { store.showLookup = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 780, height: 650)
        .onAppear {
            targetIDs = store.selection
            if let first = store.first { query = [first.tags.artist, first.tags.title.isEmpty ? first.title : first.tags.title].filter { !$0.isEmpty }.joined(separator: " ") }
        }
        .onChange(of: source) { _ in cancel(); songs = []; lyrics = []; selectedLyric = nil; preview = nil; message = "输入关键词后点击搜索" }
        .onDisappear { cancel() }
        .sheet(item: $preview) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text(item.title).font(.headline)
                ScrollView { Text(item.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                HStack { Text("应用后仍需保存写入音乐文件").font(.caption).foregroundStyle(.secondary); Spacer(); Button("取消") { preview = nil }.keyboardShortcut(.cancelAction); Button("应用歌词") { applyLyrics(item.text); preview = nil }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 620, height: 500)
        }
    }
    private func cancel() { operationID = UUID(); task?.cancel(); task = nil; pending = false }
    private func run(_ status: String, operation: @escaping @MainActor (UUID) async throws -> Void) {
        cancel()
        let id = operationID
        pending = true; message = status
        task = Task { @MainActor in
            defer { if operationID == id { pending = false; task = nil } }
            do { try await operation(id) }
            catch { if operationID == id && !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    private func isCurrent(_ id: UUID) -> Bool { operationID == id && !Task.isCancelled }
    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !pending else { return }
        let selectedSource = source, selectedCountry = country
        songs = []; lyrics = []; selectedLyric = nil
        run("正在搜索 \(selectedSource.name)…") { id in
            if selectedSource == .lrclib {
                let results = try await OnlineLookup.lyrics(query: text)
                guard isCurrent(id) else { return }
                lyrics = results; message = results.isEmpty ? "没有找到歌词，可以调整关键词" : "找到 \(results.count) 份歌词"
            } else {
                let results = try await OnlineLookup.songs(query: text, country: selectedCountry, source: selectedSource)
                guard isCurrent(id) else { return }
                songs = results; message = results.isEmpty ? "没有找到结果，可以调整关键词或来源" : "\(selectedSource.name)找到 \(results.count) 个结果；请核对后应用"
            }
        }
    }
    private func applySong(_ song: CatalogSong) {
        run("正在读取 \(song.source.name)歌曲详情…") { id in
            let detail = try await OnlineLookup.details(song)
            guard isCurrent(id) else { return }
            store.mutate(targetIDs: targetIDs) { detail.applying(to: &$0) }
            message = "已应用“\(detail.trackName ?? "")”的标签，关闭窗口后保存以写入文件"
        }
    }
    private func applyArtwork(_ song: CatalogSong) {
        run("正在下载 \(song.source.name)封面…") { id in
            let detail = song.artworkURL == nil ? try await OnlineLookup.details(song) : song
            guard let url = detail.artworkURL else { throw AppError.message("这首歌暂无可用封面") }
            let data = try await OnlineLookup.fetch(url)
            guard NSImage(data: data) != nil else { throw AppError.message("来源返回了无效图片") }
            guard isCurrent(id) else { return }
            store.mutate(targetIDs: targetIDs) { $0.artwork = data }; message = "已应用封面，关闭窗口后保存以写入文件"
        }
    }
    private func previewLyrics(_ song: CatalogSong) {
        run("正在读取 \(song.source.name)歌词…") { id in
            let text = try await OnlineLookup.lyrics(for: song)
            guard isCurrent(id) else { return }
            preview = LyricPreview(id: song.id, title: "\(song.trackName ?? "") · \(song.source.name)", text: text)
            message = "已获取歌词，请预览后应用"
        }
    }
    private func applyLyrics(_ text: String) {
        store.mutate(targetIDs: targetIDs) { $0.lyrics = text }; message = "已应用歌词，关闭窗口后保存以写入文件"
    }
}
