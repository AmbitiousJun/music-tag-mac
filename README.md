# MusicTag for Mac

原生 Swift 音乐标签编辑器，采用 macOS 系统控件。需要 macOS 13 或更新版本，默认构建为 Apple Silicon 版。

## 使用

1. 打开 `dist/MusicTag.app`，将音乐文件或文件夹拖入窗口，也可以按 `⌘O` 添加音乐，或 `⇧⌘O` 递归添加文件夹。
2. 在列表选中音乐，在左侧编辑标签、封面和歌词。按住 `⌘` 或 `⇧` 多选；修改字段会应用到所选可写文件，未修改字段保留各自值。
3. 按 `⌘S` 保存所选音乐，`⇧⌘S` 保存全部修改。标签编辑先留在内存，保存后写入原文件。

“音乐”菜单提供歌词导入/导出、简繁转换、文件名填标签和标签生成文件名。重命名模板支持 `{artist}`、`{title}`、`{album}`、`{track}`、`{year}`，例如 `{artist} - {title}`；确认前可以预览。`艺术家 - 标题.mp3` 可通过“文件名 → 标签”快速拆分。

## 格式

| 格式 | 读取与写入 | 说明 |
|---|---|---|
| MP3 | 支持 | ID3v2.3/v2.4，读取旧 ID3v1 |
| FLAC | 支持 | Vorbis Comment、PICTURE |
| M4A / MP4 | 支持 | iTunes 元数据；上限 512 MiB，复杂或无法安全验证的布局会拒绝写入 |
| WAV | 支持 `.wav` | RIFF 元数据和 ID3 |
| AIFF | 支持 `.aif`、`.aiff` | AIFF 元数据和 ID3 |
| 其他可导入音频 | 只读 | 系统可识别时显示元数据或试听，不保证全部格式可解码 |

保存直接调整元数据并保留音频数据，不进行转码。引擎测试包含字段、封面、歌词往返及音频 SHA-256 检查，记录见 [analysis/tests](analysis/tests)。

## 构建

需要 Xcode 或包含 macOS SDK 的开发工具。在项目根目录运行：

```bash
./scripts/build.sh
open dist/MusicTag.app
```

构建使用 `swiftc -Osize` 和系统框架，执行本地 ad-hoc 签名；App 无需 .NET、FFmpeg 或第三方运行时。默认仅包含 arm64，以减少体积。通用版同时包含 arm64 和 x86_64，供 Intel Mac 使用：

```bash
./scripts/build.sh --universal
```

## 技术架构与源码目录

界面采用 SwiftUI，音乐列表使用系统原生 Table；AppKit 负责文件面板、窗口和应用生命周期，AVFoundation 负责音频信息和试听。`LibraryStore` 在主线程维护音乐、选中项与编辑状态，标签引擎直接读写本地元数据。项目通过 `swiftc` 编译，不依赖第三方运行时。

```text
Sources/MusicTag/
├── MusicTagApp.swift   # 应用入口、主窗口、音乐列表和标签编辑界面
├── LibraryStore.swift  # 导入、目录恢复、选择、批量编辑、保存与试听
├── TagEngine.swift     # 音频标签读取和写入
├── MP4Tags.swift       # M4A / MP4 元数据处理
├── OnlineLookup.swift # 在线标签和歌词来源
└── LookupView.swift   # 在线搜索界面
Resources/             # 应用信息
Tests/                 # 标签、业务、原生列表焦点、在线来源和图标测试
scripts/               # 构建、图标生成与测试脚本
.github/workflows/     # 图标、列表交互验证与自动发布
```

## 自动发布

将以 `v` 开头的版本 Tag 推送到 GitHub，会触发 `.github/workflows/release.yml`，构建同时包含 arm64 和 x86_64（amd64）的通用版 `MusicTag.app`，并打包为 `MusicTag-v版本号-universal.dmg`。DMG 内包含 App 和“应用程序”目录快捷方式，可拖入安装。

例如发布 `v1.2.3`：

```bash
git tag v1.2.3
git push origin v1.2.3
```

工作流会将去掉 `v` 前缀的 Tag 写入 App 版本号，并把 `MusicTag-v1.2.3-universal.dmg` 上传到同名 GitHub Release；Release 不存在时自动创建并生成发布说明，重新运行会替换同名附件。使用仓库自带的 `GITHUB_TOKEN`，无需额外配置 Secret。自动构建沿用本地 ad-hoc 签名，未做 Developer ID 签名或公证。

## 验证

格式与业务测试需要本机安装 FFmpeg/ffprobe，仅用于生成和独立校验测试音频，不会打包入 App：

```bash
./scripts/test.sh
```

原生音乐列表回归测试不需要 FFmpeg，会在独立测试窗口中验证目录导入后的连续切换、多选、编辑目标和焦点保留：

```bash
bash scripts/test-selection.sh
```

也可以通过 `FFMPEG`、`FFPROBE` 环境变量指定工具的绝对路径。在线接口测试单独执行，会向公开服务发送固定的测试关键词 `周杰伦 晴天`、`陈奕迅 十年` 和 `The Beatles Yesterday`：

```bash
./scripts/test-lookup.sh  # 离线来源解析、加密向量、错误及兼容接口测试
./scripts/test-online.sh # 四个来源的真实网络验收
```

验证日志保存在 `analysis/tests/*-results.txt`。App 使用本地 ad-hoc 签名，未做 Apple Developer ID 签名或公证。

## 边界与分析资料

撤销和还原针对当前会话的标签：`⌘Z` 撤销标签修改，“还原”恢复到最近保存值。没有持久化标签历史或自动备份库；重命名直接修改原文件名。应用会记住最近一次导入的文件夹（支持多选及拖入），下次启动时重新扫描仍存在的目录；目录不存在则保持空列表。单独添加歌曲不会覆盖目录记录，未保存的标签修改不会跨启动恢复。

