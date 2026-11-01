import AppKit

/// 分栏视图：和访达一样一层一栏，点文件夹往右开一栏，点视频最右边出预览。
final class RemoteColumnsView: NSView {
    var load: ((URL, @escaping ([RemoteEntry]?) -> Void) -> Void)?
    var present: (([RemoteEntry]) -> [RemoteEntry])?
    var count: ((URL) -> Int?)?
    var onFolder: ((Int, URL) -> Void)?
    var onFile: ((Int, RemoteEntry) -> Void)?
    var onPlay: ((RemoteEntry) -> Void)?
    var folderMenu: ((URL) -> NSMenu?)?

    private let scroll = NSScrollView()
    private let content = NSView()
    private let preview = RemotePreviewView()
    private var columns: [RemoteColumn] = []

    private static let columnWidth: CGFloat = 260, previewWidth: CGFloat = 320

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        addSubview(scroll)
        preview.isHidden = true
        preview.onPlay = { [weak self] entry in self?.onPlay?(entry) }
        content.addSubview(preview)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 换路径：前面相同的栏留着，后面的换掉；选中态跟着路径走。
    func setPath(_ path: [URL], file: RemoteEntry?) {
        let keep = zip(columns, path).prefix { $0.0.folder == $0.1 }.count
        columns[keep...].forEach { $0.removeFromSuperview() }
        columns.removeSubrange(keep...)
        for url in path[keep...] {
            let c = RemoteColumn(folder: url, owner: self)
            columns.append(c)
            content.addSubview(c)
            load?(url) { [weak c] entries in c?.fill(entries ?? []) }
        }
        for (i, c) in columns.enumerated() {
            c.select(i + 1 < path.count ? path[i + 1] : file?.url)
        }
        preview.isHidden = file == nil
        if let file { preview.show(file) }
        layoutColumns()
        // 新开的栏滚到看得见的地方
        let end = NSRect(x: max(0, content.frame.width - 1), y: 0, width: 1, height: 1)
        content.scrollToVisible(end)
    }

    func clear() {
        columns.forEach { $0.removeFromSuperview() }
        columns = []
    }

    /// 筛选、排序变了，或者片库数字回来了。
    func refreshContents() { columns.forEach { $0.refill() } }

    fileprivate func picked(_ column: RemoteColumn, _ entry: RemoteEntry) {
        guard let i = columns.firstIndex(where: { $0 === column }) else { return }
        if entry.isDirectory { onFolder?(i, entry.url) } else { onFile?(i, entry) }
    }

    fileprivate func play(_ entry: RemoteEntry) { onPlay?(entry) }

    fileprivate func focusNeighbour(of column: RemoteColumn, step: Int) {
        guard let i = columns.firstIndex(where: { $0 === column }), columns.indices.contains(i + step) else { return }
        columns[i + step].focus()
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutColumns()
    }

    private func layoutColumns() {
        let h = bounds.height, w = RemoteColumnsView.columnWidth
        var x: CGFloat = 0
        for c in columns {
            c.frame = NSRect(x: x, y: 0, width: w, height: h)
            x += w
        }
        if !preview.isHidden {
            preview.frame = NSRect(x: x, y: 0, width: RemoteColumnsView.previewWidth, height: h)
            x += RemoteColumnsView.previewWidth
        }
        content.frame = NSRect(x: 0, y: 0, width: max(x, bounds.width), height: h)
    }
}

/// 一栏：一个文件夹的内容。
final class RemoteColumn: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let folder: URL
    private weak var owner: RemoteColumnsView?
    private let scroll = NSScrollView()
    private let table = RemoteColumnTable()
    private let line = NSBox()
    private let empty = Style.label("没有视频", size: 13, color: Style.faint)
    private var raw: [RemoteEntry]?
    private var rows: [RemoteEntry] = []
    private var selected: URL?
    private var applying = false

    init(folder: URL, owner: RemoteColumnsView) {
        self.folder = folder
        self.owner = owner
        super.init(frame: .zero)
        let col = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onLeft = { [weak self] in
            guard let self else { return }
            self.owner?.focusNeighbour(of: self, step: -1)
        }
        table.onRight = { [weak self] in
            guard let self else { return }
            self.owner?.focusNeighbour(of: self, step: 1)
        }
        table.onReturn = { [weak self] in self?.doubleClicked() }
        table.rowMenu = { [weak self] r in
            guard let self, self.rows.indices.contains(r), self.rows[r].isDirectory else { return nil }
            return self.owner?.folderMenu?(self.rows[r].url)
        }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        addSubview(scroll)
        line.boxType = .separator
        addSubview(line)
        empty.alignment = .center
        empty.isHidden = true
        addSubview(empty)
    }

    required init?(coder: NSCoder) { fatalError() }

    func fill(_ entries: [RemoteEntry]) {
        raw = entries
        refill()
    }

    func refill() {
        guard let raw else { return }
        rows = owner?.present?(raw) ?? raw
        empty.isHidden = !rows.isEmpty
        table.reloadData()
        applySelection()
    }

    func select(_ url: URL?) {
        selected = url
        applySelection()
    }

    /// 接键盘：选中的那行，没有就第一行
    func focus() {
        window?.makeFirstResponder(table)
        if table.selectedRow < 0, !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func applySelection() {
        applying = true
        defer { applying = false }
        if let selected, let i = rows.firstIndex(where: { $0.url == selected }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            table.scrollRowToVisible(i)
        } else {
            table.deselectAll(nil)
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        scroll.frame = NSRect(x: 0, y: 0, width: w - 1, height: h)
        table.tableColumns.first?.width = w - 1
        line.frame = NSRect(x: w - 1, y: 0, width: 1, height: h)
        empty.frame = NSRect(x: 0, y: h / 2 - 10, width: w, height: 20)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RemoteRowHighlight() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: RemoteColumnCell.id, owner: nil) as? RemoteColumnCell) ?? RemoteColumnCell()
        let e = rows[row]
        cell.configure(title: e.isDirectory ? e.name : Media.title(of: e.url), symbol: e.isDirectory ? "folder.fill" : "film",
                       trailing: e.isDirectory ? owner?.count?(e.url).map(String.init) : nil, chevron: e.isDirectory)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        let r = table.selectedRow
        guard rows.indices.contains(r) else {
            // 点到空白处不算取消选中，路径还在
            applySelection()
            return
        }
        window?.makeFirstResponder(table)
        guard rows[r].url != selected else { return }
        selected = rows[r].url
        owner?.picked(self, rows[r])
    }

    @objc private func doubleClicked() {
        let r = table.selectedRow
        guard rows.indices.contains(r) else { return }
        if rows[r].isDirectory { owner?.focusNeighbour(of: self, step: 1) } else { owner?.play(rows[r]) }
    }
}

final class RemoteColumnTable: NSTableView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onReturn: (() -> Void)?
    var rowMenu: ((Int) -> NSMenu?)?

    // 右键事件是单元格转上来的，表格默认不认 menu(for:) 给的菜单，这里按点到的行直接弹
    override func rightMouseDown(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0, let menu = rowMenu?(r) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onLeft?()
        case 124: onRight?()
        case 36, 76: onReturn?()
        default: super.keyDown(with: event)
        }
    }
}

final class RemoteRowHighlight: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? NSColor.controlAccentColor : NSColor(white: 1, alpha: 0.16)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 7, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

/// 分栏和常用共用的一行：图标、名字，右边数字和箭头。
final class RemoteColumnCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("RemoteColumnCell")
    private let icon = NSImageView()
    private let title = Style.label(size: 13)
    private let trailing = Style.label(size: 12, color: Style.faint, mono: true)
    private let chevron = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = RemoteColumnCell.id
        icon.contentTintColor = Style.secondary
        chevron.image = Style.symbol("chevron.right", size: 10, weight: .semibold)
        chevron.contentTintColor = Style.faint
        trailing.alignment = .right
        for v in [icon, title, trailing, chevron] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, symbol: String, trailing number: String?, chevron showChevron: Bool) {
        title.stringValue = text
        icon.image = Style.symbol(symbol, size: 14)
        trailing.stringValue = number ?? ""
        chevron.isHidden = !showChevron
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        icon.frame = NSRect(x: 16, y: (h - 20) / 2, width: 22, height: 20)
        let right = chevron.isHidden ? w - 14 : w - 28
        chevron.frame = NSRect(x: w - 26, y: (h - 14) / 2, width: 12, height: 14)
        trailing.sizeToFit()
        let numberW = trailing.stringValue.isEmpty ? 0 : ceil(trailing.frame.width) + 6
        trailing.frame = NSRect(x: right - numberW, y: (h - 16) / 2, width: numberW, height: 16)
        title.frame = NSRect(x: 44, y: (h - 18) / 2, width: max(0, right - numberW - 44), height: 18)
    }
}

/// 分栏最右边的预览：封面、时长、大小，点封面或按钮就放。
final class RemotePreviewView: NSView {
    var onPlay: ((RemoteEntry) -> Void)?
    private let thumb = ThumbView()
    private let title = Style.label(size: 15, weight: .semibold)
    private let detail = Style.label(size: 12, color: Style.secondary)
    private let date = Style.label(size: 12, color: Style.faint)
    private var playButton: PillButton!
    private var entry: RemoteEntry?

    override init(frame: NSRect) {
        super.init(frame: frame)
        playButton = PillButton(title: "播放", symbol: "play.fill", target: self, action: #selector(play))
        title.maximumNumberOfLines = 3
        title.lineBreakMode = .byTruncatingTail
        title.cell?.wraps = true
        title.cell?.truncatesLastVisibleLine = true
        thumb.layer?.cornerRadius = 10
        thumb.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(play)))
        for v in [thumb, title, detail, date, playButton!] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ e: RemoteEntry) {
        entry = e
        title.stringValue = Media.title(of: e.url)
        thumb.image = nil
        thumb.progress = RemoteInfo.progress(e)
        date.stringValue = "\(RemoteInfo.size(e)) · \(relativeDay(e.modified))"
        detail.stringValue = RemoteInfo.watched(e, duration: Thumbnails.shared.cachedDuration(for: e.url))
        let resume = History.shared.record(for: Media.key(e.url))?.resumePosition
        playButton.title = resume == nil ? "播放" : "接着放"
        needsLayout = true
        let url = e.url
        Thumbnails.shared.poster(for: url) { [weak self] img, duration in
            guard let self, self.entry?.url == url else { return }
            self.thumb.image = img
            self.detail.stringValue = RemoteInfo.watched(e, duration: duration)
        }
    }

    @objc private func play() {
        if let entry { onPlay?(entry) }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let inset: CGFloat = 24, width = w - 2 * inset
        let thumbH = (width * 9 / 16).rounded()
        var y = h - 24 - thumbH
        thumb.frame = NSRect(x: inset, y: y, width: width, height: thumbH)
        let titleH = min(62, ceil(title.sizeThatFits(NSSize(width: width, height: 70)).height))
        y -= 14 + titleH
        title.frame = NSRect(x: inset, y: y, width: width, height: titleH)
        y -= 8 + 16
        detail.frame = NSRect(x: inset, y: y, width: width, height: 16)
        y -= 4 + 16
        date.frame = NSRect(x: inset, y: y, width: width, height: 16)
        let size = playButton.preferredSize
        y -= 18 + size.height
        playButton.frame = NSRect(x: inset, y: y, width: size.width, height: size.height)
    }
}

/// 文件夹页左边的常用位置。
final class RemoteSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Place {
        let url: URL
        let title: String
        let symbol: String
        let count: Int?
        let removable: Bool
    }

    var places: [Place] = [] { didSet { reload() } }
    var current: URL? { didSet { applyCurrent() } }
    var onPick: ((URL) -> Void)?
    var onRemove: ((URL) -> Void)?

    private let scroll = NSScrollView()
    private let table = RemoteColumnTable()
    private let line = NSBox()
    private var applying = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let col = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.rowMenu = { [weak self] r in
            guard let self, self.places.indices.contains(r), self.places[r].removable else { return nil }
            let menu = NSMenu()
            let item = menu.addItem(withTitle: "从常用中移除", action: #selector(self.removeClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = self.places[r].url
            return menu
        }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        addSubview(scroll)
        line.boxType = .separator
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func reload() {
        table.reloadData()
        applyCurrent()
    }

    private func applyCurrent() {
        applying = true
        defer { applying = false }
        if let current, let i = places.firstIndex(where: { $0.url == current }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        scroll.frame = NSRect(x: 0, y: 0, width: w - 1, height: h)
        table.tableColumns.first?.width = w - 1
        line.frame = NSRect(x: w - 1, y: 0, width: 1, height: h)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { places.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RemoteRowHighlight() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: RemoteColumnCell.id, owner: nil) as? RemoteColumnCell) ?? RemoteColumnCell()
        let p = places[row]
        cell.configure(title: p.title, symbol: p.symbol, trailing: p.count.map(String.init), chevron: false)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applying, places.indices.contains(table.selectedRow) else { return }
        onPick?(places[table.selectedRow].url)
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onRemove?(url) }
    }
}

/// 文件夹页下面的路径栏，每一层都能点。放不下时省掉前面几层。
final class RemotePathBar: NSView {
    var onPick: ((URL) -> Void)?
    private var buttons: [NSView] = []
    private var targets: [URL] = []
    private let line = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.boxType = .separator
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 家目录里的路径从主机名算起，别的从根目录算起。
    static func crumbs(host: String, home: String, folder: URL) -> [(title: String, url: URL)] {
        let path = folder.path
        let inHome = !home.isEmpty && (path == home || path.hasPrefix(home + "/"))
        var current = inHome ? home : ""
        var out = [(title: host, url: Media.remoteURL(host: host, path: inHome ? home : "/"))]
        for part in (inHome ? String(path.dropFirst(home.count)) : path).split(separator: "/") {
            current += "/" + part
            out.append((String(part), Media.remoteURL(host: host, path: current)))
        }
        return out
    }

    func show(host: String, home: String, folder: URL) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        targets = []
        for (i, c) in RemotePathBar.crumbs(host: host, home: home, folder: folder).enumerated() {
            if i > 0 {
                let arrow = NSImageView()
                arrow.image = Style.symbol("chevron.right", size: 9, weight: .semibold)
                arrow.contentTintColor = Style.faint
                buttons.append(arrow)
                addSubview(arrow)
            }
            let b = TextButton(c.title, size: 12, target: self, action: #selector(crumbClicked(_:)))
            b.tag = targets.count
            targets.append(c.url)
            buttons.append(b)
            addSubview(b)
        }
        needsLayout = true
    }

    @objc private func crumbClicked(_ sender: NSButton) {
        if targets.indices.contains(sender.tag) { onPick?(targets[sender.tag]) }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        line.frame = NSRect(x: 0, y: h - 1, width: w, height: 1)
        let widths = buttons.map { ($0 as? TextButton).map { ceil($0.attributedTitle.size().width) + 18 } ?? 12 }
        // 从最后一层往前排，放得下多少算多少
        var total: CGFloat = 0
        var first = buttons.count
        while first > 0, total + widths[first - 1] <= w - 32 {
            first -= 1
            total += widths[first]
        }
        if first < buttons.count, buttons[first] is NSImageView { total -= widths[first]; first += 1 }
        var x: CGFloat = 16
        for (i, b) in buttons.enumerated() {
            b.isHidden = i < first
            guard i >= first else { continue }
            b.frame = NSRect(x: x, y: (h - 1 - 22) / 2, width: widths[i], height: 22)
            x += widths[i]
        }
    }
}
