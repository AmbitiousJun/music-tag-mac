import AppKit
import SwiftUI

/// Keep mouse tracking, keyboard navigation and contextual selection in AppKit.
struct TrackTable: NSViewRepresentable {
    @ObservedObject var store: LibraryStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let table = MusicTrackTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.rowSizeStyle = .custom
        table.rowHeight = 50
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = NSTableHeaderView()
        for (id, title, width, minimum, fixed) in [
            ("title", "标题", 220.0, 160.0, false),
            ("artist", "艺术家", 110.0, 75.0, false),
            ("album", "专辑", 120.0, 80.0, false),
            ("format", "格式", 56.0, 56.0, true),
            ("duration", "时长", 52.0, 52.0, true)
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.minWidth = minimum
            column.maxWidth = fixed ? width : 10_000
            column.width = width
            column.resizingMask = fixed ? [] : [.autoresizingMask, .userResizingMask]
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.menu = context.coordinator.makeMenu()
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.store = store
        coordinator.updating = true
        defer { coordinator.updating = false }
        let items = store.visible
        // Selection changes must not rebuild the rows while AppKit tracks a click.
        if coordinator.items != items {
            coordinator.items = items
            table.reloadData()
        }
        let indexes = IndexSet(items.indices.filter { store.selection.contains(items[$0].id) })
        if table.selectedRowIndexes != indexes {
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let table = scroll.documentView as? NSTableView else { return }
        table.delegate = nil
        table.dataSource = nil
        table.menu = nil
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
        var store: LibraryStore
        var items: [TrackItem] = []
        var updating = false

        init(store: LibraryStore) { self.store = store }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil })
            if store.selection != ids { store.selection = ids }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row), let column = tableColumn else { return nil }
            let item = items[row]
            if column.identifier.rawValue == "title" {
                let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? TrackTitleCell ?? TrackTitleCell()
                cell.identifier = column.identifier
                cell.configure(item)
                return cell
            }
            let cell: TrackValueCell
            if let reused = tableView.makeView(withIdentifier: column.identifier, owner: self) as? TrackValueCell { cell = reused }
            else { cell = TrackValueCell() }
            cell.identifier = column.identifier
            switch column.identifier.rawValue {
            case "artist": cell.label.stringValue = item.tags.artist.isEmpty ? "—" : item.tags.artist
            case "album": cell.label.stringValue = item.tags.album.isEmpty ? "—" : item.tags.album
            case "format":
                cell.label.stringValue = item.format
                cell.label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
                cell.toolTip = item.writable ? "支持标签编辑" : "只读格式"
            default:
                cell.label.stringValue = item.time
                cell.label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            }
            return cell
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            for (title, action) in [
                ("保存标签", #selector(save)), ("试听 / 暂停", #selector(play)),
                ("在访达中显示", #selector(reveal)), ("", nil),
                ("文件名 → 标签", #selector(tagsFromFilename)), ("标签 → 文件名…", #selector(rename)),
                ("从列表移除", #selector(remove))
            ] as [(String, Selector?)] {
                guard let action else { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            return menu
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            !store.selection.isEmpty && (!store.busy || menuItem.action == #selector(play) || menuItem.action == #selector(reveal))
        }

        @objc private func save() { store.save() }
        @objc private func play() { store.togglePlayback() }
        @objc private func reveal() { store.reveal() }
        @objc private func tagsFromFilename() { store.tagsFromFilename() }
        @objc private func rename() { store.showRename = true }
        @objc private func remove() { store.removeSelected() }
    }
}

final class MusicTrackTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !isRowSelected(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }
}

private final class TrackTitleCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let filenameLabel = NSTextField(labelWithString: "")
    private let dirty = NSTextField(labelWithString: "●")
    private let symbol = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        filenameLabel.font = .systemFont(ofSize: 10)
        for label in [titleLabel, filenameLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        dirty.font = .systemFont(ofSize: 8)
        dirty.textColor = .systemOrange
        let text = NSStackView(views: [titleLabel, filenameLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let stack = NSStackView(views: [dirty, symbol, text])
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            dirty.widthAnchor.constraint(equalToConstant: 5),
            symbol.widthAnchor.constraint(equalToConstant: 14),
            symbol.heightAnchor.constraint(equalToConstant: 16)
        ])
        textField = titleLabel
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: TrackItem) {
        titleLabel.stringValue = item.title
        filenameLabel.stringValue = item.url.lastPathComponent
        dirty.alphaValue = item.isDirty ? 1 : 0
        symbol.image = NSImage(systemSymbolName: item.issue == nil ? "music.note" : "exclamationmark.triangle", accessibilityDescription: item.issue)
        symbol.contentTintColor = item.issue == nil ? .secondaryLabelColor : .systemOrange
        toolTip = item.url.path
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }
    private func updateColors() {
        titleLabel.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        filenameLabel.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}

private final class TrackValueCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor }
    }
}
