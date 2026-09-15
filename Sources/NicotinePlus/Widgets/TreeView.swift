// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import NicotineCore

// MARK: - Values

/// A value stored in a list view column.
enum TreeValue: Hashable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case bool(Bool)
    case object(AnyObject)

    static func == (lhs: TreeValue, rhs: TreeValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(lhs), .string(rhs)): lhs == rhs
        case let (.int(lhs), .int(rhs)): lhs == rhs
        case let (.bool(lhs), .bool(rhs)): lhs == rhs
        case let (.object(lhs), .object(rhs)): lhs === rhs
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case let .string(value): hasher.combine(value)
        case let .int(value): hasher.combine(value)
        case let .bool(value): hasher.combine(value)
        case let .object(value): hasher.combine(ObjectIdentifier(value))
        }
    }

    var string: String {
        switch self {
        case let .string(value): value
        case let .int(value): String(value)
        case let .bool(value): String(value)
        case .object: ""
        }
    }

    var int: Int {
        switch self {
        case let .int(value): value
        case let .bool(value): value ? 1 : 0
        case let .string(value): Int(value) ?? 0
        case .object: 0
        }
    }

    var bool: Bool {
        switch self {
        case let .bool(value): value
        case let .int(value): value != 0
        case let .string(value): !value.isEmpty
        case .object: true
        }
    }

    func object<T: AnyObject>(as type: T.Type = T.self) -> T? {
        if case let .object(value) = self {
            return value as? T
        }
        return nil
    }

    var isEmpty: Bool {
        switch self {
        case let .string(value): value.isEmpty
        case let .int(value): value == 0
        case let .bool(value): !value
        case .object: false
        }
    }

    var description: String { string }

    fileprivate func compare(_ other: TreeValue) -> ComparisonResult {
        switch (self, other) {
        case let (.string(lhs), .string(rhs)):
            return lhs.localizedCompare(rhs)
        case let (.int(lhs), .int(rhs)):
            return lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
        case let (.bool(lhs), .bool(rhs)):
            return lhs == rhs ? .orderedSame : (lhs ? .orderedDescending : .orderedAscending)
        default:
            return .orderedSame
        }
    }
}

extension TreeValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Wraps a value type, so it can be stored in a list view column.
final class Box<Value> {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

// MARK: - Rows

/// A row in a list view. Rows are identified by reference, and stay valid
/// until removed from the list view.
final class TreeRow: NSObject {
    fileprivate(set) var values: [TreeValue]
    fileprivate(set) weak var parent: TreeRow?
    fileprivate(set) var children: [TreeRow] = []
    fileprivate var needsSort = false
    fileprivate var isRemoved = false

    fileprivate init(values: [TreeValue], parent: TreeRow?) {
        self.values = values
        self.parent = parent
    }

    var hasChildren: Bool { !children.isEmpty }
}

// MARK: - Columns

struct TreeColumn {

    enum Kind {
        case text
        case number
        case progress
        case toggle
        case icon
    }

    enum SortOrder {
        case ascending
        case descending
    }

    let id: String
    /// Column title. Columns without a title only store data, and are not displayed.
    var title: String?
    var kind: Kind = .text
    var width: CGFloat?
    var expandsColumn = false
    /// Identifier of the data column used for sorting this column
    var sortColumn: String?
    var defaultSortOrder: SortOrder?
    /// Values in this column are used as keys for looking up rows
    var isIteratorKey = false
    var hidesHeader = false
    /// Data column containing the font weight (e.g. 700 for bold)
    var textWeightColumn: String?
    /// Data column containing the underline state
    var textUnderlineColumn: String?
    /// Data column containing whether the cell is sensitive
    var sensitiveColumn: String?
    var toggleCallback: (@MainActor (TreeView, TreeRow) -> Void)?
    var tooltipCallback: (@MainActor (TreeView, TreeRow) -> String?)?

    /// Hidden data column
    static func data(_ id: String, isIteratorKey: Bool = false, sortOrder: SortOrder? = nil) -> TreeColumn {
        TreeColumn(id: id, title: nil, defaultSortOrder: sortOrder, isIteratorKey: isIteratorKey)
    }
}

// MARK: - Tree View

/// A list view with optional tree structure, backed by `NSOutlineView`.
///
/// Column widths, visibility, order and (optionally) sorting are persisted in
/// the "columns" configuration section.
@MainActor
final class TreeView: NSObject {

    let scrollView = NSScrollView()
    let outlineView = TreeOutlineView()

    private(set) var iterators: [TreeValue: TreeRow] = [:]
    /// Whether rows can have child rows. Clear the list view before changing it.
    var hasTree: Bool {
        didSet {
            setShowExpanders(hasTree)
            outlineView.reloadData()
        }
    }
    let multiSelect: Bool

    var popupMenu: PopupMenu?
    var accelerators: [Accelerator] = []

    private let widgetName: String?
    private let secondaryName: String?
    private let columns: [TreeColumn]
    private let persistentSort: Bool
    private let activateRowCallback: (@MainActor (TreeView, TreeRow, String) -> Void)?
    private let selectRowCallback: (@MainActor (TreeView, TreeRow?) -> Void)?
    private let deleteAcceleratorCallback: (@MainActor (TreeView) -> Void)?
    private let focusInCallback: (@MainActor (TreeView) -> Void)?

    private var columnIndices: [String: Int] = [:]
    private var tableColumns: [String: NSTableColumn] = [:]
    private var iteratorKeyColumn = 0
    private let root = TreeRow(values: [], parent: nil)

    private var defaultSortColumn: Int?
    private var defaultSortOrder = TreeColumn.SortOrder.ascending
    private var sortColumn: Int?
    private var sortOrder: TreeColumn.SortOrder?
    private var isFrozen = false

    private var isUpdateScheduled = false
    private var needsReload = false
    private var changedRows: [TreeRow] = []
    private var isApplyingColumnConfig = false
    private var isFillingWidth = false
    private weak var fillColumn: NSTableColumn?
    private var fillExtraWidth: CGFloat = 0
    private var isSelectingProgrammatically = false

    init(columns: [TreeColumn], hasTree: Bool = false, multiSelect: Bool = false, persistentSort: Bool = false,
         name: String? = nil, secondaryName: String? = nil,
         activateRow: (@MainActor (TreeView, TreeRow, String) -> Void)? = nil,
         selectRow: (@MainActor (TreeView, TreeRow?) -> Void)? = nil,
         deleteAccelerator: (@MainActor (TreeView) -> Void)? = nil,
         focusIn: (@MainActor (TreeView) -> Void)? = nil) {

        self.columns = columns
        self.hasTree = hasTree
        self.multiSelect = multiSelect
        self.persistentSort = persistentSort
        self.widgetName = name
        self.secondaryName = secondaryName
        self.activateRowCallback = activateRow
        self.selectRowCallback = selectRow
        self.deleteAcceleratorCallback = deleteAccelerator
        self.focusInCallback = focusIn

        super.init()

        outlineView.treeView = self
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.allowsMultipleSelection = multiSelect
        outlineView.allowsEmptySelection = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.style = .fullWidth
        outlineView.rowSizeStyle = .default
        outlineView.usesAutomaticRowHeights = false
        outlineView.indentationPerLevel = hasTree ? 14 : 0
        outlineView.autoresizesOutlineColumn = false
        outlineView.target = self
        outlineView.doubleAction = #selector(onDoubleClick(_:))

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        initialiseColumns()

        let notificationCenter = NotificationCenter.default
        scrollView.contentView.postsFrameChangedNotifications = true
        notificationCenter.addObserver(self, selector: #selector(onContentViewFrameChanged(_:)),
                                       name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        notificationCenter.addObserver(self, selector: #selector(onColumnsChanged(_:)),
                                       name: NSTableView.columnDidMoveNotification, object: outlineView)
        notificationCenter.addObserver(self, selector: #selector(onColumnsChanged(_:)),
                                       name: NSTableView.columnDidResizeNotification, object: outlineView)

        accelerators = [
            Accelerator(.character("c"), modifiers: .command) { [unowned self] in onCopyCellData() },
            Accelerator(.return) { [unowned self] in onActivateAccelerator() },
            Accelerator(.character("\\"), modifiers: .command) { [unowned self] in onExpandRowLevelAccelerator() },
            Accelerator(.character("-")) { [unowned self] in onCollapseRowAccelerator() },
            Accelerator(.character("+")) { [unowned self] in onExpandRowAccelerator() },
            Accelerator(.character("=")) { [unowned self] in onExpandRowAccelerator() }
        ]

        if deleteAccelerator != nil {
            accelerators.append(Accelerator(.delete) { [unowned self] in onDeleteAccelerator() })
            accelerators.append(Accelerator(.backspace, modifiers: .command) { [unowned self] in onDeleteAccelerator() })
        }
    }

    // MARK: Columns

    private func columnConfig() -> [String: JSONValue] {
        guard let widgetName, let widgetConfig = config.columns[widgetName]?.objectValue else {
            return [:]
        }

        if let secondaryName, let secondaryConfig = widgetConfig[secondaryName]?.objectValue {
            return secondaryConfig
        }
        return widgetConfig
    }

    private func initialiseColumns() {
        for (index, column) in columns.enumerated() {
            columnIndices[column.id] = index
        }

        let columnConfig = columnConfig()
        var visibleColumns: [(position: Int, column: NSTableColumn)] = []
        var hasVisibleColumnHeader = false

        for (index, column) in columns.enumerated() {
            let sortColumnIndex = columnIndices[column.sortColumn ?? column.id] ?? index

            if column.isIteratorKey {
                iteratorKeyColumn = index
            }

            if let defaultSortOrder = column.defaultSortOrder {
                defaultSortColumn = sortColumnIndex
                self.defaultSortOrder = defaultSortOrder

                if sortColumn == nil {
                    sortColumn = sortColumnIndex
                    sortOrder = defaultSortOrder
                }
            }

            guard let title = column.title else {
                // Hidden data column
                continue
            }

            let columnProperties = columnConfig[column.id]?.objectValue ?? [:]
            var width = column.width

            if column.kind != .icon, let savedWidth = columnProperties["width"]?.doubleValue, savedWidth > 0 {
                width = CGFloat(savedWidth)
            }

            if persistentSort, let savedSortOrder = columnProperties["sort"]?.stringValue {
                sortColumn = sortColumnIndex
                sortOrder = (savedSortOrder == "descending") ? .descending : .ascending
            }

            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.hidesHeader ? "" : title
            tableColumn.minWidth = 24
            tableColumn.headerToolTip = title

            if !column.hidesHeader {
                hasVisibleColumnHeader = true
            }

            switch column.kind {
            case .number, .progress:
                tableColumn.headerCell.alignment = .right
            case .toggle, .icon:
                tableColumn.headerCell.alignment = .center
            case .text:
                break
            }

            if column.kind == .icon {
                tableColumn.resizingMask = []
                tableColumn.width = width ?? 24
                tableColumn.maxWidth = max(tableColumn.width, 48)
            } else {
                tableColumn.resizingMask = .userResizingMask

                if width == 0 {
                    // Fit the column to its title
                    tableColumn.width = max(tableColumn.headerCell.cellSize.width + 12, tableColumn.minWidth)
                } else {
                    tableColumn.width = width ?? 100
                }
            }

            tableColumn.isHidden = !(columnProperties["visible"]?.boolValue ?? true)
            tableColumns[column.id] = tableColumn

            let position = columnProperties["position"]?.intValue ?? index
            visibleColumns.append((position, tableColumn))
        }

        isApplyingColumnConfig = true

        // Restore column order from config
        for (_, tableColumn) in visibleColumns.sorted(by: { $0.position < $1.position }) {
            outlineView.addTableColumn(tableColumn)
        }

        isApplyingColumnConfig = false

        // Columns keep their width, expanding columns take up any remaining space
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing

        if !hasVisibleColumnHeader {
            outlineView.headerView = nil
        } else {
            outlineView.headerView?.menu = makeColumnHeaderMenu()
        }

        updateColumnProperties()
        updateSortIndicator()
    }

    private func updateColumnProperties() {
        // Set first non-icon column as the expander column
        for tableColumn in outlineView.tableColumns where !tableColumn.isHidden {
            guard let column = column(for: tableColumn), column.kind != .icon else {
                continue
            }

            if outlineView.outlineTableColumn !== tableColumn {
                outlineView.outlineTableColumn = tableColumn
            }
            break
        }
    }

    private func column(for tableColumn: NSTableColumn?) -> TreeColumn? {
        guard let tableColumn, let index = columnIndices[tableColumn.identifier.rawValue] else {
            return nil
        }
        return columns[index]
    }

    /// Saves column widths, visibility and order for the next session.
    func saveColumns() {
        guard let widgetName, !isApplyingColumnConfig else {
            return
        }

        let previousConfig = columnConfig()
        var savedColumns: [String: JSONValue] = [:]

        for (position, tableColumn) in outlineView.tableColumns.enumerated() {
            let columnID = tableColumn.identifier.rawValue
            let width = Int(tableColumn.width - (tableColumn === fillColumn ? fillExtraWidth : 0))
            let isVisible = !tableColumn.isHidden
            var properties: [String: JSONValue] = [
                "visible": .bool(isVisible),
                "position": .int(position)
            ]

            if width > 0 {
                properties["width"] = .int(width)
            } else if let previousWidth = previousConfig[columnID]?.objectValue?["width"] {
                properties["width"] = previousWidth
            }

            if persistentSort, let column = column(for: tableColumn) {
                let sortColumnIndex = columnIndices[column.sortColumn ?? column.id]

                if sortColumnIndex == sortColumn, sortColumn != defaultSortColumn, let sortOrder {
                    properties["sort"] = .string(sortOrder == .descending ? "descending" : "ascending")
                }
            }

            savedColumns[columnID] = .object(properties)
        }

        if let secondaryName {
            var widgetConfig = config.columns[widgetName]?.objectValue ?? [:]
            widgetConfig[secondaryName] = .object(savedColumns)
            config.columns[widgetName] = .object(widgetConfig)
        } else {
            config.columns[widgetName] = .object(savedColumns)
        }
    }

    @objc private func onColumnsChanged(_ notification: Notification) {
        guard !isFillingWidth else {
            return
        }

        if notification.name == NSTableView.columnDidResizeNotification,
           let resizedColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
           resizedColumn === fillColumn {
            // The user resized the expanding column, keep its new width
            fillExtraWidth = 0
            fillColumn = nil
        }

        saveColumns()
        fillAvailableWidth()
    }

    @objc private func onContentViewFrameChanged(_ notification: Notification) {
        fillAvailableWidth()
    }

    /// Widens the last visible expanding column to fill the available width.
    private func fillAvailableWidth() {
        guard !isFillingWidth else {
            return
        }

        isFillingWidth = true
        defer { isFillingWidth = false }

        if let fillColumn, fillExtraWidth > 0 {
            fillColumn.width -= fillExtraWidth
        }

        fillColumn = nil
        fillExtraWidth = 0

        let visibleTableColumns = outlineView.tableColumns.filter { !$0.isHidden }
        let spacing = outlineView.intercellSpacing.width
        let totalWidth = visibleTableColumns.reduce(0) { $0 + $1.width + spacing }
        let availableWidth = scrollView.contentView.bounds.width

        guard availableWidth > totalWidth + 1 else {
            return
        }

        let expandingColumn = visibleTableColumns.last { column(for: $0)?.expandsColumn == true }
            ?? visibleTableColumns.last

        guard let expandingColumn else {
            return
        }

        let extraWidth = floor(availableWidth - totalWidth)
        expandingColumn.width += extraWidth
        fillColumn = expandingColumn
        fillExtraWidth = extraWidth
    }

    var visibleColumns: [String] {
        outlineView.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
    }

    // MARK: Column Header Menu

    private func makeColumnHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    fileprivate func populateColumnHeaderMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let visibleColumns = outlineView.tableColumns.filter { !$0.isHidden }

        for (columnNumber, tableColumn) in outlineView.tableColumns.enumerated() {
            var title = tableColumn.headerToolTip ?? tableColumn.title

            if title.isEmpty {
                title = String(localized: "Column #\(columnNumber + 1)")
            }

            let menuItem = NSMenuItem(title: title, action: #selector(onColumnHeaderToggled(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = tableColumn
            menuItem.state = tableColumn.isHidden ? .off : .on
            menuItem.isEnabled = tableColumn.isHidden || visibleColumns.count > 1
            menu.addItem(menuItem)
        }
    }

    @objc private func onColumnHeaderToggled(_ sender: NSMenuItem) {
        guard let tableColumn = sender.representedObject as? NSTableColumn else {
            return
        }

        tableColumn.isHidden.toggle()
        updateColumnProperties()
        saveColumns()
        fillAvailableWidth()
    }

    // MARK: Sorting

    func freeze() {
        isFrozen = true
    }

    func unfreeze() {
        isFrozen = false
        markAllNeedSort(root)
        scheduleUpdate(needsReload: true)
    }

    private func markAllNeedSort(_ row: TreeRow) {
        row.needsSort = true

        for child in row.children where child.hasChildren {
            markAllNeedSort(child)
        }
    }

    private func sortChildren(of row: TreeRow) {
        guard row.needsSort else {
            return
        }

        row.needsSort = false

        if let sortColumn, let sortOrder {
            let isAscending = (sortOrder == .ascending)

            row.children.sort { lhs, rhs in
                let result = lhs.values[sortColumn].compare(rhs.values[sortColumn])
                return isAscending ? (result == .orderedAscending) : (result == .orderedDescending)
            }
        }

        for child in row.children where child.hasChildren {
            sortChildren(of: child)
        }
    }

    private func isSortColumn(_ index: Int) -> Bool {
        index == sortColumn
    }

    private func updateSortIndicator() {
        for tableColumn in outlineView.tableColumns {
            outlineView.setIndicatorImage(nil, in: tableColumn)
        }
        outlineView.highlightedTableColumn = nil

        guard let sortColumn, let sortOrder else {
            return
        }

        for tableColumn in outlineView.tableColumns {
            guard let column = column(for: tableColumn),
                  columnIndices[column.sortColumn ?? column.id] == sortColumn else {
                continue
            }

            let imageName = (sortOrder == .ascending) ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
            outlineView.setIndicatorImage(NSImage(named: imageName), in: tableColumn)
            break
        }
    }

    /// Reset sorting when column header has been pressed three times.
    fileprivate func onColumnHeaderClicked(_ tableColumn: NSTableColumn) {
        guard let column = column(for: tableColumn),
              let sortColumnIndex = columnIndices[column.sortColumn ?? column.id] else {
            return
        }

        let firstSortOrder: TreeColumn.SortOrder
        let secondSortOrder: TreeColumn.SortOrder
        let isStringColumn = if case .string = sampleValue(sortColumnIndex) { true } else { false }

        if isStringColumn || column.id == "in_queue" || column.id == "queue_position" {
            // String value (or queue position column): ascending sort by default
            firstSortOrder = .ascending
            secondSortOrder = .descending
        } else {
            // Numerical value: descending sort by default
            firstSortOrder = .descending
            secondSortOrder = .ascending
        }

        if sortColumn != sortColumnIndex {
            sortColumn = sortColumnIndex
            sortOrder = firstSortOrder

        } else if sortOrder == firstSortOrder {
            sortOrder = secondSortOrder

        } else if defaultSortColumn != nil {
            // Reset list view to default state
            sortColumn = defaultSortColumn
            sortOrder = defaultSortOrder

        } else {
            sortOrder = firstSortOrder
        }

        updateSortIndicator()
        markAllNeedSort(root)
        scheduleUpdate(needsReload: true)
        saveColumns()
    }

    private func sampleValue(_ columnIndex: Int) -> TreeValue? {
        if let firstRow = root.children.first {
            return firstRow.values[columnIndex]
        }

        switch columns[columnIndex].kind {
        case .text, .icon: return .string("")
        default: return .int(0)
        }
    }

    // MARK: Updating

    private func scheduleUpdate(needsReload: Bool = false, changedRow: TreeRow? = nil) {
        if needsReload {
            self.needsReload = true
        } else if let changedRow {
            changedRows.append(changedRow)
        }

        guard !isUpdateScheduled else {
            return
        }

        isUpdateScheduled = true

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.update()
            }
        }
    }

    /// Applies pending changes to the list view. Changes are coalesced, and
    /// applied at most once per run loop iteration.
    func update() {
        isUpdateScheduled = false

        if needsReload {
            needsReload = false
            changedRows.removeAll()

            if !isFrozen {
                sortChildren(of: root)
            }

            let selectedRows = selectedRowObjects()

            isSelectingProgrammatically = true
            outlineView.reloadData()

            let indexes = IndexSet(selectedRows.compactMap { row -> Int? in
                let index = outlineView.row(forItem: row)
                return index >= 0 ? index : nil
            })
            outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
            isSelectingProgrammatically = false
            return
        }

        guard !changedRows.isEmpty else {
            return
        }

        let visibleRange = outlineView.rows(in: outlineView.visibleRect)
        var indexes = IndexSet()

        for row in changedRows {
            let index = outlineView.row(forItem: row)

            if index >= 0 && NSLocationInRange(index, visibleRange) {
                indexes.insert(index)
            }
        }

        changedRows.removeAll()

        if !indexes.isEmpty {
            outlineView.reloadData(forRowIndexes: indexes,
                                   columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
        }
    }

    // MARK: Rows

    @discardableResult
    func addRow(_ values: [TreeValue], selectRow: Bool = true, parent: TreeRow? = nil) -> TreeRow? {
        let key = values[iteratorKeyColumn]

        guard iterators[key] == nil else {
            return nil
        }

        let parentRow = parent ?? root
        let row = TreeRow(values: values, parent: parent)

        parentRow.children.append(row)
        parentRow.needsSort = true
        iterators[key] = row

        scheduleUpdate(needsReload: true)

        if selectRow {
            self.selectRow(row)
        }

        return row
    }

    func rowValue(_ row: TreeRow, _ columnID: String) -> TreeValue {
        row.values[columnIndices[columnID]!]
    }

    func setRowValue(_ row: TreeRow, _ columnID: String, _ value: TreeValue) {
        let index = columnIndices[columnID]!

        guard row.values[index] != value else {
            return
        }

        row.values[index] = value
        rowChanged(row, columnIndex: index)
    }

    func setRowValues(_ row: TreeRow, _ values: [String: TreeValue]) {
        var isSortColumnChanged = false

        for (columnID, value) in values {
            let index = columnIndices[columnID]!
            row.values[index] = value

            if isSortColumn(index) {
                isSortColumnChanged = true
            }
        }

        if isSortColumnChanged {
            (row.parent ?? root).needsSort = true
            scheduleUpdate(needsReload: true)
        } else {
            scheduleUpdate(changedRow: row)
        }
    }

    private func rowChanged(_ row: TreeRow, columnIndex: Int) {
        if isSortColumn(columnIndex) {
            (row.parent ?? root).needsSort = true
            scheduleUpdate(needsReload: true)
        } else {
            scheduleUpdate(changedRow: row)
        }
    }

    func removeRow(_ row: TreeRow) {
        removeIterators(row)

        let parentRow = row.parent ?? root
        parentRow.children.removeAll { $0 === row }

        scheduleUpdate(needsReload: true)
    }

    private func removeIterators(_ row: TreeRow) {
        row.isRemoved = true
        iterators.removeValue(forKey: row.values[iteratorKeyColumn])

        for child in row.children {
            removeIterators(child)
        }
    }

    func clear() {
        root.children.removeAll()
        iterators.removeAll()
        changedRows.removeAll()
        needsReload = false
        isUpdateScheduled = false

        isSelectingProgrammatically = true
        outlineView.reloadData()
        isSelectingProgrammatically = false
    }

    func children(of row: TreeRow?) -> [TreeRow] {
        (row ?? root).children
    }

    var rootRows: [TreeRow] { root.children }
    var isEmpty: Bool { iterators.isEmpty }

    // MARK: Selection

    private func selectedRowObjects() -> [TreeRow] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? TreeRow }
    }

    var selectedRows: [TreeRow] {
        if needsReload {
            update()
        }
        return selectedRowObjects()
    }

    var numSelectedRows: Int { outlineView.numberOfSelectedRows }
    var isSelectionEmpty: Bool { outlineView.numberOfSelectedRows <= 0 }

    var focusedRow: TreeRow? {
        if needsReload {
            update()
        }

        let clickedRow = outlineView.clickedRow

        if clickedRow >= 0 {
            return outlineView.item(atRow: clickedRow) as? TreeRow
        }

        let selectedRow = outlineView.selectedRow
        return selectedRow >= 0 ? outlineView.item(atRow: selectedRow) as? TreeRow : nil
    }

    var focusedColumn: String? {
        let columnIndex = outlineView.lastClickedColumn

        guard columnIndex >= 0, columnIndex < outlineView.numberOfColumns else {
            return visibleColumns.first
        }
        return outlineView.tableColumns[columnIndex].identifier.rawValue
    }

    func selectRow(_ row: TreeRow? = nil, expandRows: Bool = true, shouldScroll: Bool = true) {
        update()

        guard let row = row ?? root.children.first else {
            return
        }

        if expandRows {
            var ancestors: [TreeRow] = []
            var parent = row.parent

            while let ancestor = parent {
                ancestors.insert(ancestor, at: 0)
                parent = ancestor.parent
            }

            for ancestor in ancestors {
                outlineView.expandItem(ancestor)
            }
        }

        let index = outlineView.row(forItem: row)

        guard index >= 0 else {
            return
        }

        outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: !shouldScroll && multiSelect)

        if shouldScroll {
            outlineView.scrollRowToVisible(index)
        }
    }

    func selectAllRows() {
        update()
        outlineView.selectAll(nil)
    }

    func unselectAllRows() {
        outlineView.deselectAll(nil)
    }

    func isRowSelected(_ row: TreeRow) -> Bool {
        let index = outlineView.row(forItem: row)
        return index >= 0 && outlineView.isRowSelected(index)
    }

    // MARK: Expanding

    @discardableResult
    func expandRow(_ row: TreeRow) -> Bool {
        update()

        guard row.hasChildren else {
            return false
        }

        outlineView.expandItem(row)
        return true
    }

    @discardableResult
    func collapseRow(_ row: TreeRow) -> Bool {
        guard outlineView.isItemExpanded(row) else {
            return false
        }

        outlineView.collapseItem(row)
        return true
    }

    func expandAllRows() {
        update()
        outlineView.expandItem(nil, expandChildren: true)
    }

    func collapseAllRows() {
        outlineView.collapseItem(nil, collapseChildren: true)
    }

    func expandRootRows() {
        update()

        for row in root.children {
            outlineView.expandItem(row)
        }
    }

    func isRowExpanded(_ row: TreeRow) -> Bool {
        outlineView.isItemExpanded(row)
    }

    func setShowExpanders(_ show: Bool) {
        outlineView.indentationPerLevel = show ? 14 : 0
        outlineView.showsExpanders = show
    }

    func grabFocus() {
        outlineView.window?.makeFirstResponder(outlineView)
    }

    // MARK: Labels

    static func iconLabel(columnID: String, iconName: String, isShortCountryLabel: Bool = false) -> String {
        if columnID == "country" {
            let countryCode = String(iconName.suffix(2)).uppercased()

            if isShortCountryLabel {
                return countryCode
            }

            let countryName = Countries.names[countryCode] ?? String(localized: "Unknown")
            return "\(countryName) (\(countryCode))"
        }

        if columnID == "status" {
            return Theme.userStatusIconLabels[iconName] ?? iconName
        }

        if columnID == "file_type" {
            return Theme.fileTypeIconLabels[iconName] ?? iconName
        }

        return iconName
    }

    // MARK: Events

    @objc private func onDoubleClick(_ sender: Any?) {
        let rowIndex = outlineView.clickedRow

        guard rowIndex >= 0, let row = outlineView.item(atRow: rowIndex) as? TreeRow else {
            return
        }

        let columnIndex = outlineView.clickedColumn
        let columnID = columnIndex >= 0 ? outlineView.tableColumns[columnIndex].identifier.rawValue : ""

        if let activateRowCallback {
            activateRowCallback(self, row, columnID)
        } else if row.hasChildren {
            if outlineView.isItemExpanded(row) {
                outlineView.collapseItem(row)
            } else {
                outlineView.expandItem(row)
            }
        }
    }

    private func onActivateAccelerator() -> Bool {
        guard let activateRowCallback, let row = focusedRow else {
            return false
        }

        activateRowCallback(self, row, focusedColumn ?? "")
        return true
    }

    private func onDeleteAccelerator() -> Bool {
        deleteAcceleratorCallback?(self)
        return true
    }

    fileprivate func onFocusIn() {
        focusInCallback?(self)
    }

    /// Command+C: copy cell data.
    private func onCopyCellData() -> Bool {
        guard let row = focusedRow, let tableColumn = tableColumns[focusedColumn ?? ""],
              let column = column(for: tableColumn) else {
            return false
        }

        let value = rowValue(row, column.sortColumn ?? column.id).string

        guard !value.isEmpty else {
            return false
        }

        if column.kind == .icon {
            Clipboard.copyText(Self.iconLabel(columnID: column.id, iconName: value, isShortCountryLabel: true))
        } else {
            Clipboard.copyText(value)
        }
        return true
    }

    private func onCollapseRowAccelerator() -> Bool {
        guard let row = focusedRow else {
            return false
        }
        collapseRow(row)
        return true
    }

    private func onExpandRowAccelerator() -> Bool {
        guard let row = focusedRow else {
            return false
        }
        expandRow(row)
        return true
    }

    /// Command+backslash: collapse or expand to show subfolders.
    private func onExpandRowLevelAccelerator() -> Bool {
        guard let row = focusedRow else {
            return false
        }

        collapseRow(row)
        expandRow(row)
        return true
    }

    fileprivate func contextMenu(for event: NSEvent) -> NSMenu? {
        guard let popupMenu else {
            return nil
        }

        let point = outlineView.convert(event.locationInWindow, from: nil)
        let rowIndex = outlineView.row(at: point)

        if rowIndex >= 0 {
            // Make sure we don't attempt to select a single row if the row is already
            // in a selection of multiple rows, otherwise the other rows will be unselected
            if outlineView.numberOfSelectedRows <= 1 || !outlineView.isRowSelected(rowIndex) {
                outlineView.window?.makeFirstResponder(outlineView)
                outlineView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
            }
        } else {
            outlineView.deselectAll(nil)
        }

        guard outlineView.numberOfSelectedRows > 0 else {
            // No rows selected, don't show menu
            return nil
        }

        popupMenu.prepare()
        return popupMenu.menu
    }

    /// Selects the first row matching a search term, like typing in a search entry.
    func selectFirstMatch(_ searchTerm: String) {
        update()

        guard outlineView.numberOfRows > 0 else {
            return
        }

        let index = typeSelectMatch(from: 0, to: -1, searchTerm: searchTerm)

        if index >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            outlineView.scrollRowToVisible(index)
        }
    }

    fileprivate func typeSelectMatch(from startRow: Int, to endRow: Int, searchTerm: String) -> Int {
        guard !searchTerm.isEmpty else {
            return -1
        }

        let searchTerm = searchTerm.lowercased()
        let textColumns = columns.enumerated().filter { $0.element.title != nil && [.text, .number].contains($0.element.kind) }
        let numberOfRows = outlineView.numberOfRows

        guard numberOfRows > 0, startRow >= 0, startRow < numberOfRows else {
            return -1
        }

        var index = startRow

        for _ in 0..<numberOfRows {
            if let row = outlineView.item(atRow: index) as? TreeRow {
                for (columnIndex, _) in textColumns where row.values[columnIndex].string.lowercased().contains(searchTerm) {
                    return index
                }
            }

            // Wrap around to the start, and stop at the end row
            index = (index + 1) % numberOfRows

            if index == endRow {
                break
            }
        }
        return -1
    }
}

// MARK: - Data Source and Delegate

extension TreeView: NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? TreeRow) ?? root).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? TreeRow) ?? root).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        hasTree && ((item as? TreeRow)?.hasChildren ?? false)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? TreeRow, let column = column(for: tableColumn),
              let columnIndex = columnIndices[column.id] else {
            return nil
        }

        let value = row.values[columnIndex]
        let isSensitive = column.sensitiveColumn.map { rowValue(row, $0).bool } ?? true
        var tooltip = column.tooltipCallback?(self, row) ?? value.string

        switch column.kind {
        case .text, .number:
            let cellView = outlineView.makeView(withIdentifier: TextCellView.identifier, owner: nil) as? TextCellView
                ?? TextCellView()
            let isBold = column.textWeightColumn.map { rowValue(row, $0).int >= 600 } ?? false
            let isUnderlined = column.textUnderlineColumn.map { rowValue(row, $0).bool } ?? false

            cellView.configure(text: value.string, alignment: column.kind == .number ? .right : .left,
                               isBold: isBold, isUnderlined: isUnderlined, isSensitive: isSensitive,
                               font: outlineView.font)
            cellView.toolTip = tooltip.isEmpty ? nil : tooltip
            return cellView

        case .progress:
            let cellView = outlineView.makeView(withIdentifier: ProgressCellView.identifier, owner: nil)
                as? ProgressCellView ?? ProgressCellView()
            cellView.value = value.int
            cellView.toolTip = nil
            return cellView

        case .toggle:
            let cellView = outlineView.makeView(withIdentifier: ToggleCellView.identifier, owner: nil)
                as? ToggleCellView ?? ToggleCellView()
            cellView.checkbox.state = value.bool ? .on : .off
            cellView.checkbox.isEnabled = isSensitive
            cellView.onToggle = { [weak self, weak row] in
                guard let self, let row, !row.isRemoved else {
                    return
                }
                column.toggleCallback?(self, row)
            }
            return cellView

        case .icon:
            let cellView = outlineView.makeView(withIdentifier: IconCellView.identifier, owner: nil)
                as? IconCellView ?? IconCellView()
            let iconName = value.string

            cellView.configure(iconName: iconName)

            if !tooltip.isEmpty {
                tooltip = Self.iconLabel(columnID: column.id, iconName: tooltip)
            }
            cellView.toolTip = tooltip.isEmpty ? nil : tooltip
            return cellView
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Selection is restored after reloading, the selected rows didn't change
        guard !isSelectingProgrammatically, let selectRowCallback else {
            return
        }

        let selectedRow = outlineView.selectedRow
        selectRowCallback(self, selectedRow >= 0 ? outlineView.item(atRow: selectedRow) as? TreeRow : nil)
    }

    func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {
        onColumnHeaderClicked(tableColumn)
    }

    func outlineView(_ outlineView: NSOutlineView, nextTypeSelectMatchFromItem startItem: Any,
                     toItem endItem: Any, for searchString: String) -> Any? {
        let startRow = outlineView.row(forItem: startItem)
        let endRow = outlineView.row(forItem: endItem)
        let index = typeSelectMatch(from: startRow, to: endRow, searchTerm: searchString)

        return index >= 0 ? outlineView.item(atRow: index) : nil
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?,
                     item: Any) -> String? {
        nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateColumnHeaderMenu(menu)
    }
}

// MARK: - Outline View

final class TreeOutlineView: NSOutlineView {

    fileprivate weak var treeView: TreeView?
    fileprivate(set) var lastClickedColumn = -1
    var showsExpanders = true

    override func keyDown(with event: NSEvent) {
        if let treeView, Accelerator.handle(event, accelerators: treeView.accelerators) {
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastClickedColumn = column(at: point)
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        treeView?.contextMenu(for: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()

        if result {
            treeView?.onFocusIn()
        }
        return result
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        showsExpanders ? super.frameOfOutlineCell(atRow: row) : .zero
    }
}

// MARK: - Cell Views

private final class TextCellView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("TextCell")

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, alignment: NSTextAlignment, isBold: Bool, isUnderlined: Bool, isSensitive: Bool,
                   font: NSFont?) {
        let baseFont = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let displayFont = isBold ? NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask) : baseFont

        label.alignment = alignment
        label.textColor = isSensitive ? .labelColor : .disabledControlTextColor

        if isUnderlined {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: displayFont,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: label.textColor ?? .labelColor
            ])
        } else {
            label.font = displayFont
            label.stringValue = text
        }
    }
}

private final class ProgressCellView: NSView {

    static let identifier = NSUserInterfaceItemIdentifier("ProgressCell")

    var value = 0 {
        didSet {
            if value != oldValue {
                needsDisplay = true
            }
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let barRect = bounds.insetBy(dx: 2, dy: 3)
        let path = NSBezierPath(roundedRect: barRect, xRadius: 3, yRadius: 3)

        NSColor.quaternaryLabelColor.setFill()
        path.fill()

        let fraction = CGFloat(min(max(value, 0), 100)) / 100
        var fillRect = barRect
        fillRect.size.width *= fraction

        if fraction > 0 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor.controlAccentColor.withAlphaComponent(0.75).setFill()
            fillRect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let text = "\(value)%" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = text.size(withAttributes: attributes)

        text.draw(at: NSPoint(x: barRect.midX - textSize.width / 2, y: barRect.midY - textSize.height / 2),
                  withAttributes: attributes)
    }
}

private final class ToggleCellView: NSView {

    static let identifier = NSUserInterfaceItemIdentifier("ToggleCell")

    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var onToggle: (@MainActor () -> Void)?

    init() {
        super.init(frame: .zero)

        identifier = Self.identifier
        checkbox.target = self
        checkbox.action = #selector(toggled(_:))
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)

        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggled(_ sender: NSButton) {
        onToggle?()
    }
}

private final class IconCellView: NSView {

    static let identifier = NSUserInterfaceItemIdentifier("IconCell")

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        identifier = Self.identifier

        for view in [imageView, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)

            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .secondaryLabelColor
        label.alignment = .center
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func configure(iconName: String) {
        if let text = Theme.text(forIconName: iconName) {
            imageView.image = nil
            label.stringValue = text
            return
        }

        label.stringValue = ""
        imageView.image = iconName.isEmpty ? nil : Theme.image(forIconName: iconName)
    }
}
