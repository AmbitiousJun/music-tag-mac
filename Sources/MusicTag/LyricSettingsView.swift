import SwiftUI

struct LyricSettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var options: LyricOptions

    private static let sampleOriginal = "[ti:测试歌]\n[00:01.2]第一行\n[00:02.30]第二行"
    private static let sampleTranslation = "[00:01.20]First line\n[00:02.300]Second line"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            aggregateSettings
            Divider()
            lyricSettings
        }
        .padding(24)
        .frame(width: 640)
    }

    private var aggregateSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("聚合搜索来源").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.aggregateSourceOrder) { source in
                    HStack(spacing: 8) {
                        Toggle(source.name, isOn: Binding(
                            get: { store.aggregateSources.contains(source) },
                            set: { store.setAggregateSource(source, enabled: $0) }
                        ))
                        .disabled(store.aggregateSources.count == 1 && store.aggregateSources.contains(source))
                        .accessibilityIdentifier("lookupSettings.source.\(source.rawValue)")
                        .frame(width: 130, alignment: .leading)
                        Button {
                            store.moveAggregateSource(source, up: true)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(source == store.aggregateSourceOrder.first)
                        .help("上移\(source.name)")
                        .accessibilityLabel("上移\(source.name)")
                        .accessibilityIdentifier("aggregate.moveUp.\(source.rawValue)")
                        Button {
                            store.moveAggregateSource(source, up: false)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(source == store.aggregateSourceOrder.last)
                        .help("下移\(source.name)")
                        .accessibilityLabel("下移\(source.name)")
                        .accessibilityIdentifier("aggregate.moveDown.\(source.rawValue)")
                    }
                }
            }
            .toggleStyle(.checkbox)
            Text("至少选择一个来源。批量填充按此顺序匹配，聚合搜索同分结果按此顺序排列。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lyricSettings: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Form {
                    Section("译文") {
                        Toggle("保留译文", isOn: $options.translationEnabled)
                            .accessibilityIdentifier("lyricSettings.translationEnabled")
                        Toggle("仅保留译文", isOn: $options.translationOnly)
                            .disabled(!options.translationEnabled)
                            .help("没有译文时保留原文")
                            .accessibilityIdentifier("lyricSettings.translationOnly")
                        Picker("译文排版", selection: $options.layout) {
                            Text("同行").tag(LyricLayout.inline)
                            Text("原文在前").tag(LyricLayout.originalFirst)
                            Text("原文与译文错时").tag(LyricLayout.staggered)
                            Text("译文在前").tag(LyricLayout.translationFirst)
                            Text("原文与译文分段").tag(LyricLayout.sections)
                        }
                        .disabled(!options.translationEnabled || options.translationOnly)
                        .accessibilityIdentifier("lyricSettings.layout")
                        TextField("同行分隔符", text: $options.separator)
                            .disabled(!options.translationEnabled || options.translationOnly || options.layout != .inline)
                            .accessibilityIdentifier("lyricSettings.separator")
                    }

                    Section("清理与转换") {
                        Toggle("统一时间标签精度", isOn: $options.normalizeTimes)
                            .disabled(options.removeTimes)
                            .accessibilityIdentifier("lyricSettings.normalizeTimes")
                        Toggle("移除时间标签", isOn: $options.removeTimes)
                            .accessibilityIdentifier("lyricSettings.removeTimes")
                        Toggle("移除空行", isOn: $options.removeBlankLines)
                            .accessibilityIdentifier("lyricSettings.removeBlankLines")
                        Toggle("移除 LRC 头部标签", isOn: $options.removeHeaders)
                            .accessibilityIdentifier("lyricSettings.removeHeaders")
                        Picker("简繁转换", selection: $options.conversion) {
                            Text("保留原样").tag(LyricConversion.none)
                            Text("转为简体").tag(LyricConversion.simplified)
                            Text("转为繁体").tag(LyricConversion.traditional)
                        }
                        .accessibilityIdentifier("lyricSettings.conversion")
                    }
                }
                .formStyle(.columns)
                Button("恢复默认") { options = LyricOptions() }
                    .accessibilityIdentifier("lyricSettings.reset")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("歌词预览").font(.headline)
                ScrollView {
                    Text(LyricFormatter.format(
                        original: Self.sampleOriginal,
                        translation: Self.sampleTranslation,
                        options: options
                    ))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("lyricSettings.preview")
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .frame(width: 260, height: 250)
                Text("应用于在线查找与批量填充的新歌词。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
