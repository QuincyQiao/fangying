import AppKit

enum RemoteViewMode: Int { case columns, list, grid }
enum RemoteSort: Int { case name, modified, size }

/// 远程电脑的片库，铺满窗口。「全部视频」最新的在前；「文件夹」和访达一样可以切分栏、列表、图标，左边常用位置，下面路径栏。
/// 点一下就放，放的时候也能再叫出来换片。
final class RemoteBrowserView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSSearchFieldDelegate {
    enum Tab: Int { case all, folders }

    unowned let controller: PlayerWindowController
    private let background = HomeView.backdrop()
    private var upButton: IconButton!
    private var closeButton: IconButton!
    private var optionsButton: IconButton!
    private var retryButton: TextButton!
    private let titleLabel = Style.label(size: 17, weight: .semibold)
    private let tabs: NSSegmentedControl
    private let viewSwitch: NSSegmentedControl
    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let collection = NSCollectionView()
    private let flow = NSCollectionViewFlowLayout()
    private let columns = RemoteColumnsView()
    private let sidebar = RemoteSidebarView()
    private let pathBar = RemotePathBar()
    private let status = Style.label(size: 14, color: Style.secondary)
    private let spinner = NSProgressIndicator()

    private var host = ""
    private var tab: Tab
    private var query = ""
    private var loading = false
    private var failed = false
    private var request = 0
    private var folderRequest = 0
    private var videos: [RemoteEntry]?
    private var videoCounts: [String: Int] = [:]
    private var home: URL?
    /// 第一个是分栏最左边的位置，最后一个是当前文件夹
    private var path: [URL] = []
    private var selectedFile: RemoteEntry?
    private var listings: [String: [RemoteEntry]] = [:]
    private var finderPlaces: [URL] = []
    private var shownFolders: [RemoteEntry] = []
    private var shownFiles: [RemoteEntry] = []
    private var cardSize = NSSize(width: 240, height: 185)
    private var folderSize = NSSize(width: 240, height: 52)
    private var rowSize = NSSize(width: 600, height: 56)
    private var measured = NSSize.zero
    private var measuredMode = RemoteViewMode.grid

    private var videoMode = RemoteViewMode(rawValue: RemoteBrowserView.stored("远程视频视图", RemoteViewMode.grid.rawValue)) ?? .grid
    private var folderMode = RemoteViewMode(rawValue: RemoteBrowserView.stored("远程文件夹视图", RemoteViewMode.columns.rawValue)) ?? .columns
    private var videoSort = RemoteSort(rawValue: RemoteBrowserView.stored("远程视频排序", RemoteSort.modified.rawValue)) ?? .modified
    private var folderSort = RemoteSort(rawValue: RemoteBrowserView.stored("远程文件夹排序", RemoteSort.name.rawValue)) ?? .name
    private var onlyVideos = UserDefaults.standard.object(forKey: "只显示有视频的文件夹") as? Bool ?? true

    private static let side: CGFloat = 40, gap: CGFloat = 20, sidebarWidth: CGFloat = 200, pathBarHeight: CGFloat = 32

    private static func stored(_ key: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }

    init(controller: PlayerWindowController) {
        self.controller = controller
        tabs = NSSegmentedControl(labels: ["全部视频", "文件夹"], trackingMode: .selectOne, target: nil, action: nil)
        viewSwitch = NSSegmentedControl(labels: ["", "", ""], trackingMode: .selectOne, target: nil, action: nil)
        tab = Tab(rawValue: UserDefaults.standard.integer(forKey: "远程片库页")) ?? .all
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(background)

        upButton = IconButton("chevron.left", size: 15, target: self, action: #selector(goUp))
        closeButton = IconButton("xmark", size: 13, target: self, action: #selector(close))
        optionsButton = IconButton("arrow.up.arrow.down", size: 13, target: self, action: #selector(showOptions(_:)))
        retryButton = TextButton("重试", size: 13, target: self, action: #selector(reload))
        retryButton.restColor = NSColor(white: 1, alpha: 0.10)
        upButton.toolTip = "上一层"
        closeButton.toolTip = "关闭"
        optionsButton.toolTip = "排序和筛选"

        tabs.segmentStyle = .automatic
        tabs.font = .systemFont(ofSize: 13, weight: .medium)
        tabs.refusesFirstResponder = true
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = tab.rawValue

        viewSwitch.segmentStyle = .automatic
        viewSwitch.refusesFirstResponder = true
        viewSwitch.target = self
        viewSwitch.action = #selector(viewChanged)
        for (i, item) in [("rectangle.split.3x1", "分栏"), ("list.bullet", "列表"), ("square.grid.2x2", "图标")].enumerated() {
            viewSwitch.setImage(Style.symbol(item.0, size: 13), forSegment: i)
            viewSwitch.setLabel("", forSegment: i)
            viewSwitch.setToolTip(item.1, forSegment: i)
        }

        searchField.placeholderString = "搜索"
        searchField.font = .systemFont(ofSize: 13)
        searchField.delegate = self
        searchField.focusRingType = .none

        flow.minimumInteritemSpacing = RemoteBrowserView.gap
        collection.collectionViewLayout = flow
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [.clear]
        collection.register(RemoteCardItem.self, forItemWithIdentifier: RemoteCardItem.id)
        collection.register(RemoteFolderItem.self, forItemWithIdentifier: RemoteFolderItem.id)
        collection.register(RemoteRowItem.self, forItemWithIdentifier: RemoteRowItem.id)
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay

        columns.load = { [weak self] url, done in self?.listing(url, completion: done) }
        columns.present = { [weak self] entries in self?.present(entries) ?? [] }
        columns.count = { [weak self] url in self?.videoCounts[url.path] }
        columns.onFolder = { [weak self] i, url in self?.enter(url, fromColumn: i) }
        columns.onFile = { [weak self] i, entry in self?.select(entry, inColumn: i) }
        columns.onPlay = { [weak self] entry in self?.controller.open([entry.url]) }
        columns.folderMenu = { [weak self] url in self?.pinMenu(for: url) }
        sidebar.onPick = { [weak self] url in self?.go(to: [url]) }
        sidebar.onRemove = { [weak self] url in self?.setPinned(false, url) }
        pathBar.onPick = { [weak self] url in self?.go(to: [url]) }

        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.isDisplayedWhenStopped = false
        status.alignment = .center
        for v in [scroll, columns, sidebar, pathBar, upButton!, titleLabel, tabs, viewSwitch, optionsButton!, searchField,
                  closeButton!, status, retryButton!, spinner] as [NSView] {
            addSubview(v)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: History.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 状态

    private var mode: RemoteViewMode { tab == .folders ? folderMode : videoMode }
    private var sort: RemoteSort { tab == .folders ? folderSort : videoSort }
    /// 分栏只能看文件夹：搜索结果是平铺的一串，这时候先按列表显示
    private var displayMode: RemoteViewMode {
        mode == .columns && !query.isEmpty ? .list : mode
    }

    private var pathKey: String { "远程路径-\(host)" }
    private var pinnedKey: String { "远程常用-\(host)" }
    private var removedKey: String { "远程不显示-\(host)" }
    private var pinned: [String] { UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [] }
    private var removed: [String] { UserDefaults.standard.stringArray(forKey: removedKey) ?? [] }

    // MARK: 数据

    func show(host: String) {
        if host != self.host {
            self.host = host
            videos = nil
            videoCounts = [:]
            home = nil
            path = []
            selectedFile = nil
            finderPlaces = []
        }
        load()
    }

    @objc private func reload() { load() }

    private func load() {
        request += 1
        let token = request
        listings = [:]
        // 片子可能变了，分栏重新读
        columns.clear()
        failed = false
        loading = true
        refresh()
        Remote.shared.videos(host: host) { [weak self] list in
            guard let self, token == self.request else { return }
            if let list {
                self.videos = list
                self.videoCounts = Remote.videoCounts(list)
            }
            if self.tab == .all {
                self.loading = false
                self.failed = list == nil
            }
            self.updateSidebar()
            self.columns.refreshContents()
            self.refresh()
        }
        Remote.shared.home(host: host) { [weak self] url in
            guard let self, token == self.request else { return }
            guard let url else {
                if self.tab == .folders {
                    self.loading = false
                    self.failed = true
                }
                self.refresh()
                return
            }
            self.home = url
            if self.path.isEmpty {
                let saved = UserDefaults.standard.stringArray(forKey: self.pathKey)?.compactMap { URL(string: $0) } ?? []
                self.path = saved.isEmpty ? [url] : saved
            }
            self.updateSidebar()
            self.showFolder()
            Remote.shared.favorites(host: self.host, home: url) { [weak self] places in
                self?.finderPlaces = places
                self?.updateSidebar()
            }
        }
    }

    private func listing(_ url: URL, completion: @escaping ([RemoteEntry]?) -> Void) {
        if let cached = listings[url.path] {
            completion(cached)
            return
        }
        Remote.shared.list(url) { [weak self] entries in
            if let entries { self?.listings[url.path] = entries }
            completion(entries)
        }
    }

    /// 按当前路径刷新正文。分栏自己按层加载，列表和图标只要最后一层。
    private func showFolder() {
        guard tab == .folders, let folder = path.last else { return }
        pathBar.show(host: host, home: home?.path ?? "", folder: folder)
        sidebar.current = path.first
        if displayMode == .columns {
            loading = false
            failed = false
            columns.setPath(path, file: selectedFile)
            refresh()
            return
        }
        folderRequest += 1
        let token = folderRequest
        loading = listings[folder.path] == nil
        failed = false
        listing(folder) { [weak self] entries in
            guard let self, token == self.folderRequest else { return }
            if entries == nil, let home = self.home, folder != home {
                // 上次看的文件夹没了，回到起点
                self.go(to: [home])
                return
            }
            self.loading = false
            self.failed = entries == nil
            self.refresh()
        }
        refresh()
    }

    private func go(to newPath: [URL], file: RemoteEntry? = nil) {
        path = newPath
        selectedFile = file
        UserDefaults.standard.set(newPath.map(\.absoluteString), forKey: pathKey)
        searchField.stringValue = ""
        query = ""
        showFolder()
    }

    /// 分栏里点了第 i 栏的文件夹
    private func enter(_ url: URL, fromColumn i: Int) { go(to: Array(path.prefix(i + 1)) + [url]) }
    /// 分栏里点了第 i 栏的视频：不放，右边出预览
    private func select(_ entry: RemoteEntry, inColumn i: Int) { go(to: Array(path.prefix(i + 1)), file: entry) }

    /// 文件夹和文件怎么筛、怎么排，分栏、列表、图标都走这里。
    private func present(_ entries: [RemoteEntry]) -> [RemoteEntry] {
        let counts = videoCounts
        let hideEmpty = onlyVideos && !counts.isEmpty
        let sort = folderSort
        return entries
            .filter { $0.isDirectory ? (!hideEmpty || counts[$0.url.path] != nil) : Media.isPlayable($0.url) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                switch sort {
                case .modified where a.modified != b.modified: return a.modified > b.modified
                case .size where a.isDirectory && counts[a.url.path] != counts[b.url.path]:
                    return (counts[a.url.path] ?? 0) > (counts[b.url.path] ?? 0)
                case .size where !a.isDirectory && a.size != b.size: return a.size > b.size
                default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
    }

    private func sortedVideos(_ list: [RemoteEntry]) -> [RemoteEntry] {
        switch sort {
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .modified: return list.sorted { $0.modified > $1.modified }
        case .size: return list.sorted { $0.size > $1.size }
        }
    }

    /// 按当前页和搜索词算出要显示的内容，刷新界面。
    private func refresh() {
        let matches = { [query] (e: RemoteEntry) in e.name.localizedStandardContains(query) }
        let folder = path.last
        switch tab {
        case .all:
            shownFolders = []
            shownFiles = sortedVideos(query.isEmpty ? (videos ?? []) : (videos ?? []).filter(matches))
        case .folders:
            if query.isEmpty {
                let entries = folder.flatMap { listings[$0.path] }.map(present) ?? []
                shownFolders = entries.filter(\.isDirectory)
                shownFiles = entries.filter { !$0.isDirectory }
            } else {
                // 搜索范围是当前文件夹和它下面的所有文件夹
                let prefix = (folder?.path ?? "") + "/"
                shownFolders = []
                shownFiles = sortedVideos((videos ?? []).filter { $0.url.path.hasPrefix(prefix) && matches($0) })
            }
        }
        let inColumns = tab == .folders && displayMode == .columns
        columns.isHidden = !inColumns
        scroll.isHidden = inColumns
        let inFolders = tab == .folders
        sidebar.isHidden = !inFolders || bounds.width < 640
        pathBar.isHidden = !inFolders
        viewSwitch.selectedSegment = mode.rawValue
        // 全部视频是平铺的，没有分栏可切
        viewSwitch.setEnabled(inFolders, forSegment: RemoteViewMode.columns.rawValue)
        if !inColumns { collection.reloadData() }
        let nothing = !inColumns && shownFolders.isEmpty && shownFiles.isEmpty
        if loading && nothing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        status.isHidden = !(failed || (nothing && !loading))
        status.stringValue = failed ? "连不上 \(host)" : query.isEmpty ? "这里没有视频" : "没有找到"
        retryButton.isHidden = !failed
        let inSubfolder = inFolders && displayMode != .columns && folder != nil && folder != home
        upButton.isHidden = !inSubfolder
        titleLabel.stringValue = host
        needsLayout = true
    }

    private func updateSidebar() {
        guard let home else { return }
        let hidden = removed
        let showEmpty = !onlyVideos || videoCounts.isEmpty
        var places = [RemoteSidebarView.Place(url: home, title: "个人", symbol: "house", count: videoCounts[home.path], removable: false)]
        func add(_ url: URL) {
            guard url != home, !places.contains(where: { $0.url == url }) else { return }
            places.append(.init(url: url, title: url.lastPathComponent, symbol: "folder", count: videoCounts[url.path], removable: true))
        }
        pinned.compactMap { URL(string: $0) }.forEach(add)
        // Finder 侧边栏里的 Applications、Downloads 这些没有片子的不用占地方
        finderPlaces.filter { !hidden.contains($0.absoluteString) && (showEmpty || videoCounts[$0.path] != nil) }.forEach(add)
        sidebar.places = places
    }

    /// 文件夹右键菜单：加进常用或拿掉。
    private func pinMenu(for url: URL) -> NSMenu {
        let m = NSMenu()
        let isPlace = sidebar.places.contains { $0.url == url }
        let item = m.addItem(withTitle: isPlace ? "从常用中移除" : "添加到常用", action: #selector(togglePin(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.isEnabled = url != home
        return m
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        setPinned(!sidebar.places.contains { $0.url == url }, url)
    }

    private func setPinned(_ on: Bool, _ url: URL) {
        let key = url.absoluteString
        var list = pinned.filter { $0 != key }
        var hidden = removed.filter { $0 != key }
        if on { list.append(key) } else { hidden.append(key) }
        UserDefaults.standard.set(list, forKey: pinnedKey)
        UserDefaults.standard.set(hidden, forKey: removedKey)
        updateSidebar()
    }

    // MARK: 操作

    @objc private func tabChanged() {
        tab = Tab(rawValue: tabs.selectedSegment) ?? .all
        UserDefaults.standard.set(tab.rawValue, forKey: "远程片库页")
        searchField.stringValue = ""
        query = ""
        showFolder()
        refresh()
    }

    @objc private func viewChanged() {
        guard let m = RemoteViewMode(rawValue: viewSwitch.selectedSegment) else { return }
        if tab == .folders {
            folderMode = m
            UserDefaults.standard.set(m.rawValue, forKey: "远程文件夹视图")
            showFolder()
        } else {
            videoMode = m
            UserDefaults.standard.set(m.rawValue, forKey: "远程视频视图")
        }
        refresh()
    }

    @objc private func showOptions(_ sender: NSView) {
        let m = NSMenu()
        m.appearance = NSAppearance(named: .darkAqua)
        for (title, value) in [("按名称", RemoteSort.name), ("按修改时间", .modified), ("按大小", .size)] {
            let item = m.addItem(withTitle: title, action: #selector(sortChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value.rawValue
            item.state = sort == value ? .on : .off
        }
        if tab == .folders {
            m.addItem(.separator())
            let item = m.addItem(withTitle: "只显示有视频的文件夹", action: #selector(toggleOnlyVideos), keyEquivalent: "")
            item.target = self
            item.state = onlyVideos ? .on : .off
            if let folder = path.last, folder != home {
                m.addItem(.separator())
                let isPlace = sidebar.places.contains { $0.url == folder }
                let pin = m.addItem(withTitle: isPlace ? "把「\(folder.lastPathComponent)」从常用中移除" : "把「\(folder.lastPathComponent)」添加到常用",
                                    action: #selector(togglePin(_:)), keyEquivalent: "")
                pin.target = self
                pin.representedObject = folder
            }
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
    }

    @objc private func sortChosen(_ sender: NSMenuItem) {
        guard let s = RemoteSort(rawValue: sender.tag) else { return }
        if tab == .folders {
            folderSort = s
            UserDefaults.standard.set(s.rawValue, forKey: "远程文件夹排序")
        } else {
            videoSort = s
            UserDefaults.standard.set(s.rawValue, forKey: "远程视频排序")
        }
        columns.refreshContents()
        refresh()
    }

    @objc private func toggleOnlyVideos() {
        onlyVideos.toggle()
        UserDefaults.standard.set(onlyVideos, forKey: "只显示有视频的文件夹")
        updateSidebar()
        columns.refreshContents()
        refresh()
    }

    @objc private func goUp() {
        guard let folder = path.last else { return }
        go(to: path.count > 1 ? Array(path.dropLast()) : [folder.deletingLastPathComponent()])
    }

    @objc private func close() { controller.hideRemoteBrowser() }

    @objc private func historyChanged() {
        if superview != nil, !scroll.isHidden { collection.reloadData() }
    }

    func controlTextDidChange(_ obj: Notification) {
        query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if tab == .folders { showFolder() }
        refresh()
    }

    /// 搜索框里按 Esc：有字先清字，没字关掉片库
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), searchField.stringValue.isEmpty else { return false }
        close()
        return true
    }

    // MARK: 布局

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        CATransaction.commit()
        let w = bounds.width, h = bounds.height
        let barY = h - 44
        closeButton.frame = NSRect(x: w - 48, y: barY, width: 30, height: 30)
        searchField.isHidden = w < 700
        let searchW: CGFloat = searchField.isHidden ? 0 : min(220, max(110, w * 0.16))
        searchField.frame = NSRect(x: w - 48 - 10 - searchW, y: barY + 2, width: searchW, height: 26)
        optionsButton.frame = NSRect(x: searchField.frame.minX - 8 - 30, y: barY, width: 30, height: 30)
        viewSwitch.sizeToFit()
        let switchW = viewSwitch.frame.width
        viewSwitch.frame = NSRect(x: optionsButton.frame.minX - 8 - switchW, y: barY + 1, width: switchW, height: 28)
        tabs.sizeToFit()
        let tabsW = tabs.frame.width
        tabs.frame = NSRect(x: viewSwitch.frame.minX - 12 - tabsW, y: barY + 1, width: tabsW, height: 28)
        var x: CGFloat = 84
        if !upButton.isHidden {
            upButton.frame = NSRect(x: x, y: barY, width: 30, height: 30)
            x += 36
        }
        titleLabel.frame = NSRect(x: x, y: barY + 4, width: max(0, tabs.frame.minX - x - 16), height: 22)

        let inFolders = tab == .folders
        sidebar.isHidden = !inFolders || w < 640
        let top = h - 58
        let bottom = inFolders ? RemoteBrowserView.pathBarHeight : 0
        let left = sidebar.isHidden ? 0 : RemoteBrowserView.sidebarWidth
        sidebar.frame = NSRect(x: 0, y: bottom, width: RemoteBrowserView.sidebarWidth, height: top - bottom)
        let body = NSRect(x: left, y: bottom, width: w - left, height: top - bottom)
        scroll.frame = body
        columns.frame = body
        pathBar.frame = NSRect(x: 0, y: 0, width: w, height: RemoteBrowserView.pathBarHeight)
        status.frame = NSRect(x: left + 40, y: h / 2 - 2, width: max(0, w - left - 80), height: 20)
        retryButton.frame = NSRect(x: left + (w - left - 76) / 2, y: h / 2 - 44, width: 76, height: 30)
        spinner.frame = NSRect(x: left + (w - left) / 2 - 18, y: h / 2 - 18, width: 36, height: 36)

        if body.size != measured || displayMode != measuredMode {
            measured = body.size
            measuredMode = displayMode
            let side = RemoteBrowserView.side, gap = RemoteBrowserView.gap
            let usable = max(200, body.width - 2 * side)
            let cols = max(2, Int((usable + gap) / (230 + gap)))
            let itemW = floor((usable - CGFloat(cols - 1) * gap) / CGFloat(cols))
            cardSize = NSSize(width: itemW, height: (itemW * 9 / 16).rounded() + 50)
            folderSize = NSSize(width: itemW, height: 52)
            rowSize = NSSize(width: usable, height: 56)
            flow.invalidateLayout()
        }
    }

    // MARK: 列表和图标

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 2 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        section == 0 ? shownFolders.count : shownFiles.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let entry = indexPath.section == 0 ? shownFolders[indexPath.item] : shownFiles[indexPath.item]
        let open: () -> Void = { [weak self] in
            guard let self else { return }
            if entry.isDirectory { self.go(to: self.path + [entry.url]) } else { self.controller.open([entry.url]) }
        }
        if displayMode == .list {
            let item = collectionView.makeItem(withIdentifier: RemoteRowItem.id, for: indexPath) as! RemoteRowItem
            item.configure(entry, count: videoCounts[entry.url.path], onOpen: open,
                           menu: entry.isDirectory ? { [weak self] in self?.pinMenu(for: entry.url) } : nil)
            return item
        }
        if entry.isDirectory {
            let item = collectionView.makeItem(withIdentifier: RemoteFolderItem.id, for: indexPath) as! RemoteFolderItem
            item.configure(entry, count: videoCounts[entry.url.path], onOpen: open) { [weak self] in self?.pinMenu(for: entry.url) }
            return item
        }
        let item = collectionView.makeItem(withIdentifier: RemoteCardItem.id, for: indexPath) as! RemoteCardItem
        item.configure(entry, onOpen: open)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        if displayMode == .list { return rowSize }
        return indexPath.section == 0 ? folderSize : cardSize
    }

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        displayMode == .list ? 2 : RemoteBrowserView.gap
    }

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, insetForSectionAt section: Int) -> NSEdgeInsets {
        let empty = section == 0 ? shownFolders.isEmpty : shownFiles.isEmpty
        if empty { return NSEdgeInsetsZero }
        let spacing: CGFloat = displayMode == .list ? 2 : 20
        return NSEdgeInsets(top: section == 0 ? 8 : 2, left: RemoteBrowserView.side, bottom: spacing, right: RemoteBrowserView.side)
    }
}

/// 卡片、列表行、预览栏共用的说明文字。
enum RemoteInfo {
    static func size(_ entry: RemoteEntry) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
    }

    static func detail(_ entry: RemoteEntry, duration: Double?) -> String {
        let text = watched(entry, duration: duration)
        return History.shared.record(for: Media.key(entry.url)).map { $0.finished || $0.resumePosition != nil } == true
            ? text : "\(text) · \(relativeDay(entry.modified))"
    }

    /// 看到哪了；没看过就是时长，时长还不知道就是大小。
    static func watched(_ entry: RemoteEntry, duration: Double?) -> String {
        let record = History.shared.record(for: Media.key(entry.url))
        let length = (duration ?? 0) > 0 ? formatTime(duration!) : size(entry)
        if let record, record.finished { return "已看完 · \(length)" }
        if let record, let r = record.resumePosition {
            return "看到 \(formatTime(r, likeDuration: record.duration)) / \(formatTime(record.duration))"
        }
        return length
    }

    static func progress(_ entry: RemoteEntry) -> Double? {
        guard let record = History.shared.record(for: Media.key(entry.url)), !record.finished else { return nil }
        return record.progress
    }
}

/// 片库里的一张视频卡片。
final class RemoteCardItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("RemoteCard")
    private let card = RemoteCardView()
    private var current: URL?

    override func loadView() { view = card }

    func configure(_ entry: RemoteEntry, onOpen: @escaping () -> Void) {
        current = entry.url
        card.onClick = onOpen
        card.title.stringValue = Media.title(of: entry.url)
        card.thumb.image = nil
        card.thumb.progress = RemoteInfo.progress(entry)
        let url = entry.url
        card.detail.stringValue = RemoteInfo.detail(entry, duration: Thumbnails.shared.cachedDuration(for: url))
        Thumbnails.shared.poster(for: url) { [weak self] img, duration in
            guard let self, self.current == url else { return }
            self.card.thumb.image = img
            self.card.detail.stringValue = RemoteInfo.detail(entry, duration: duration)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let u = current { Thumbnails.shared.cancelPoster(for: u) }
        current = nil
        card.clearHover()
    }
}

final class RemoteCardView: NSView {
    let thumb = ThumbView()
    let title = Style.label(size: 13, weight: .medium)
    let detail = Style.label(size: 12, color: Style.secondary)
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        thumb.layer?.cornerRadius = 10
        addSubview(thumb)
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError() }

    // 点击卡片自己接，不走集合视图的选中
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let th = (w * 9 / 16).rounded()
        thumb.frame = NSRect(x: 0, y: h - th, width: w, height: th)
        title.frame = NSRect(x: 2, y: h - th - 24, width: w - 4, height: 18)
        detail.frame = NSRect(x: 2, y: h - th - 42, width: w - 4, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        thumb.layer?.borderWidth = 2
        thumb.layer?.borderColor = NSColor(white: 1, alpha: 0.75).cgColor
    }

    override func mouseExited(with event: NSEvent) { clearHover() }
    func clearHover() { thumb.layer?.borderWidth = 0 }
}

/// 图标视图里的一个文件夹：一条，比视频卡片矮。
final class RemoteFolderItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("RemoteFolder")
    private let row = RemoteFolderView()

    override func loadView() { view = row }

    func configure(_ entry: RemoteEntry, count: Int?, onOpen: @escaping () -> Void, menu: @escaping () -> NSMenu?) {
        row.name.stringValue = entry.name
        row.count.stringValue = count.map(String.init) ?? ""
        row.onClick = onOpen
        row.contextMenu = menu
        row.needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        row.clearHover()
    }
}

final class RemoteFolderView: NSView {
    let name = Style.label(size: 13, weight: .medium)
    let count = Style.label(size: 12, color: Style.faint, mono: true)
    var onClick: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    private let icon = NSImageView()
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        icon.image = Style.symbol("folder.fill", size: 17)
        icon.contentTintColor = Style.secondary
        count.alignment = .right
        addSubview(icon)
        addSubview(name)
        addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        icon.frame = NSRect(x: 14, y: (h - 22) / 2, width: 24, height: 22)
        count.frame = NSRect(x: w - 56, y: (h - 16) / 2, width: 44, height: 16)
        name.frame = NSRect(x: 46, y: (h - 18) / 2, width: w - 46 - 60, height: 18)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor }
    override func mouseExited(with event: NSEvent) { clearHover() }
    func clearHover() { layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor }
}

/// 列表视图的一行：小封面、名字，右边时长和日期。
final class RemoteRowItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("RemoteRow")
    private let row = RemoteRowView()
    private var current: URL?

    override func loadView() { view = row }

    func configure(_ entry: RemoteEntry, count: Int?, onOpen: @escaping () -> Void, menu: (() -> NSMenu?)?) {
        current = entry.url
        row.onClick = onOpen
        row.contextMenu = menu
        row.title.stringValue = entry.isDirectory ? entry.name : Media.title(of: entry.url)
        row.thumb.image = nil
        row.thumb.placeholderSymbol = entry.isDirectory ? "folder.fill" : "film"
        row.thumb.layer?.backgroundColor = entry.isDirectory ? nil : NSColor(white: 1, alpha: 0.07).cgColor
        row.thumb.progress = entry.isDirectory ? nil : RemoteInfo.progress(entry)
        if entry.isDirectory {
            row.detail.stringValue = count.map { "\($0) 个视频" } ?? ""
            return
        }
        let url = entry.url
        row.detail.stringValue = RemoteInfo.detail(entry, duration: Thumbnails.shared.cachedDuration(for: url))
        Thumbnails.shared.poster(for: url) { [weak self] img, duration in
            guard let self, self.current == url else { return }
            self.row.thumb.image = img
            self.row.detail.stringValue = RemoteInfo.detail(entry, duration: duration)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let u = current, !Media.kind(of: u).isFolderLike { Thumbnails.shared.cancelPoster(for: u) }
        current = nil
        row.clearHover()
    }
}

private extension Media.Kind {
    var isFolderLike: Bool { self == .folder || self == .other }
}

final class RemoteRowView: NSView {
    let thumb = ThumbView()
    let title = Style.label(size: 13, weight: .medium)
    let detail = Style.label(size: 12, color: Style.secondary)
    var onClick: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        detail.alignment = .right
        addSubview(thumb)
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        thumb.frame = NSRect(x: 8, y: (h - 42) / 2, width: 74, height: 42)
        detail.frame = NSRect(x: w - 232, y: (h - 16) / 2, width: 220, height: 16)
        title.frame = NSRect(x: 96, y: (h - 18) / 2, width: max(0, w - 96 - 244), height: 18)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Style.hover.cgColor }
    override func mouseExited(with event: NSEvent) { clearHover() }
    func clearHover() { layer?.backgroundColor = nil }
}
