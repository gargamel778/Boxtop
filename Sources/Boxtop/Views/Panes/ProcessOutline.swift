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

        let scroll = ProcessScrollView()
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
        private var textFont = NSFont.systemFont(ofSize: 12.5)
        private var numericFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        /// Pre-order pids and child counts of the last tree, to skip reloads when only values changed.
        private var treeShape: [Int32] = []
        private static let suspendedColor = NSColor(Color.accentClay)
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
                textFont = NSFont.systemFont(ofSize: CGFloat(fontSize - 0.5))
                numericFont = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(fontSize - 0.5), weight: .regular)
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

        /// Flat list: rows are positional slots whose contents change in place. Processes that come
        /// and go only add or remove rows at the end, and the cells on screen are updated where they
        /// are. (Reloading rows made AppKit replace every visible cell view each second.)
        private func updateFlat(_ items: [ProcessItem], outline: NSOutlineView, structureChanged: Bool) {
            while slots.count < items.count { slots.append(Node(items[slots.count])) }
            for (index, item) in items.enumerated() {
                slots[index].item = item
                slots[index].children = []
            }
            nodes = [:]
            treeShape = []
            let old = roots.count
            roots = Array(slots.prefix(items.count))
            if structureChanged {
                outline.reloadData()
                return
            }
            if items.count > old {
                outline.insertItems(at: IndexSet(integersIn: old..<items.count), inParent: nil, withAnimation: [])
            } else if items.count < old {
                outline.removeItems(at: IndexSet(integersIn: items.count..<old), inParent: nil, withAnimation: [])
            }
            refreshVisibleCells(outline)
        }

        /// Writes the current values into the cells already on screen, without replacing any views.
        private func refreshVisibleCells(_ outline: NSOutlineView) {
            let visible = outline.rows(in: outline.visibleRect)
            let end = min(visible.location + visible.length, outline.numberOfRows)
            guard visible.location < end else { return }
            let keys = outline.tableColumns.map { ProcessSortKey(rawValue: $0.identifier.rawValue) }
            for row in visible.location..<end {
                guard let node = outline.item(atRow: row) as? Node else { continue }
                for (column, key) in keys.enumerated() {
                    guard let key, let cell = outline.view(atColumn: column, row: row, makeIfNecessary: false) as? ProcessCell
                    else { continue }
                    configure(cell, key: key, item: node.item)
                }
            }
        }

        /// Tree view: one node per pid so expansion and selection survive the full reload.
        private func updateTree(_ items: [ProcessItem], outline: NSOutlineView) {
            var seen = [Int32: Node]()
            var shape: [Int32] = []
            func build(_ item: ProcessItem) -> Node {
                let node = nodes[item.pid] ?? Node(item)
                node.item = item
                shape.append(item.pid)
                shape.append(Int32(item.children?.count ?? 0))
                node.children = (item.children ?? []).map(build)
                seen[item.pid] = node
                return node
            }
            let reused = !nodes.isEmpty
            roots = items.map(build)
            nodes = seen
            collapsed = collapsed.filter { seen[$0] != nil }
            // Same processes in the same places: only the values changed.
            if reused, shape == treeShape {
                refreshVisibleCells(outline)
                return
            }
            treeShape = shape
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

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            outlineView.makeView(withIdentifier: ProcessRowView.identifier, owner: nil) as? ProcessRowView ?? ProcessRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let tableColumn,
                  let key = ProcessSortKey(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let cell = dequeue(tableColumn.identifier) ?? ProcessCell(identifier: tableColumn.identifier, withIcon: key == .name)
            configure(cell, key: key, item: node.item)
            return cell
        }

        private func configure(_ cell: ProcessCell, key: ProcessSortKey, item: ProcessItem) {
            switch key {
            case .name:
                let stopped = item.state == .stopped
                cell.set(item.name, font: textFont, color: stopped ? Self.suspendedColor : .labelColor, trailing: false,
                         toolTip: stopped ? "Suspended" : nil)
                cell.setIcon(IconCache.shared.icon(pid: item.pid, path: item.path))
            case .cpu:
                cell.set(String(format: "%.1f", item.cpu), font: numericFont, color: .labelColor, trailing: true)
            case .memory:
                cell.set(Fmt.memory(item.memory), font: numericFont, color: .labelColor, trailing: true)
            case .cpuTime:
                cell.set(Fmt.cpuTime(item.cpuTime), font: numericFont, color: .labelColor, trailing: true)
            case .threads:
                cell.set(String(item.threads), font: numericFont, color: .labelColor, trailing: true)
            case .pid:
                cell.set(String(item.pid), font: numericFont, color: .secondaryLabelColor, trailing: true)
            case .user:
                cell.set(item.user, font: textFont, color: .secondaryLabelColor, trailing: false)
            case .command:
                cell.set(item.command, font: textFont, color: .secondaryLabelColor, trailing: false, toolTip: item.command)
            }
        }

        // Explicit recycling for rows that scroll out or a full reload: NSTableView's own reuse queue
        // was not handing back programmatically created cells.
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

/// Gives the name column back the width it gained while the pane was larger (say, maximized).
/// The table scrolls sideways, so AppKit keeps that width and the numeric columns end up out of view.
final class ProcessScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let table = documentView as? NSTableView,
              let name = table.tableColumns.first(where: { $0.identifier.rawValue == ProcessSortKey.name.rawValue })
        else { return }
        let excess = table.frame.width - contentView.bounds.width
        let defaultWidth = ProcessOutline.Coordinator.columns[0].width
        guard excess > 1, name.width > defaultWidth else { return }
        name.width = max(defaultWidth, name.width - excess)
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

/// Row view that draws its cells into its own layer: one backing store per row instead of one per
/// cell, since all of a row's cells change together every second anyway.
final class ProcessRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ProcessRow")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Table cell that draws its icon and one-line label itself. NSTextField and NSImageView cells each
/// brought a layer, a layout pass and an appearance-driven redraw for some 250 cells that change
/// every second; on slow Macs that machinery cost more than drawing the text.
final class ProcessCell: NSTableCellView {
    private let hasIcon: Bool
    private var text = ""
    private var font = NSFont.systemFont(ofSize: 12.5)
    private var lineHeight: CGFloat = 16
    private var color = NSColor.labelColor
    private var trailing = false
    private var icon: NSImage?

    private static let paragraphs: [Bool: NSParagraphStyle] = ([false: .left, true: .right] as [Bool: NSTextAlignment]).mapValues { alignment in
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    init(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) {
        hasIcon = withIcon
        super.init(frame: .zero)
        self.identifier = identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { false }

    /// Selected rows (emphasized) draw their text in the selection text color.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    /// Only redraws when a value changed.
    func set(_ string: String, font: NSFont, color: NSColor, trailing: Bool, toolTip tip: String? = nil) {
        var changed = false
        if text != string { text = string; changed = true }
        if self.font != font {
            self.font = font
            lineHeight = ceil(("Xg" as NSString).size(withAttributes: [.font: font]).height)
            changed = true
        }
        if self.color != color { self.color = color; changed = true }
        if self.trailing != trailing { self.trailing = trailing; changed = true }
        if changed { needsDisplay = true }
        if toolTip != tip { toolTip = tip }
    }

    func setIcon(_ image: NSImage) {
        guard icon !== image else { return }
        icon = image
        needsDisplay = true
    }

    override func accessibilityLabel() -> String? { text }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 2
        if hasIcon {
            icon?.draw(in: NSRect(x: x, y: floor((bounds.height - 16) / 2), width: 16, height: 16), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 22
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: backgroundStyle == .emphasized ? NSColor.alternateSelectedControlTextColor : color,
            .paragraphStyle: Self.paragraphs[trailing]!,
        ]
        let rect = NSRect(x: x, y: floor((bounds.height - lineHeight) / 2), width: max(0, bounds.width - x - 2), height: lineHeight)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
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
