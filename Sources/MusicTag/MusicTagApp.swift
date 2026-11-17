import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        LibraryStore.shared.restoreLastDirectories()
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        LibraryStore.shared.importURLs(filenames.map { URL(fileURLWithPath: $0) })
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            let store = LibraryStore.shared
            if store.busy {
                let alert = NSAlert(); alert.messageText = "正在处理音乐"; alert.informativeText = "请等待当前操作完成后退出。"; alert.runModal()
                return .terminateCancel
            }
            if store.dirtyCount == 0 { return .terminateNow }
            let alert = NSAlert(); alert.messageText = "仍有 \(store.dirtyCount) 首音乐未保存"; alert.informativeText = "返回窗口保存修改，或丢弃修改并退出。"; alert.addButton(withTitle: "返回编辑"); alert.addButton(withTitle: "丢弃并退出")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main struct MusicTagApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = LibraryStore.shared
    var body: some Scene {
        WindowGroup("MusicTag") {
            MainView().environmentObject(store).frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加音乐…") { store.openFiles() }.keyboardShortcut("o")
                Button("添加文件夹…") { store.openFiles(folder: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存所选音乐") { store.save() }.keyboardShortcut("s").disabled(store.selected.allSatisfy { !$0.isDirty } || store.busy)
                Button("保存全部修改") { store.save(all: true) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(store.dirtyCount == 0 || store.busy)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销标签修改") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo || store.busy)
            }
            CommandMenu("音乐") {
                Group {
                    Button("试听 / 暂停") { store.togglePlayback() }.keyboardShortcut(" ", modifiers: [.command]).disabled(store.first == nil)
                    Button("在访达中显示") { store.reveal() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(store.first == nil)
                    Divider()
                    Button("搜索标签与歌词…") { store.showLookup = true }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(store.selection.isEmpty)
                    Button("文件名 → 标签") { store.tagsFromFilename() }.disabled(store.selection.isEmpty)
                    Button("标签 → 文件名…") { store.showRename = true }.disabled(store.selection.isEmpty)
                }
                Group {
                    Divider()
                    Button("导入歌词…") { store.importLyrics() }.disabled(store.selection.isEmpty)
                    Button("导出歌词…") { store.exportLyrics() }.disabled(store.selection.isEmpty)
                    Divider()
                    Button("从列表移除") { store.removeSelected() }.disabled(store.selection.isEmpty)
                }
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var dragOver = false
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sidebar.frame(minWidth: 165, idealWidth: 180, maxWidth: 210)
                inspector.frame(minWidth: 300, idealWidth: 330, maxWidth: 390)
                library.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                if store.busy { ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 14, height: 14) }
                else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                Text(store.status).lineLimit(1).accessibilityIdentifier("library.status")
                Spacer()
                Text("\(store.tracks.count) 首音乐").foregroundStyle(.secondary).accessibilityIdentifier("library.count")
                if !store.selection.isEmpty { Text("已选 \(store.selection.count) 首").foregroundStyle(.secondary).accessibilityIdentifier("library.selectionCount") }
                if store.dirtyCount > 0 { Text("\(store.dirtyCount) 首待保存").foregroundStyle(.orange).accessibilityIdentifier("library.dirtyCount") }
            }.font(.system(size: 11)).padding(.horizontal, 16).frame(height: 30).background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { store.openFiles() } label: { Label("添加音乐", systemImage: "plus") }.help("添加音乐或文件夹 · ⌘O").disabled(store.busy).accessibilityIdentifier("toolbar.addFiles")
                Button { store.openFiles(folder: true) } label: { Label("添加文件夹", systemImage: "folder.badge.plus") }.help("添加音乐文件夹").disabled(store.busy).accessibilityIdentifier("toolbar.addFolder")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }.disabled(!store.canUndo || store.busy).accessibilityIdentifier("toolbar.undo")
                Button { store.showLookup = true } label: { Label("搜索标签", systemImage: "sparkle.magnifyingglass") }.disabled(store.selection.isEmpty || store.busy)
                Button { store.togglePlayback() } label: { Label("试听", systemImage: store.isPlaying ? "pause.fill" : "play.fill") }.disabled(store.first == nil).accessibilityIdentifier("toolbar.play").accessibilityValue(store.isPlaying ? "正在播放" : "已暂停")
                Divider()
                Button { store.save(all: true) } label: { Label("保存修改", systemImage: "square.and.arrow.down") }.disabled(store.dirtyCount == 0 || store.busy).help("保存全部修改 · ⇧⌘S").accessibilityIdentifier("toolbar.saveAll")
            }
        }
        .overlay { if dragOver { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dragOver) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                store.importURLs(urls)
            }
            return true
        }
        .alert("操作提示", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) { Button("好", role: .cancel) { store.alert = nil } } message: { Text(store.alert ?? "") }
        .sheet(isPresented: $store.showLookup) { LookupView().environmentObject(store) }
        .sheet(isPresented: $store.showRename) { RenameView().environmentObject(store) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.accentColor).frame(width: 36, height: 36).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) { Text("MusicTag").font(.headline); Text("让音乐井然有序").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 14).padding(.vertical, 22)
            List(selection: $store.filter) {
                Section("音乐库") {
                    ForEach(LibraryFilter.allCases) { filter in
                        HStack { Label(filter.rawValue, systemImage: filter.symbol); Spacer(); Text("\(store.count(filter))").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary) }.tag(filter)
                    }
                }
            }.listStyle(.sidebar)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                Label("本地音乐，原生编辑", systemImage: "externaldrive").font(.system(size: 10, weight: .medium))
                Text("标签修改会在点击保存后写入原文件。支持多选批量编辑。").font(.system(size: 10)).lineSpacing(4).foregroundStyle(.secondary)
            }.padding(16)
        }.background(.regularMaterial)
    }
    private var inspector: some View {
        VStack(spacing: 0) {
            HStack { Text("标签编辑").font(.headline); Spacer(); if store.selected.count > 1 { Text("批量 · \(store.selected.count)").font(.caption).foregroundStyle(.secondary) } }.padding(16)
            Divider()
            if store.first != nil { TagInspector().environmentObject(store).disabled(store.busy) }
            else {
                VStack(spacing: 12) { Image(systemName: "slider.horizontal.3").font(.system(size: 32, weight: .light)); Text("选择音乐以编辑标签").font(.callout) }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private var library: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(store.filter.rawValue).font(.system(size: 22, weight: .semibold)); Text("\(store.visible.count) 首音乐 · 在这里整理每一处细节").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    Picker("排序方式", selection: $store.sortMode) { Text("文件名").tag(0); Text("艺术家").tag(1); Text("专辑").tag(2) }
                } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).fixedSize().help("排序")
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 16)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索标题、艺术家、专辑或文件名", text: $store.query).textFieldStyle(.plain).accessibilityIdentifier("library.search")
                if !store.query.isEmpty { Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(8).background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 22).padding(.bottom, 16)
            Divider()
            if store.tracks.isEmpty { emptyLibrary }
            else {
                TrackTable(store: store).frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.visible.isEmpty { Text("没有符合条件的音乐").foregroundStyle(.secondary).padding() }
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            ZStack { Circle().fill(Color.accentColor.opacity(0.07)).frame(width: 136, height: 136); Circle().stroke(Color.accentColor.opacity(0.15), lineWidth: 1).frame(width: 112, height: 112); Image(systemName: "opticaldisc").font(.system(size: 65, weight: .ultraLight)).foregroundStyle(Color.accentColor) }
            VStack(spacing: 8) { Text("给音乐一个完整的名字").font(.system(size: 23, weight: .medium)); Text("拖入音乐或文件夹，编辑标签、封面与歌词").foregroundStyle(.secondary) }
            Button { store.openFiles() } label: { Label("添加音乐", systemImage: "plus").padding(.horizontal, 12).padding(.vertical, 4) }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("MP3 · FLAC · M4A · WAV · AIFF").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TagInspector: View {
    @EnvironmentObject var store: LibraryStore
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    cover
                    if let item = store.first, !item.writable {
                        Label("此格式只读，可试听及查看信息", systemImage: "lock").font(.caption).foregroundStyle(.orange)
                    }
                    if let issue = store.first?.issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    Picker("编辑内容", selection: $tab) { Text("标签").tag(0); Text("歌词").tag(1); Text("信息").tag(2) }.pickerStyle(.segmented).accessibilityIdentifier("inspector.tabs")
                    Group {
                        if tab == 0 { fields }
                        else if tab == 1 { lyrics }
                        else { information }
                    }
                }.padding(16)
            }
            Divider()
            HStack {
                Button("还原") { store.revertSelected() }.disabled(store.selected.allSatisfy { !$0.isDirty }).accessibilityIdentifier("inspector.revert")
                Spacer()
                Button("保存标签") { store.save() }.buttonStyle(.borderedProminent).disabled(store.selected.allSatisfy { !$0.isDirty }).accessibilityIdentifier("inspector.save")
            }.padding(14)
        }
    }
    private var cover: some View {
        HStack(alignment: .center, spacing: 16) {
            Group {
                if let data = store.first?.tags.artwork, let image = NSImage(data: data) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                else { ZStack { Color.accentColor.opacity(0.05); Image(systemName: "music.note").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Color.accentColor.opacity(0.55)) } }
            }.frame(width: 126, height: 126).background(Color(nsColor: .windowBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.07))).shadow(color: .black.opacity(0.06), radius: 7, y: 3)
            VStack(alignment: .leading, spacing: 9) {
                Text("专辑封面").font(.system(size: 12, weight: .medium))
                if let data = store.first?.tags.artwork, let image = NSImage(data: data), let rep = image.representations.first { Text("\(rep.pixelsWide) × \(rep.pixelsHigh)").font(.system(size: 10)).foregroundStyle(.secondary) }
                else { Text("添加一张喜欢的封面").font(.system(size: 10)).foregroundStyle(.secondary) }
                Button("选择图片…") { store.chooseArtwork() }.controlSize(.small).disabled(!store.hasWritableSelection).accessibilityIdentifier("artwork.choose")
                HStack(spacing: 10) {
                    Button("导出") { store.exportArtwork() }.disabled(store.first?.tags.artwork == nil)
                    Button("移除") { store.mutate { $0.artwork = nil } }.disabled(store.first?.tags.artwork == nil || !store.hasWritableSelection)
                }.buttonStyle(.link).font(.system(size: 10))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.selected.count > 1 { Text("空白且标注“多个值”的字段保留各自内容；修改字段将应用到所有选中音乐。").font(.caption).foregroundStyle(.secondary).lineSpacing(3) }
            ForEach(TagField.all) { field in
                VStack(alignment: .leading, spacing: 5) {
                    Text(field.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextField(store.mixed(field.key) ? "多个值" : "填写\(field.name)", text: store.binding(field)).textFieldStyle(.roundedBorder).accessibilityIdentifier("tag.\(field.id)")
                }
            }
            HStack { Button("文件名 → 标签") { store.tagsFromFilename() }; Spacer(); Menu { Button("简体 → 繁体") { store.transformChinese(traditional: true) }; Button("繁体 → 简体") { store.transformChinese(traditional: false) } } label: { Image(systemName: "character.book.closed") }.fixedSize() }.controlSize(.small).padding(.top, 3)
        }.disabled(!store.hasWritableSelection)
    }
    private var lyrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Button("导入…") { store.importLyrics() }; Button("导出…") { store.exportLyrics() }; Spacer(); Menu { Button("移除时间标签") { store.cleanLyrics(removeTimes: true) }; Button("移除空行") { store.cleanLyrics(removeTimes: false) } } label: { Image(systemName: "wand.and.stars") }.fixedSize() }.controlSize(.small)
            TextEditor(text: Binding(get: { store.common(\.lyrics) }, set: { store.set(\.lyrics, $0, name: "歌词") })).font(.system(size: 12, design: .monospaced)).frame(minHeight: 320).padding(6).background(Color(nsColor: .textBackgroundColor)).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.2))).disabled(!store.hasWritableSelection).accessibilityIdentifier("tag.lyrics")
            Text(store.mixed(\.lyrics) ? "多个歌词值；编辑后将应用到所有选中音乐。" : "支持纯文本及 LRC 时间标签。保存后嵌入音乐文件。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var information: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = store.first {
                ForEach([("文件名", item.url.lastPathComponent), ("格式", item.format), ("时长", item.time), ("文件大小", ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)), ("采样率", item.sampleRate > 0 ? String(format: "%.1f kHz", item.sampleRate / 1000) : "—"), ("声道", item.channels > 0 ? "\(item.channels)" : "—"), ("标签写入", item.writable ? "支持 · 保留音频数据" : "只读"), ("位置", item.url.deletingLastPathComponent().path)], id: \.0) { label, value in VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 12)).textSelection(.enabled) } }
                Button("在访达中显示") { store.reveal() }.controlSize(.small)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RenameView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var pattern = "{artist} - {title}"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("按标签重命名").font(.title2).fontWeight(.semibold)
            Text("修改原文件名；已存在的同名文件会阻止操作。").foregroundStyle(.secondary)
            TextField("命名模板", text: $pattern).textFieldStyle(.roundedBorder).accessibilityIdentifier("rename.pattern")
            Text("可用字段：{artist}  {title}  {album}  {track}  {year}").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 12) { ForEach(store.selected.prefix(12)) { item in VStack(alignment: .leading, spacing: 4) { Text(item.url.lastPathComponent).foregroundStyle(.secondary); Label(store.renamed(item, pattern: pattern), systemImage: "arrow.turn.down.right") }.font(.system(size: 12)) } } }.frame(height: 210)
            HStack { Spacer(); Button("取消") { store.showRename = false }.keyboardShortcut(.cancelAction); Button("重命名 \(store.selected.count) 个文件") { store.rename(pattern: pattern) }.buttonStyle(.borderedProminent).disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding(26).frame(width: 560)
    }
}
