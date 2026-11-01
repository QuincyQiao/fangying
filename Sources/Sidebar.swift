import AppKit

/// 右侧可收起的玻璃侧栏：列表（同文件夹的片子）、最近、字幕。
final class SidebarView: NSView {
    enum Tab: Int { case playlist, recent, subtitles }

    unowned let controller: PlayerWindowController
    private let glass = Style.glass(cornerRadius: 22, tint: 0.45)
    private let content = NSView()
    let segmented: NSSegmentedControl
    let playlistPane: MediaListPane
    let recentPane: MediaListPane
    let subtitlePane: SubtitlePane
    private(set) var tab: Tab

    static let width: CGFloat = 320

    init(controller: PlayerWindowController) {
        self.controller = controller
        segmented = NSSegmentedControl(labels: ["列表", "最近", "字幕"], trackingMode: .selectOne, target: nil, action: nil)
        playlistPane = MediaListPane(kind: .playlist)
        recentPane = MediaListPane(kind: .recent)
        subtitlePane = SubtitlePane(controller: controller)
        tab = .playlist
        super.init(frame: .zero)
        wantsLayer = true

        glass.contentView = content
        addSubview(glass)
        segmented.segmentStyle = .automatic
        segmented.controlSize = .large
        segmented.font = .systemFont(ofSize: 13, weight: .medium)
        segmented.refusesFirstResponder = true
        segmented.target = self
        segmented.action = #selector(tabChanged)
        segmented.selectedSegment = tab.rawValue
        content.addSubview(segmented)
        for p in [playlistPane, recentPane, subtitlePane] as [NSView] { content.addSubview(p) }

        playlistPane.onActivate = { [weak controller] i in controller?.player.play(at: i) }
        playlistPane.onReveal = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        recentPane.onActivate = { [weak self] i in
            guard let self, self.recentPane.items.indices.contains(i) else { return }
            let item = self.recentPane.items[i]
            if !item.missing { self.controller.open([item.url]) }
        }
        recentPane.onReveal = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        recentPane.onRemove = { url in History.shared.remove(path: Media.key(url)) }
        recentPane.onClearAll = { History.shared.clear() }
        showTab(tab)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tabChanged() {
        showTab(Tab(rawValue: segmented.selectedSegment) ?? .playlist)
    }

    func showTab(_ t: Tab) {
        tab = t
        segmented.selectedSegment = t.rawValue
        playlistPane.isHidden = t != .playlist
        recentPane.isHidden = t != .recent
        subtitlePane.isHidden = t != .subtitles
        reload()
    }

    func reload() {
        switch tab {
        case .playlist: reloadPlaylist(scrollToCurrent: true)
        case .recent: reloadRecent()
        case .subtitles: subtitlePane.update()
        }
    }

    func reloadPlaylist(scrollToCurrent: Bool = false) {
        guard tab == .playlist else { return }
        let p = controller.player
        let folder = p.current?.deletingLastPathComponent().lastPathComponent ?? ""
        playlistPane.header = p.playlist.isEmpty ? "" : folder
        playlistPane.headerDetail = p.playlist.isEmpty ? "" : "\(p.playlist.count) 个"
        playlistPane.items = p.playlist.enumerated().map { i, url in
            let rec = History.shared.record(for: Media.key(url))
            let dur = Thumbnails.shared.cachedDuration(for: url) ?? rec?.duration ?? 0
            var detail = dur > 0 ? formatTime(dur) : ""
            var progress: Double? = nil
            if i == p.index {
                detail = "正在播放"
            } else if let rec, rec.finished {
                detail = "已看完" + (dur > 0 ? " · " + formatTime(dur) : "")
            } else if let rec, let r = rec.resumePosition, rec.duration > 0 {
                detail = "看到 \(formatTime(r, likeDuration: rec.duration)) / \(formatTime(rec.duration))"
                progress = rec.progress
            }
            return MediaListPane.Item(url: url, title: Media.title(of: url), detail: detail, progress: progress,
                                      isCurrent: i == p.index, missing: false, finished: rec?.finished ?? false,
                                      useSnapshot: false, wantsDuration: dur == 0 && i != p.index)
        }
        playlistPane.reload(scrollTo: scrollToCurrent ? p.index : nil)
    }

    func reloadRecent() {
        guard tab == .recent else { return }
        let currentPath = controller.player.current.map(Media.key)
        recentPane.header = ""
        recentPane.items = History.shared.records.map { r in
            let url = r.url
            let exists = r.isAvailable
            let folder = url.deletingLastPathComponent().lastPathComponent
            var detail = exists ? "\(folder) · \(relativeDay(r.updated))" : "找不到文件 · \(relativeDay(r.updated))"
            if r.path == currentPath { detail = "正在播放" }
            return MediaListPane.Item(url: url, title: Media.title(of: url), detail: detail,
                                      progress: r.finished ? nil : r.progress, isCurrent: r.path == currentPath,
                                      missing: !exists, finished: r.finished, useSnapshot: true, wantsDuration: false)
        }
        recentPane.reload(scrollTo: nil)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let w = bounds.width, h = bounds.height
        let topInset: CGFloat = controller.isFullScreen ? 16 : 40
        segmented.sizeToFit()
        segmented.frame = NSRect(x: 16, y: h - topInset - 30, width: w - 32, height: 30)
        let paneFrame = NSRect(x: 0, y: 0, width: w, height: h - topInset - 30 - 10)
        for p in [playlistPane, recentPane, subtitlePane] as [NSView] { p.frame = paneFrame }
    }
}

// MARK: - 列表

final class MediaListPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Kind { case playlist, recent }
    struct Item {
        let url: URL
        let title: String
        var detail: String
        let progress: Double?
        let isCurrent: Bool
        let missing: Bool
        let finished: Bool
        let useSnapshot: Bool
        let wantsDuration: Bool
    }

    let kind: Kind
    var items: [Item] = []
    var header = "" { didSet { headerLabel.stringValue = header; needsLayout = true } }
    var headerDetail = "" { didSet { headerDetailLabel.stringValue = headerDetail } }
    var onActivate: ((Int) -> Void)?
    var onReveal: ((URL) -> Void)?
    var onRemove: ((URL) -> Void)?
    var onClearAll: (() -> Void)?

    private let headerLabel = Style.label(size: 13, weight: .semibold, color: Style.text)
    private let headerDetailLabel = Style.label(size: 12, weight: .regular, color: Style.secondary)
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let empty = Style.label(size: 13, color: Style.faint)

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        addSubview(headerLabel)
        addSubview(headerDetailLabel)
        headerDetailLabel.alignment = .right

        let col = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 68
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        addSubview(scroll)

        empty.alignment = .center
        empty.stringValue = kind == .playlist ? "还没有打开视频" : "还没有看过的视频"
        addSubview(empty)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        var top = h
        if !header.isEmpty {
            headerLabel.frame = NSRect(x: 18, y: h - 22, width: w - 36 - 60, height: 18)
            headerDetailLabel.frame = NSRect(x: w - 18 - 60, y: h - 22, width: 60, height: 18)
            top = h - 30
        }
        headerLabel.isHidden = header.isEmpty
        headerDetailLabel.isHidden = header.isEmpty
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: top)
        table.tableColumns.first?.width = w
        empty.frame = NSRect(x: 0, y: h / 2 - 10, width: w, height: 20)
    }

    func reload(scrollTo index: Int?) {
        empty.isHidden = !items.isEmpty
        table.reloadData()
        if let i = index, items.indices.contains(i) {
            // 当前这一集放在可见区域里，前面留一两条
            table.scrollRowToVisible(min(items.count - 1, i + 2))
            table.scrollRowToVisible(max(0, i - 1))
        }
    }

    @objc private func clicked() {
        let r = table.clickedRow
        if r >= 0 { onActivate?(r) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = MediaRowView()
        v.isCurrent = items.indices.contains(row) && items[row].isCurrent
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: MediaCell.id, owner: nil) as? MediaCell) ?? MediaCell()
        cell.configure(items[row])
        return cell
    }

    // 右键菜单
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard items.indices.contains(r) else {
            if kind == .recent, !items.isEmpty { menu.addItem(withTitle: "清空最近记录", action: #selector(clearAll), keyEquivalent: "").target = self }
            return
        }
        let reveal = menu.addItem(withTitle: "在访达中显示", action: #selector(reveal(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.tag = r
        reveal.isEnabled = !items[r].missing && items[r].url.isFileURL
        if kind == .recent {
            let remove = menu.addItem(withTitle: "从最近记录中移除", action: #selector(remove(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = r
            menu.addItem(.separator())
            menu.addItem(withTitle: "清空最近记录", action: #selector(clearAll), keyEquivalent: "").target = self
        }
    }

    @objc private func reveal(_ sender: NSMenuItem) { onReveal?(items[sender.tag].url) }
    @objc private func remove(_ sender: NSMenuItem) { onRemove?(items[sender.tag].url) }
    @objc private func clearAll() { onClearAll?() }
}

final class MediaRowView: NSTableRowView {
    var isCurrent = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override func drawBackground(in dirtyRect: NSRect) {
        let color: NSColor? = isCurrent ? Style.current : hovering ? Style.hover : nil
        guard let color else { return }
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 0), xRadius: 11, yRadius: 11).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

final class MediaCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("MediaCell")
    private let thumb = ThumbView()
    private let title = Style.label(size: 13, weight: .medium)
    private let detail = Style.label(size: 12, color: Style.secondary)
    private let playing = NSImageView()
    private var path = ""

    init() {
        super.init(frame: .zero)
        identifier = MediaCell.id
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.cell?.wraps = true
        title.cell?.truncatesLastVisibleLine = true
        playing.image = Style.symbol("speaker.wave.2.fill", size: 11)
        playing.contentTintColor = NSColor.controlAccentColor.blended(withFraction: 0.25, of: .white)
        for v in [thumb, title, detail, playing] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: MediaListPane.Item) {
        path = Media.key(item.url)
        title.stringValue = item.title
        detail.stringValue = item.detail
        thumb.progress = item.progress
        playing.isHidden = !item.isCurrent
        alphaValue = item.missing ? 0.45 : 1
        thumb.image = nil
        if item.useSnapshot, let snap = Thumbnails.shared.snapshot(for: path) {
            thumb.image = snap
        } else if !item.missing {
            let p = path
            Thumbnails.shared.poster(for: item.url) { [weak self] img, duration in
                guard let self, self.path == p else { return }
                self.thumb.image = img
                if item.wantsDuration, let d = duration, d > 0, !item.finished { self.detail.stringValue = formatTime(d) }
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let tw: CGFloat = 96, th: CGFloat = 54
        thumb.frame = NSRect(x: 18, y: (h - th) / 2, width: tw, height: th)
        let x = 18 + tw + 12
        let w = bounds.width - x - 18
        let titleSize = title.sizeThatFits(NSSize(width: w, height: 40))
        let titleH = min(36, ceil(titleSize.height))
        let block = titleH + 4 + 16
        let top = (h + block) / 2
        title.frame = NSRect(x: x, y: top - titleH, width: w, height: titleH)
        let dx: CGFloat = playing.isHidden ? 0 : 16
        playing.frame = NSRect(x: x, y: top - titleH - 4 - 15, width: 13, height: 13)
        detail.frame = NSRect(x: x + dx, y: top - titleH - 4 - 16, width: w - dx, height: 16)
    }
}

// MARK: - 字幕

final class SubtitlePane: NSView {
    unowned let controller: PlayerWindowController
    private let subPopup = NSPopUpButton()
    private let secondaryPopup = NSPopUpButton()
    private let audioPopup = NSPopUpButton()
    private let sizeSlider = NSSlider(value: 1, minValue: 0.5, maxValue: 2, target: nil, action: nil)
    private let sizeValue = Style.label(size: 12, weight: .medium, color: Style.secondary, mono: true)
    private let posSlider = NSSlider(value: 100, minValue: 50, maxValue: 110, target: nil, action: nil)
    private let posValue = Style.label(size: 12, weight: .medium, color: Style.secondary, mono: true)
    private let delayValue = Style.label(size: 13, weight: .semibold, color: Style.text, mono: true)
    private var minus: IconButton!
    private var plus: IconButton!
    private var resetSize: IconButton!
    private var resetPos: IconButton!
    private var resetDelay: IconButton!
    private var loadButton: TextButton!
    private var labels: [NSTextField] = []
    private let sectionLine = NSBox()

    init(controller: PlayerWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        for (popup, sel) in [(subPopup, #selector(subChosen)), (secondaryPopup, #selector(secondaryChosen)), (audioPopup, #selector(audioChosen))] {
            popup.target = self
            popup.action = sel
            popup.refusesFirstResponder = true
            popup.font = .systemFont(ofSize: 13)
            popup.controlSize = .regular
            addSubview(popup)
        }
        for (s, sel) in [(sizeSlider, #selector(sizeChanged)), (posSlider, #selector(posChanged))] {
            s.target = self
            s.action = sel
            s.isContinuous = true
            s.refusesFirstResponder = true
            s.controlSize = .small
            addSubview(s)
        }
        minus = IconButton("minus", size: 13, target: self, action: #selector(delayMinus))
        plus = IconButton("plus", size: 13, target: self, action: #selector(delayPlus))
        resetSize = IconButton("arrow.counterclockwise", size: 12, target: self, action: #selector(resetSizeTapped))
        resetPos = IconButton("arrow.counterclockwise", size: 12, target: self, action: #selector(resetPosTapped))
        resetDelay = IconButton("arrow.counterclockwise", size: 12, target: self, action: #selector(resetDelayTapped))
        for b in [resetSize!, resetPos!, resetDelay!] { b.tint = Style.secondary; b.toolTip = "恢复默认" }
        loadButton = TextButton("加载字幕文件…", size: 13, target: controller, action: #selector(PlayerWindowController.loadSubtitleFile(_:)))
        loadButton.restColor = NSColor(white: 1, alpha: 0.10)
        delayValue.alignment = .center
        sizeValue.alignment = .right
        posValue.alignment = .right
        for v in [minus!, plus!, resetSize!, resetPos!, resetDelay!, loadButton!, sizeValue, posValue, delayValue] as [NSView] { addSubview(v) }
        for t in ["字幕", "第二字幕", "音轨", "字号", "位置", "延迟"] {
            let l = Style.label(t, size: 13, weight: .regular, color: Style.secondary)
            labels.append(l)
            addSubview(l)
        }
        sectionLine.boxType = .separator
        addSubview(sectionLine)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        let lx: CGFloat = 20, cx: CGFloat = 92, cw = w - cx - 18
        var y = bounds.height - 8
        func row(_ i: Int, height: CGFloat = 30, _ place: (NSRect) -> Void) {
            y -= height
            labels[i].frame = NSRect(x: lx, y: y + (height - 17) / 2, width: cx - lx - 6, height: 17)
            place(NSRect(x: cx, y: y, width: cw, height: height))
            y -= 10
        }
        row(0) { subPopup.frame = $0 }
        row(1) { secondaryPopup.frame = $0 }
        row(2) { audioPopup.frame = $0 }
        y -= 6
        sectionLine.frame = NSRect(x: lx, y: y, width: w - lx - 18, height: 1)
        y -= 14
        row(3) { r in
            resetSize.frame = NSRect(x: r.maxX - 26, y: r.midY - 13, width: 26, height: 26)
            sizeValue.frame = NSRect(x: r.maxX - 26 - 48, y: r.midY - 8, width: 44, height: 16)
            sizeSlider.frame = NSRect(x: r.minX, y: r.midY - 10, width: r.width - 26 - 52, height: 20)
        }
        row(4) { r in
            resetPos.frame = NSRect(x: r.maxX - 26, y: r.midY - 13, width: 26, height: 26)
            posValue.frame = NSRect(x: r.maxX - 26 - 48, y: r.midY - 8, width: 44, height: 16)
            posSlider.frame = NSRect(x: r.minX, y: r.midY - 10, width: r.width - 26 - 52, height: 20)
        }
        row(5) { r in
            resetDelay.frame = NSRect(x: r.maxX - 26, y: r.midY - 13, width: 26, height: 26)
            minus.frame = NSRect(x: r.minX, y: r.midY - 14, width: 28, height: 28)
            plus.frame = NSRect(x: r.maxX - 26 - 34, y: r.midY - 14, width: 28, height: 28)
            delayValue.frame = NSRect(x: r.minX + 30, y: r.midY - 9, width: r.width - 26 - 34 - 32, height: 18)
        }
        y -= 8
        loadButton.frame = NSRect(x: lx, y: y - 34, width: w - lx - 18, height: 34)
    }

    func update() {
        guard !isHidden else { return }
        let p = controller.player
        let base = p.current.map(Media.title(of:))
        func fill(_ popup: NSPopUpButton, type: String, selected: (Track) -> Bool, offTitle: String?) {
            popup.removeAllItems()
            let list = p.tracks.filter { $0.type == type }
            if let off = offTitle {
                popup.addItem(withTitle: off)
                popup.lastItem?.tag = -1
            }
            for t in list {
                popup.addItem(withTitle: t.displayName(videoBaseName: base))
                popup.lastItem?.tag = t.id
            }
            if let sel = list.first(where: selected) { popup.selectItem(withTag: sel.id) } else { popup.selectItem(withTag: -1) }
            popup.isEnabled = !list.isEmpty
        }
        let sid = p.mpv.string("sid").flatMap(Int.init)
        let sid2 = p.mpv.string("secondary-sid").flatMap(Int.init)
        fill(subPopup, type: "sub", selected: { $0.id == sid }, offTitle: "关闭")
        fill(secondaryPopup, type: "sub", selected: { $0.id == sid2 }, offTitle: "关闭")
        fill(audioPopup, type: "audio", selected: { $0.selected }, offTitle: p.tracks.contains { $0.type == "audio" } ? nil : "无")
        sizeSlider.doubleValue = p.subScale
        sizeValue.stringValue = "\(Int((p.subScale * 100).rounded()))%"
        posSlider.doubleValue = p.subPos
        posValue.stringValue = p.subPos == 100 ? "默认" : p.subPos < 100 ? "上移 \(Int(100 - p.subPos))" : "下移 \(Int(p.subPos - 100))"
        delayValue.stringValue = String(format: "%+.1f 秒", p.subDelay)
        resetSize.isEnabled = abs(p.subScale - 1) > 0.001
        resetPos.isEnabled = p.subPos != 100
        resetDelay.isEnabled = abs(p.subDelay) > 0.001
    }

    @objc private func subChosen() { controller.player.selectTrack(type: "sub", id: tagOrNil(subPopup)) }
    @objc private func secondaryChosen() { controller.player.selectTrack(type: "secondary", id: tagOrNil(secondaryPopup)) }
    @objc private func audioChosen() { controller.player.selectTrack(type: "audio", id: tagOrNil(audioPopup)) }
    private func tagOrNil(_ p: NSPopUpButton) -> Int? { (p.selectedItem?.tag ?? -1) < 0 ? nil : p.selectedItem?.tag }

    @objc private func sizeChanged() { controller.player.setSubScale(sizeSlider.doubleValue) }
    @objc private func posChanged() { controller.player.setSubPos(posSlider.doubleValue) }
    @objc private func delayMinus() { controller.adjustSubDelay(-0.1) }
    @objc private func delayPlus() { controller.adjustSubDelay(0.1) }
    @objc private func resetSizeTapped() { controller.player.setSubScale(1) }
    @objc private func resetPosTapped() { controller.player.setSubPos(100) }
    @objc private func resetDelayTapped() { controller.player.setSubDelay(0) }
}
