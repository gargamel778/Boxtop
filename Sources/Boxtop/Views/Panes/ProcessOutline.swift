import AppKit
import SwiftUI

/// The process table, backed by NSOutlineView (like Activity Monitor) because it is reloaded every
/// update with 1000+ rows that constantly reorder: fixed row heights and plain reloads stay cheap,
/// where a diffing SwiftUI Table spent most of its time re-measuring rows.
struct ProcessOutline: NSViewRepresentable {
    let app: AppState
    let items: [ProcessItem]
    let tree: Bool
    let sortKey: ProcessSortKey
    let descending: Bool
    let selection: Int32?
    let fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ProcessOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.style = .inset
        outline.backgroundColor = .clear
        outline.usesAutomaticRowHeights = false
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.gridStyleMask = []
        outline.intercellSpacing = NSSize(width: 8, height: 0)

        for column in Coordinator.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.key.rawValue))
            tableColumn.title = column.key.label
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.headerCell.alignment = column.trailing ? .right : .left
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.key.rawValue, ascending: !column.key.defaultDescending)
            tableColumn.isHidden = column.hiddenByDefault
            outline.addTableColumn(tableColumn)
            if column.key == .name { outline.outlineTableColumn = tableColumn }
        }
        // Widths, order and hidden columns persist across launches.
        outline.autosaveName = "BoxtopProcessTable"
        outline.autosaveTableColumns = true

        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.onDelete = { [weak coordinator] in coordinator?.app?.requestQuit() }
        outline.onOpen = { [weak coordinator] pid in coordinator?.app?.showDetails(for: pid) }
        outline.menu = coordinator.rowMenu
        outline.headerView?.menu = coordinator.headerMenu(for: outline)
        coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    /// The table simply fills the space it is offered; answering directly keeps SwiftUI from
    /// running an Auto Layout pass over the whole table on every update.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 320)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(items: items, tree: tree, sortKey: sortKey, descending: descending,
                                   selection: selection, fontSize: fontSize)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        struct Column {
            let key: ProcessSortKey
            let width: CGFloat
            let minWidth: CGFloat
            let trailing: Bool
            var hiddenByDefault = false
        }

        static let columns: [Column] = [
            Column(key: .name, width: 220, minWidth: 140, trailing: false),
            Column(key: .cpu, width: 62, minWidth: 50, trailing: true),
            Column(key: .memory, width: 80, minWidth: 60, trailing: true),
            Column(key: .cpuTime, width: 76, minWidth: 60, trailing: true),
            Column(key: .threads, width: 56, minWidth: 44, trailing: true),
            Column(key: .pid, width: 58, minWidth: 44, trailing: true),
            Column(key: .user, width: 76, minWidth: 50, trailing: false),
            Column(key: .command, width: 300, minWidth: 100, trailing: false, hiddenByDefault: true),
        ]

        /// Reference wrapper for outline items. In tree view one node per pid keeps expansion across
        /// reloads; in the flat list nodes are positional slots whose contents change in place.
        final class Node {
            var item: ProcessItem
            var children: [Node] = []
            var pid: Int32 { item.pid }
            init(_ item: ProcessItem) { self.item = item }
        }

        weak var app: AppState?
        weak var outline: ProcessOutlineView?
        private var roots: [Node] = []
        private var nodes: [Int32: Node] = [:]
        private var slots: [Node] = []
        private var tree = false
        private var collapsed = Set<Int32>()
        private var updatingSelection = false
        private var fontSize: Double = 13
        private let rowMenuStorage = NSMenu()

        init(app: AppState) {
            self.app = app
            super.init()
            rowMenuStorage.delegate = self
        }

        var rowMenu: NSMenu { rowMenuStorage }

        func update(items: [ProcessItem], tree: Bool, sortKey: ProcessSortKey, descending: Bool,
                    selection: Int32?, fontSize: Double) {
            guard let outline else { return }
            if self.fontSize != fontSize || outline.rowHeight != CGFloat(fontSize + 9) {
                self.fontSize = fontSize
                outline.rowHeight = CGFloat(fontSize + 9)
            }
            let treeChanged = tree != self.tree
            self.tree = tree

            let wanted = [NSSortDescriptor(key: sortKey.rawValue, ascending: !descending)]
            if outline.sortDescriptors.first?.key != wanted[0].key || outline.sortDescriptors.first?.ascending != wanted[0].ascending {
                updatingSelection = true
                outline.sortDescriptors = wanted
                updatingSelection = false
            }

            updatingSelection = true
            defer { updatingSelection = false }
            if tree {
                updateTree(items, outline: outline)
            } else {
                updateFlat(items, outline: outline, structureChanged: treeChanged)
            }

            // Keep the selection on the same process, wherever it moved.
            if let pid = selection, let row = row(of: pid, in: outline) {
                if outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            } else if outline.selectedRow >= 0 {
                outline.deselectAll(nil)
            }
            if treeChanged { outline.scrollRowToVisible(0) }
        }

        /// Flat list: rows are reused positionally and only the visible ones are redrawn, unless the
        /// number of processes changed.
        private func updateFlat(_ items: [ProcessItem], outline: NSOutlineView, structureChanged: Bool) {
            while slots.count < items.count { slots.append(Node(items[slots.count])) }
            for (index, item) in items.enumerated() {
                slots[index].item = item
                slots[index].children = []
            }
            nodes = [:]
            if structureChanged || roots.count != items.count {
                roots = Array(slots.prefix(items.count))
                outline.reloadData()
            } else {
                let visible = outline.rows(in: outline.visibleRect)
                guard visible.length > 0 else { return }
                outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                                   columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
            }
        }

        /// Tree view: one node per pid so expansion and selection survive the full reload.
        private func updateTree(_ items: [ProcessItem], outline: NSOutlineView) {
            var seen = [Int32: Node]()
            func build(_ item: ProcessItem) -> Node {
                let node = nodes[item.pid] ?? Node(item)
                node.item = item
                node.children = (item.children ?? []).map(build)
                seen[item.pid] = node
                return node
            }
            roots = items.map(build)
            nodes = seen
            collapsed = collapsed.filter { seen[$0] != nil }
            outline.reloadData()
            // New parents start expanded unless the user collapsed them (parents before children,
            // since an item can only expand once its parent is visible).
            func expand(_ list: [Node]) {
                for node in list where !node.children.isEmpty && !collapsed.contains(node.pid) {
                    if !outline.isItemExpanded(node) { outline.expandItem(node) }
                    expand(node.children)
                }
            }
            expand(roots)
        }

        private func row(of pid: Int32, in outline: NSOutlineView) -> Int? {
            if tree {
                guard let node = nodes[pid] else { return nil }
                let row = outline.row(forItem: node)
                return row >= 0 ? row : nil
            }
            return roots.firstIndex { $0.pid == pid }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return roots.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return roots[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            tree && !((item as? Node)?.children.isEmpty ?? true)
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updatingSelection, let first = outlineView.sortDescriptors.first, let raw = first.key,
                  let key = ProcessSortKey(rawValue: raw), let app else { return }
            app.preferences.processSort = key
            app.preferences.processDescending = !first.ascending
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let tableColumn,
                  let key = ProcessSortKey(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let item = node.item
            let cell = dequeue(tableColumn.identifier) ?? ProcessCell(identifier: tableColumn.identifier, withIcon: key == .name)
            let numeric = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(fontSize - 0.5), weight: .regular)
            let text = NSFont.systemFont(ofSize: CGFloat(fontSize - 0.5))
            switch key {
            case .name:
                cell.set(item.name, font: text, color: .labelColor, trailing: false)
                cell.imageView?.image = IconCache.shared.icon(pid: item.pid, path: item.path)
                cell.toolTip = item.state == .stopped ? "Suspended" : nil
                cell.textField?.textColor = item.state == .stopped ? NSColor(Color.accentClay) : .labelColor
            case .cpu:
                cell.set(String(format: "%.1f", item.cpu), font: numeric, color: .labelColor, trailing: true)
            case .memory:
                cell.set(Fmt.memory(item.memory), font: numeric, color: .labelColor, trailing: true)
            case .cpuTime:
                cell.set(Fmt.cpuTime(item.cpuTime), font: numeric, color: .labelColor, trailing: true)
            case .threads:
                cell.set(String(item.threads), font: numeric, color: .labelColor, trailing: true)
            case .pid:
                cell.set(String(item.pid), font: numeric, color: .secondaryLabelColor, trailing: true)
            case .user:
                cell.set(item.user, font: text, color: .secondaryLabelColor, trailing: false)
            case .command:
                cell.set(item.command, font: text, color: .secondaryLabelColor, trailing: false)
                cell.toolTip = item.command
            }
            return cell
        }

        // Explicit recycling: every reload replaces all visible rows, and NSTableView's own reuse
        // queue was not handing back programmatically created cells.
        private var pool: [NSUserInterfaceItemIdentifier: [ProcessCell]] = [:]

        private func dequeue(_ identifier: NSUserInterfaceItemIdentifier) -> ProcessCell? {
            pool[identifier]?.popLast()
        }

        func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {
            for column in 0..<rowView.numberOfColumns {
                if let cell = rowView.view(atColumn: column) as? ProcessCell, let identifier = cell.identifier,
                   (pool[identifier]?.count ?? 0) < 200 {
                    pool[identifier, default: []].append(cell)
                }
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let outline, let app else { return }
            let node = outline.item(atRow: outline.selectedRow) as? Node
            if app.selectedPID != node?.pid { app.selectedPID = node?.pid }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !updatingSelection, let node = notification.userInfo?["NSObject"] as? Node else { return }
            collapsed.insert(node.pid)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !updatingSelection, let node = notification.userInfo?["NSObject"] as? Node else { return }
            collapsed.remove(node.pid)
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard let node = sender.item(atRow: sender.clickedRow) as? Node else { return }
            app?.showDetails(for: node.pid)
        }

        // MARK: Menus

        /// Right-click on the header: show or hide columns.
        func headerMenu(for outline: NSOutlineView) -> NSMenu {
            let menu = NSMenu()
            for column in outline.tableColumns where column.identifier.rawValue != ProcessSortKey.name.rawValue {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column
                menu.addItem(item)
            }
            menu.delegate = self
            return menu
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let column = sender.representedObject as? NSTableColumn else { return }
            column.isHidden.toggle()
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            if menu === rowMenuStorage {
                buildRowMenu(menu)
            } else {
                for item in menu.items {
                    if let column = item.representedObject as? NSTableColumn { item.state = column.isHidden ? .off : .on }
                }
            }
        }

        private func buildRowMenu(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, let app, let node = outline.item(atRow: outline.clickedRow) as? Node,
                  let process = app.monitor.latest?.processes.first(where: { $0.pid == node.pid }) else { return }
            let pid = process.pid
            func add(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
                let item = ClosureMenuItem(title: title, action: action)
                menu.addItem(item)
                return item
            }
            _ = add("Show Details") { app.showDetails(for: pid) }
            menu.addItem(.separator())
            _ = add("Quit…") { app.requestQuit(pid: pid) }
            _ = add("Force Quit") { app.requestSignal(SIGKILL, pid: pid) }
            _ = add(process.state == .stopped ? "Resume" : "Suspend") {
                app.requestSignal(process.state == .stopped ? SIGCONT : SIGSTOP, pid: pid)
            }
            let signals = NSMenu()
            for (signal, name) in Signals.common {
                signals.addItem(ClosureMenuItem(title: "\(name) (\(signal))") { app.requestSignal(signal, pid: pid) })
            }
            let signalItem = NSMenuItem(title: "Send Signal", action: nil, keyEquivalent: "")
            signalItem.submenu = signals
            menu.addItem(signalItem)
            menu.addItem(.separator())
            let name = RunningApps.shared.name(pid, path: process.path, fallback: process.name)
            _ = add("Filter by “\(name)”") { app.filterText = name }
            _ = add("Copy PID") { Self.copy(String(pid)) }
            _ = add("Copy Command") { Self.copy(process.command) }
            if !process.path.isEmpty {
                _ = add("Show in Finder") { NSWorkspace.shared.selectFile(process.path, inFileViewerRootedAtPath: "") }
            }
        }

        private static func copy(_ string: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    }
}

/// Outline view that turns ⌫ into Quit and Return into Show Details.
final class ProcessOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    var onOpen: ((Int32) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            onDelete?()
        case 36, 76: // return, enter
            if let node = item(atRow: selectedRow) as? ProcessOutline.Coordinator.Node { onOpen?(node.pid) }
        default:
            super.keyDown(with: event)
        }
    }
}

/// Table cell with an optional icon and a single-line label, laid out by hand (no constraints)
/// because hundreds of cells are reconfigured every second.
final class ProcessCell: NSTableCellView {
    private let hasIcon: Bool

    init(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) {
        hasIcon = withIcon
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        if withIcon {
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            imageView = icon
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        guard let textField else { return }
        var x: CGFloat = 2
        if hasIcon, let imageView {
            imageView.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16)
            x += 22
        }
        let height = ceil(textField.intrinsicContentSize.height)
        textField.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - 2), height: height)
    }

    func set(_ string: String, font: NSFont, color: NSColor, trailing: Bool) {
        guard let textField else { return }
        if textField.stringValue != string { textField.stringValue = string }
        if textField.font != font {
            textField.font = font
            needsLayout = true
        }
        if textField.textColor != color { textField.textColor = color }
        let alignment: NSTextAlignment = trailing ? .right : .left
        if textField.alignment != alignment { textField.alignment = alignment }
        toolTip = nil
    }
}

/// NSMenuItem that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() {
        handler()
    }
}
