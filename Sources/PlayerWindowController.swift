import AppKit
import UniformTypeIdentifiers

/// 画面所在的视图不接鼠标，事件都交给根视图处理。
final class VideoHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 窗口根视图：摆放各层、转发鼠标键盘、接拖进来的文件。
final class PlayerRootView: NSView {
    weak var controller: PlayerWindowController?
    private var tracking: NSTrackingArea?
    var dropHighlight = false { didSet { layer?.borderWidth = dropHighlight ? 3 : 0 } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    // 从别的窗口点过来时，这一下只算切换窗口；开了「单击画面暂停」也不能动播放状态
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { !Settings.clickToPause }
    override func layout() { super.layout(); controller?.layoutViews() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) { controller?.pointerMoved() }
    override func mouseEntered(with event: NSEvent) { controller?.pointerMoved() }
    override func mouseExited(with event: NSEvent) { controller?.pointerExited() }
    override func mouseDown(with event: NSEvent) { controller?.pointerDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.pointerDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.pointerUp(event) }
    override func scrollWheel(with event: NSEvent) { controller?.scroll(event) }
    override func menu(for event: NSEvent) -> NSMenu? { controller?.contextMenu() }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) != true { super.keyDown(with: event) }
    }

    // 拖进来的视频、文件夹、字幕
    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = urls(sender).contains { [.video, .audio, .folder, .subtitle].contains(Media.kind(of: $0)) }
        dropHighlight = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        let list = urls(sender)
        guard !list.isEmpty else { return false }
        controller?.handleDrop(list)
        return true
    }
}

/// 进度条悬停时上方的小预览：缩略图、章节名和时间。
final class PreviewPopup: NSView {
    private let glass = Style.glass(cornerRadius: 12, tint: 0.55)
    private let content = NSView()
    let imageView = ThumbView()
    let time = Style.label(size: 12, weight: .semibold, color: Style.text, mono: true)
    private let chapterLabel = Style.label(size: 13, weight: .semibold, color: Style.text)
    var chapter = "" { didSet { chapterLabel.stringValue = chapter; needsLayout = true } }
    var showsImage = true { didSet { needsLayout = true } }
    var imageAspect: CGFloat = 16.0 / 9.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.contentView = content
        addSubview(glass)
        content.addSubview(imageView)
        content.addSubview(time)
        content.addSubview(chapterLabel)
        imageView.layer?.cornerRadius = 7
        time.alignment = .center
        chapterLabel.alignment = .center
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var preferredSize: NSSize {
        let chapterH: CGFloat = chapter.isEmpty ? 0 : 20
        var width: CGFloat = 84
        if !chapter.isEmpty { width = max(width, min(260, ceil(chapterLabel.intrinsicContentSize.width) + 24)) }
        guard showsImage else { return NSSize(width: width, height: 30 + chapterH) }
        let s = imageSize
        return NSSize(width: max(width, s.width + 12), height: s.height + 12 + 22 + chapterH)
    }

    private var imageSize: NSSize {
        let maxW: CGFloat = 176, maxH: CGFloat = 110
        let w = min(maxW, maxH * imageAspect)
        return NSSize(width: w.rounded(), height: (w / imageAspect).rounded())
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        imageView.isHidden = !showsImage
        chapterLabel.isHidden = chapter.isEmpty
        time.textColor = chapter.isEmpty ? Style.text : Style.secondary
        time.frame = NSRect(x: 0, y: 7, width: bounds.width, height: 16)
        chapterLabel.frame = NSRect(x: 8, y: 25, width: bounds.width - 16, height: 18)
        if showsImage {
            let s = imageSize
            imageView.frame = NSRect(x: (bounds.width - s.width) / 2, y: bounds.height - 6 - s.height, width: s.width, height: s.height)
        }
    }
}

final class PlayerWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    let player = Player()
    let root = PlayerRootView()
    private let videoHost = VideoHostView()
    private(set) var videoLayer: VideoLayer!
    private(set) var home: HomeView!
    private(set) var controlBar: ControlBar!
    private(set) var sidebar: SidebarView!
    private let osd = OSDView()
    private let topShade = GradientView(top: true)
    private let titleLabel = Style.label(size: 13, weight: .semibold, color: Style.text)
    private let spinner = NSProgressIndicator()
    private let audioIcon = NSImageView()
    private let audioTitle = Style.label(size: 17, weight: .semibold, color: Style.text)
    private let preview = PreviewPopup()

    private(set) var isFullScreen = false
    private(set) var sidebarVisible = UserDefaults.standard.bool(forKey: "显示侧栏")
    private var controlsShown = true
    private var hideTimer: Timer?
    private var firstVideoFitted = false
    private var fittedAspect: CGFloat = 0
    /// 窗口开合动画期间画面宽度钉住不动：视频层不变大小就不用重画，窗口边缘像抽屉一样把侧栏露出来
    private var frozenVideoWidth: CGFloat?
    private var sidebarAnimation = 0
    private lazy var speedPanel = SpeedPanel(controller: self)
    private lazy var speedPopover: NSPopover = {
        let p = NSPopover()
        // 程序不在前台时 transient 会立刻收起，截图检查时改成不自动关
        p.behavior = ProcessInfo.processInfo.environment["FANGYING_DEMO"] != nil ? .applicationDefined : .transient
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentViewController = speedPanel
        return p
    }()
    private lazy var settingsWindow = SettingsWindowController()
    private var mouseDownPoint: NSPoint?
    private var dragging = false
    private var clickPausedAt: Date?
    private var scrollAxis: Int = 0  // 0 未定 1 横 2 竖
    private var scrollSeekTarget: Double?
    private var pendingSubtitles: [URL] = []
    private var lastTimeUpdate = Date.distantPast
    private var loadingSince: Date?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 480, height: 300)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.title = "放映"
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("放映主窗口") { window.center() }
        window.setFrameAutosaveName("放映主窗口")

        root.controller = self
        window.contentView = root
        videoLayer = VideoLayer(mpv: player.mpv)
        videoHost.layer = videoLayer
        videoHost.wantsLayer = true
        root.addSubview(videoHost)

        home = HomeView(controller: self)
        controlBar = ControlBar(controller: self)
        sidebar = SidebarView(controller: self)
        audioIcon.image = Style.symbol("music.note", size: 64, weight: .light)
        audioIcon.contentTintColor = Style.faint
        audioTitle.alignment = .center
        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.isDisplayedWhenStopped = false
        titleLabel.alignment = .center
        for v in [audioIcon, audioTitle, home!, topShade, titleLabel, spinner, controlBar!, sidebar!, preview, osd] as [NSView] {
            root.addSubview(v)
        }
        preview.isHidden = true
        sidebar.isHidden = true

        player.onChange = { [weak self] in self?.playerChanged($0) }
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: History.changed, object: nil)
        refreshState()
        controlBar.updateAll()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 打开

    func open(_ urls: [URL]) {
        let media = urls.filter { Media.isPlayable($0) || Media.kind(of: $0) == .folder }
        guard !media.isEmpty else { return }
        player.open(media)
        window?.makeKeyAndOrderFront(nil)
    }

    func handleDrop(_ urls: [URL]) {
        let subs = urls.filter { Media.kind(of: $0) == .subtitle }
        let media = urls.filter { Media.isPlayable($0) || Media.kind(of: $0) == .folder }
        if !media.isEmpty {
            pendingSubtitles = subs
            open(media)
        } else if player.current != nil {
            for s in subs { player.addSubtitle(s) }
            if let s = subs.first { osd.show("已加载字幕 \(s.lastPathComponent)", symbol: "captions.bubble") ; layoutViews() }
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        var types: [UTType] = [.movie, .audiovisualContent, .audio, .folder]
        for ext in Media.videoExts.union(Media.audioExts) { if let t = UTType(filenameExtension: ext) { types.append(t) } }
        panel.allowedContentTypes = types
        if let cur = player.current { panel.directoryURL = cur.deletingLastPathComponent() }
        panel.beginSheetModal(for: window!) { [weak self] r in
            if r == .OK { self?.open(panel.urls) }
        }
    }

    @objc func loadSubtitleFile(_ sender: Any?) {
        guard player.current != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Media.subtitleExts.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = player.current?.deletingLastPathComponent()
        panel.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let self else { return }
            for u in panel.urls { self.player.addSubtitle(u) }
        }
    }

    // MARK: 播放器变化

    private func playerChanged(_ change: Player.Change) {
        switch change {
        case .position:
            let now = Date()
            if now.timeIntervalSince(lastTimeUpdate) > 0.05 || player.paused {
                lastTimeUpdate = now
                controlBar.updateTime()
            }
        case .pause:
            controlBar.updatePlay()
            if player.paused { showControls() } else { scheduleHide() }
        case .duration:
            controlBar.updateTime()
            controlBar.updateChapters()
            sidebar.reloadPlaylist()
        case .volume:
            controlBar.updateVolume()
        case .speed:
            controlBar.updateSpeed()
            speedPanel.update()
        case .tracks:
            controlBar.updateTracks()
            sidebar.subtitlePane.update()
            if !pendingSubtitles.isEmpty, player.tracks.contains(where: { $0.type == "video" || $0.type == "audio" }) {
                let subs = pendingSubtitles
                pendingSubtitles = []
                for s in subs { player.addSubtitle(s) }
            }
            refreshState()
        case .subtitle:
            sidebar.subtitlePane.update()
        case .video:
            videoChanged()
        case .chapters:
            controlBar.updateChapters()
        case .file:
            window?.title = player.title
            titleLabel.stringValue = player.title
            firstVideoFittedForFile = false
            loadingSince = Date()
            controlBar.updateAll()
            sidebar.reloadPlaylist(scrollToCurrent: true)
            sidebar.reloadRecent()
            refreshState()
            showControls()
            if let u = player.current { NSDocumentController.shared.noteNewRecentDocumentURL(u) }
        case .idle, .buffering:
            refreshState()
            controlBar.updatePlay()
        case .cache:
            break
        case .ended:
            controlBar.updatePlay()
            controlBar.updateTime()
            showControls()
        case .error(let msg):
            osd.show(msg, symbol: "exclamationmark.triangle", duration: 3)
            layoutViews()
            refreshState()
        case .resumed(let t):
            osd.show("从 \(formatTime(t, likeDuration: player.duration)) 接着放", symbol: "clock.arrow.circlepath",
                     duration: 5, buttonTitle: "从头播放", target: self, action: #selector(restartFromBeginning))
            layoutViews()
        }
    }

    private var firstVideoFittedForFile = false

    @objc private func restartFromBeginning() {
        player.seek(to: 0)
        osd.hide()
    }

    @objc private func historyChanged() {
        if sidebarVisible, sidebar.tab == .recent { sidebar.reloadRecent() }
    }

    /// 首页 / 画面 / 纯音频 / 加载中 的切换。
    private func refreshState() {
        let hasFile = player.current != nil
        home.isHidden = hasFile
        videoHost.isHidden = !hasFile
        controlBar.isHidden = !hasFile
        titleLabel.isHidden = !hasFile
        topShade.isHidden = !hasFile
        let audioOnly = hasFile && !player.loading && !player.idle && !player.hasVideo
        audioIcon.isHidden = !audioOnly
        audioTitle.isHidden = !audioOnly
        audioTitle.stringValue = player.title
        let slowLoad = player.loading && (loadingSince.map { Date().timeIntervalSince($0) > 0.6 } ?? false)
        if hasFile && (player.buffering || slowLoad) { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if player.loading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.refreshState() }
        }
        if !hasFile { setControls(visible: true, animated: false) }
        if sidebar.alphaValue == 1 || sidebar.isHidden { sidebar.isHidden = !sidebarShown; sidebar.alphaValue = 1 }
        layoutViews()
    }

    private func videoChanged() {
        refreshState()
        guard let size = player.videoSize, size.width > 0, size.height > 0 else { return }
        let aspect = size.width / size.height
        if !firstVideoFittedForFile {
            firstVideoFittedForFile = true
            if !firstVideoFitted || abs(aspect - fittedAspect) > 0.01 { fitWindow(to: size) }
        }
        updateEDR()
        preview.imageAspect = aspect
    }

    private func updateEDR() {
        let headroom = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        videoLayer.setEDR(player.isHDR && headroom > 1.0)
    }

    // MARK: 窗口大小

    private var sidebarRegion: CGFloat { SidebarView.width + 20 }
    /// 首页不显示侧栏（列表是空的）；偏好照样记着，打开视频后再出来。
    private var sidebarShown: Bool { sidebarVisible && player.current != nil }

    private func fitWindow(to size: CGSize) {
        guard let window, !isFullScreen, let screen = window.screen ?? NSScreen.main else { return }
        let extra = sidebarVisible ? sidebarRegion : 0
        let visible = screen.visibleFrame
        let maxW = visible.width * 0.9 - extra, maxH = visible.height * 0.9
        let aspect = size.width / size.height
        var w: CGFloat, h: CGFloat
        if !firstVideoFitted {
            w = size.width; h = size.height
            if w < 760 { w = 760; h = w / aspect }        // 小片子放大一点
            let s = min(1, maxW / w, maxH / h)
            w *= s; h *= s
        } else {
            w = root.bounds.width - extra
            h = w / aspect
            if h > maxH { h = maxH; w = h * aspect }
            if w > maxW { w = maxW; h = w / aspect }
            if h < 300 { h = 300; w = h * aspect }
        }
        let content = NSRect(x: 0, y: 0, width: (w + extra).rounded(), height: h.rounded())
        var frame = window.frameRect(forContentRect: content)
        let old = window.frame
        frame.origin = NSPoint(x: old.midX - frame.width / 2, y: old.midY - frame.height / 2)
        frame = clamp(frame, to: visible)
        if !sidebarVisible { window.contentAspectRatio = size } else { window.contentResizeIncrements = NSSize(width: 1, height: 1) }
        window.setFrame(frame, display: true, animate: firstVideoFitted && window.isVisible)
        firstVideoFitted = true
        fittedAspect = aspect
    }

    private func clamp(_ f: NSRect, to v: NSRect) -> NSRect {
        var r = f
        if r.width > v.width { r.size.width = v.width }
        if r.height > v.height { r.size.height = v.height }
        r.origin.x = min(max(r.origin.x, v.minX), v.maxX - r.width)
        r.origin.y = min(max(r.origin.y, v.minY), v.maxY - r.height)
        return r
    }

    @objc func windowSize(_ sender: NSMenuItem) {
        guard let window, !isFullScreen, let size = player.videoSize, let screen = window.screen else { return }
        let extra = sidebarVisible ? sidebarRegion : 0
        var w: CGFloat, h: CGFloat
        if sender.tag == 0 {
            let v = screen.visibleFrame
            let s = min((v.width - extra) / size.width, v.height / size.height)
            w = size.width * s; h = size.height * s
        } else {
            let s = CGFloat(sender.tag) / 100
            w = size.width * s; h = size.height * s
        }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w + extra, height: h))
        let old = window.frame
        frame.origin = NSPoint(x: old.midX - frame.width / 2, y: old.midY - frame.height / 2)
        window.setFrame(clamp(frame, to: screen.visibleFrame), display: true, animate: true)
    }

    // MARK: 布局

    func layoutViews() {
        let b = root.bounds
        guard b.width > 0 else { return }
        home.frame = b
        // 窗口模式下视频层只占侧栏左边，玻璃侧栏底下是纯黑，不用跟着每帧视频重新模糊。
        // 全屏时窗口没法加宽，侧栏浮在画面上，画面不缩放
        let reserved = sidebarShown && !isFullScreen
        var videoLayerW = reserved ? max(200, b.width - sidebarRegion) : b.width
        if let f = frozenVideoWidth { videoLayerW = f }
        if videoHost.frame.size != NSSize(width: videoLayerW, height: b.height) {
            videoHost.frame = NSRect(x: 0, y: 0, width: videoLayerW, height: b.height)
            // 视频层是我们自己挂上去的，大小不归 AppKit 管，这里同步
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = videoHost.bounds
            CATransaction.commit()
        }
        let videoW = sidebarShown && isFullScreen ? max(200, b.width - sidebarRegion) : videoLayerW

        let sideX = frozenVideoWidth.map { $0 + 10 } ?? (b.width - SidebarView.width - 10)
        sidebar.frame = NSRect(x: sideX, y: 10, width: SidebarView.width, height: b.height - 20)

        let barW = min(720, videoW - 40)
        controlBar.frame = NSRect(x: (videoW - barW) / 2, y: isFullScreen ? 28 : 18, width: barW, height: ControlBar.height)
        topShade.frame = NSRect(x: 0, y: b.height - 96, width: videoLayerW, height: 96)
        titleLabel.frame = NSRect(x: 90, y: b.height - 30, width: max(0, videoW - 180), height: 18)
        spinner.frame = NSRect(x: videoW / 2 - 18, y: b.height / 2 - 18, width: 36, height: 36)
        audioIcon.frame = NSRect(x: videoW / 2 - 50, y: b.height / 2 - 10, width: 100, height: 90)
        audioTitle.frame = NSRect(x: 40, y: b.height / 2 - 48, width: max(0, videoW - 80), height: 24)

        if !osd.isHidden {
            let s = osd.preferredSize
            osd.frame = NSRect(x: (videoW - s.width) / 2, y: b.height - (isFullScreen ? 40 : 62) - s.height, width: s.width, height: s.height)
        }
    }

    // MARK: 控制条显隐

    func showControls() {
        setControls(visible: true, animated: true)
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: false) { [weak self] _ in self?.hideControlsIfIdle() }
    }

    private func mouseInside(_ v: NSView) -> Bool {
        guard let window, !v.isHidden else { return false }
        let p = v.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return v.bounds.contains(p)
    }

    /// 截图检查界面时用：FANGYING_DEMO=1 控制条不自动藏
    private let demoMode = ProcessInfo.processInfo.environment["FANGYING_DEMO"] != nil

    private func hideControlsIfIdle(force: Bool = false) {
        guard player.current != nil, !demoMode else { return }
        let mouseInWindow = mouseInside(root)
        if !force {
            if controlBar.isInteracting || speedPopover.isShown || mouseInside(controlBar) || (sidebarVisible && mouseInside(sidebar)) { scheduleHide(); return }
            if player.paused && mouseInWindow { return }
        }
        setControls(visible: false, animated: true)
        preview.isHidden = true
        if mouseInWindow, !player.paused { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    private var trafficLights: NSView? { window?.standardWindowButton(.closeButton)?.superview }

    private func setControls(visible: Bool, animated: Bool) {
        guard visible != controlsShown || !animated else { return }
        controlsShown = visible
        let views: [NSView] = [controlBar, topShade, titleLabel] + (isFullScreen ? [] : [trafficLights].compactMap { $0 })
        let alpha: CGFloat = visible ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = visible ? 0.18 : 0.45
                for v in views { v.animator().alphaValue = alpha }
            }
        } else {
            for v in views { v.alphaValue = alpha }
        }
        if player.current == nil { trafficLights?.alphaValue = 1 }
    }

    // MARK: 鼠标

    private var lastMouse = NSPoint.zero

    func pointerMoved() {
        guard let window else { return }
        let p = window.mouseLocationOutsideOfEventStream
        if hypot(p.x - lastMouse.x, p.y - lastMouse.y) < 2 { return }
        lastMouse = p
        if player.current != nil { showControls() }
    }

    func pointerExited() {
        guard player.current != nil, !controlBar.isInteracting else { return }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self, !self.mouseInside(self.root) else { return }
            self.hideControlsIfIdle(force: true)
        }
    }

    func pointerDown(_ event: NSEvent) {
        window?.makeFirstResponder(root)
        if event.clickCount >= 2 {
            // 双击全屏：第一下已经切换了播放/暂停，改回来
            if let t = clickPausedAt, Date().timeIntervalSince(t) < NSEvent.doubleClickInterval { player.togglePause() }
            clickPausedAt = nil
            toggleFullScreen()
            mouseDownPoint = nil
            return
        }
        mouseDownPoint = event.locationInWindow
        dragging = false
    }

    func pointerDragged(_ event: NSEvent) {
        guard let start = mouseDownPoint, !dragging else { return }
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) > 3 {
            dragging = true
            if !isFullScreen { window?.performDrag(with: event) }
        }
    }

    func pointerUp(_ event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard Settings.clickToPause, mouseDownPoint != nil, !dragging, event.clickCount == 1, player.current != nil else { return }
        player.togglePause()
        clickPausedAt = Date()
    }

    func scroll(_ e: NSEvent) {
        guard player.current != nil else { return }
        if e.momentumPhase != [] { return }
        let precise = e.hasPreciseScrollingDeltas
        if e.phase == .began || (!precise && e.phase == []) { scrollAxis = 0 }
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if scrollAxis == 0 {
            if abs(dx) > abs(dy) * 1.2 { scrollAxis = 1 } else if abs(dy) > 0 { scrollAxis = 2 }
        }
        if scrollAxis == 1 {
            let base = scrollSeekTarget ?? player.position
            let target = min(max(0, base - Double(dx) * (precise ? 0.2 : 4)), max(0, player.duration))
            scrollSeekTarget = target
            player.seek(to: target, exact: false)
            if !controlsShown { osd.show("\(formatTime(target, likeDuration: player.duration)) / \(formatTime(player.duration))", symbol: dx < 0 ? "goforward" : "gobackward", duration: 0.9); layoutViews() }
        } else if scrollAxis == 2 {
            let up = Double(dy) * (e.isDirectionInvertedFromDevice ? -1 : 1)
            player.setVolume(player.volume + up * (precise ? 0.35 : 3))
            showVolumeOSD()
        }
        if e.phase == .ended || e.phase == .cancelled || (!precise && e.phase == []) {
            if scrollAxis == 1, let t = scrollSeekTarget, e.phase != [] { player.seek(to: t, exact: true) }
            if e.phase != [] || !precise { scrollSeekTarget = nil }
            if e.phase != [] { scrollAxis = 0 }
        }
    }

    // MARK: 进度条

    func scrub(to fraction: Double, phase: Scrubber.Phase) {
        let d = player.duration
        guard d > 0 else { return }
        let t = fraction * d
        controlBar.scrubberPreviewTime = t
        switch phase {
        case .began, .changed: player.seek(to: t, exact: false)
        case .ended: player.seek(to: t, exact: true)
        }
        controlBar.updateTime()
    }

    func scrubberHover(fraction: Double?, in scrubber: Scrubber) {
        guard let f = fraction, player.duration > 0, let url = player.current else {
            preview.isHidden = true
            return
        }
        let t = f * player.duration
        preview.time.stringValue = formatTime(t, likeDuration: player.duration)
        preview.showsImage = url.isFileURL && player.hasVideo
        preview.chapter = Player.chapterTitle(in: player.chapters, at: t)
        let s = preview.preferredSize
        let px = scrubber.convert(NSPoint(x: scrubber.bounds.width * f, y: 0), to: root).x
        let x = min(max(8, px - s.width / 2), root.bounds.width - s.width - 8)
        preview.frame = NSRect(x: x, y: controlBar.frame.maxY + 10, width: s.width, height: s.height)
        preview.isHidden = false
        if preview.showsImage {
            Thumbnails.shared.preview(for: url, at: t) { [weak self] img, _ in
                guard let self, !self.preview.isHidden, let img else { return }
                self.preview.imageView.image = img
            }
        }
    }

    // MARK: 键盘（带 ⌘ 和方向键的都在菜单里）

    func handleKey(_ e: NSEvent) -> Bool {
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if e.keyCode == 53 {  // Esc
            if isFullScreen { window?.toggleFullScreen(nil) }
            return true
        }
        if mods.isEmpty, chars == "f" { toggleFullScreen(); return true }
        if mods.isEmpty, e.keyCode == 36 || e.keyCode == 76 { toggleFullScreen(); return true }  // 回车
        return false
    }

    // MARK: 全屏

    func toggleFullScreen() { window?.toggleFullScreen(nil) }
    @objc func toggleFullScreenFromBar(_ sender: Any?) { toggleFullScreen() }

    func windowWillEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        controlBar.updateFullscreen(true)
        trafficLights?.alphaValue = 1
        layoutViews()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { layoutViews(); sidebar.needsLayout = true }

    func windowWillExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        controlBar.updateFullscreen(false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        layoutViews()
        sidebar.needsLayout = true
        setControls(visible: controlsShown, animated: false)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateEDR()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 1
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        videoLayer.contentsScale = window?.backingScaleFactor ?? 1
        videoLayer.redraw()
    }

    // MARK: 侧栏

    /// 打开时默认是列表页
    @objc func toggleSidebar(_ sender: Any?) { setSidebar(visible: !sidebarVisible, tab: sidebarVisible ? nil : .playlist) }

    func setSidebar(visible: Bool, tab: SidebarView.Tab? = nil) {
        if let tab { sidebar.showTab(tab) }
        guard visible != sidebarVisible else { return }
        sidebarVisible = visible
        UserDefaults.standard.set(visible, forKey: "显示侧栏")
        guard player.current != nil else { return }
        if visible { sidebar.reload() }
        animateSidebar(visible)
    }

    private func animateSidebar(_ visible: Bool) {
        guard let window else { return }
        sidebarAnimation += 1
        let token = sidebarAnimation
        let finish = { [weak self] in
            guard let self, token == self.sidebarAnimation else { return }
            self.frozenVideoWidth = nil
            self.sidebar.layer?.removeAnimation(forKey: "slide")
            self.sidebar.isHidden = !self.sidebarShown
            if !self.sidebarShown, !self.isFullScreen, let size = self.player.videoSize { window.contentAspectRatio = size }
            self.layoutViews()
            self.stopPerfProbe()
        }
        startPerfProbe()
        sidebar.isHidden = false

        // 窗口模式：开时加宽、关时按画面比例收回。视频层大小不变，只有窗口边缘在动
        var target = window.frame
        if !isFullScreen, let screen = window.screen {
            let v = screen.visibleFrame
            if visible {
                window.contentResizeIncrements = NSSize(width: 1, height: 1)
                target.size.width = min(v.width, target.width + sidebarRegion)
                if target.maxX > v.maxX { target.origin.x = max(v.minX, v.maxX - target.width) }
                frozenVideoWidth = max(200, min(videoHost.frame.width, target.width - sidebarRegion))
            } else if let size = player.videoSize {
                let h = window.contentRect(forFrameRect: target).height
                let fitted = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: (h * size.width / size.height).rounded(), height: h))
                target.size.width = min(target.width, fitted.width)
                frozenVideoWidth = videoHost.frame.width
            }
        }
        layoutViews()
        if abs(target.width - window.frame.width) > 1 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(target, display: true)
            }, completionHandler: finish)
        } else {
            // 全屏或屏幕放不下：侧栏自己滑进滑出，交给 Core Animation，不经过主线程
            CATransaction.begin()
            CATransaction.setCompletionBlock(finish)
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = visible ? sidebarRegion : 0
            slide.toValue = visible ? 0 : sidebarRegion
            slide.duration = 0.24
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            slide.isRemovedOnCompletion = false
            slide.fillMode = .forwards
            sidebar.layer?.add(slide, forKey: "slide")
            CATransaction.commit()
        }
    }

    // MARK: 流畅度探针（FANGYING_PERF=1）

    private let perfEnabled = ProcessInfo.processInfo.environment["FANGYING_PERF"] != nil
    private var perfLink: CADisplayLink?
    private var perfLast: CFTimeInterval = 0
    private var perfGaps: [Double] = []
    private var perfDraws = 0

    private func startPerfProbe() {
        guard perfEnabled, perfLink == nil else { return }
        perfGaps = []
        perfLast = 0
        perfDraws = videoLayer.forcedDraws
        let link = root.displayLink(target: self, selector: #selector(perfTick))
        link.add(to: .main, forMode: .common)
        perfLink = link
    }

    @objc private func perfTick() {
        let now = CACurrentMediaTime()
        if perfLast > 0 { perfGaps.append((now - perfLast) * 1000) }
        perfLast = now
    }

    private func stopPerfProbe() {
        guard let link = perfLink else { return }
        link.invalidate()
        perfLink = nil
        NSLog("侧栏动画：主线程 %d 帧，最长间隔 %.1f 毫秒，超过 25 毫秒 %d 次，画面被迫重画 %d 次",
              perfGaps.count, perfGaps.max() ?? 0, perfGaps.filter { $0 > 25 }.count, videoLayer.forcedDraws - perfDraws)
    }

    @objc func showSidebarTab(_ sender: NSMenuItem) {
        let tab = SidebarView.Tab(rawValue: sender.tag) ?? .playlist
        if sidebarVisible, sidebar.tab == tab { setSidebar(visible: false) } else { setSidebar(visible: true, tab: tab) }
    }

    // MARK: 控制条上的菜单

    @objc func showSpeedPanel(_ sender: Any?) {
        guard player.current != nil else { return }
        if speedPopover.isShown { speedPopover.close(); return }
        setControls(visible: true, animated: false)
        let anchor: NSView = controlBar.speedButton.isHidden ? controlBar : controlBar.speedButton
        speedPanel.update()
        speedPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    @objc func showSubtitleMenu(_ sender: NSView) { popUp(subtitleMenu(compact: true), from: sender) }
    @objc func showAudioMenu(_ sender: NSView) { popUp(trackMenu(type: "audio"), from: sender) }

    private func popUp(_ menu: NSMenu, from view: NSView) {
        menu.appearance = NSAppearance(named: .darkAqua)
        hideTimer?.invalidate()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 6), in: view)
        scheduleHide()
    }

    /// 面板和菜单里留的常用档；别的倍速在面板滑条上自己调
    static let commonSpeeds: [Double] = [0.75, 1, 1.25, 1.5, 2]
    /// 按 [ ] 时走的档位
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    func speedMenu() -> NSMenu {
        let m = NSMenu()
        for s in Self.commonSpeeds {
            let item = m.addItem(withTitle: s == 1 ? "1×（正常）" : ControlBar.speedText(s), action: #selector(setSpeedItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(s * 100)
            item.state = abs(player.speed - s) < 0.001 ? .on : .off
        }
        m.addItem(.separator())
        let custom = Self.commonSpeeds.contains { abs(player.speed - $0) < 0.001 } ? nil : ControlBar.speedText(player.speed)
        let item = m.addItem(withTitle: custom.map { "自定义（\($0)）…" } ?? "自定义…", action: #selector(showSpeedPanel(_:)), keyEquivalent: "")
        item.target = self
        item.state = custom == nil ? .off : .on
        return m
    }

    func trackMenu(type: String) -> NSMenu {
        let m = NSMenu()
        let base = player.current.map(Media.title(of:))
        let list = player.tracks.filter { $0.type == (type == "secondary" ? "sub" : type) }
        let selectedID: Int? = type == "secondary" ? player.mpv.string("secondary-sid").flatMap(Int.init)
            : type == "sub" ? player.mpv.string("sid").flatMap(Int.init) : list.first(where: { $0.selected })?.id
        let action: Selector = type == "audio" ? #selector(audioTrackItem(_:)) : type == "secondary" ? #selector(secondaryTrackItem(_:)) : #selector(subtitleTrackItem(_:))
        if type != "audio" {
            let off = m.addItem(withTitle: type == "secondary" ? "不显示第二字幕" : "关闭字幕", action: action, keyEquivalent: "")
            off.target = self
            off.tag = -1
            off.state = selectedID == nil ? .on : .off
            if !list.isEmpty { m.addItem(.separator()) }
        }
        for t in list {
            let item = m.addItem(withTitle: t.displayName(videoBaseName: base), action: action, keyEquivalent: "")
            item.target = self
            item.tag = t.id
            item.state = t.id == selectedID ? .on : .off
        }
        if type == "audio", list.isEmpty {
            m.addItem(withTitle: "没有音轨", action: nil, keyEquivalent: "").isEnabled = false
        }
        return m
    }

    func subtitleMenu(compact: Bool) -> NSMenu {
        let m = trackMenu(type: "sub")
        m.addItem(.separator())
        let second = m.addItem(withTitle: "第二字幕", action: nil, keyEquivalent: "")
        second.submenu = trackMenu(type: "secondary")
        second.isEnabled = player.tracks.contains { $0.type == "sub" }
        m.addItem(withTitle: "加载字幕文件…", action: #selector(loadSubtitleFile(_:)), keyEquivalent: "").target = self
        if compact {
            let s = m.addItem(withTitle: "字幕大小、位置和延迟…", action: #selector(showSidebarTab(_:)), keyEquivalent: "")
            s.target = self
            s.tag = SidebarView.Tab.subtitles.rawValue
        }
        return m
    }

    func contextMenu() -> NSMenu? {
        guard player.current != nil else { return nil }
        let m = NSMenu()
        m.addItem(withTitle: player.paused ? "播放" : "暂停", action: #selector(togglePlay(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "字幕", action: nil, keyEquivalent: "").submenu = subtitleMenu(compact: true)
        m.addItem(withTitle: "音轨", action: nil, keyEquivalent: "").submenu = trackMenu(type: "audio")
        m.addItem(withTitle: "倍速", action: nil, keyEquivalent: "").submenu = speedMenu()
        m.addItem(.separator())
        m.addItem(withTitle: isFullScreen ? "退出全屏" : "全屏", action: #selector(toggleFullScreenFromBar(_:)), keyEquivalent: "").target = self
        let f = m.addItem(withTitle: "窗口置顶", action: #selector(toggleFloat(_:)), keyEquivalent: "")
        f.target = self
        f.state = window?.level == .floating ? .on : .off
        m.addItem(withTitle: sidebarVisible ? "隐藏侧栏" : "显示侧栏", action: #selector(toggleSidebar(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "在访达中显示", action: #selector(revealCurrent(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "设置…", action: #selector(showSettings(_:)), keyEquivalent: "").target = self
        return m
    }

    // MARK: 菜单动作

    @objc func togglePlay(_ sender: Any?) { player.togglePause(); if player.paused { showControls() } }
    @objc func playNext(_ sender: Any?) { player.next() }
    @objc func playPrevious(_ sender: Any?) { player.previous() }
    @objc func seekForward(_ sender: Any?) { keyboardSeek(Double(Settings.seekStep)) }
    @objc func seekBackward(_ sender: Any?) { keyboardSeek(-Double(Settings.seekStep)) }
    @objc func seekForwardLong(_ sender: Any?) { keyboardSeek(30) }
    @objc func seekBackwardLong(_ sender: Any?) { keyboardSeek(-30) }
    @objc func frameForward(_ sender: Any?) { player.frameStep(forward: true) }
    @objc func frameBackward(_ sender: Any?) { player.frameStep(forward: false) }

    private func keyboardSeek(_ delta: Double) {
        guard player.current != nil else { return }
        player.seek(by: delta)
        if !controlsShown {
            osd.show("\(formatTime(player.position, likeDuration: player.duration)) / \(formatTime(player.duration))",
                     symbol: delta > 0 ? "goforward" : "gobackward", duration: 0.9)
            layoutViews()
        }
    }

    @objc func setSpeedItem(_ sender: NSMenuItem) { player.setSpeed(Double(sender.tag) / 100); showSpeedOSD(Double(sender.tag) / 100) }
    @objc func speedUp(_ sender: Any?) {
        let s = Self.speeds.first { $0 > player.speed + 0.001 } ?? Self.speeds.last!
        player.setSpeed(s); showSpeedOSD(s)
    }
    @objc func speedDown(_ sender: Any?) {
        let s = Self.speeds.last { $0 < player.speed - 0.001 } ?? Self.speeds.first!
        player.setSpeed(s); showSpeedOSD(s)
    }
    @objc func speedReset(_ sender: Any?) { player.setSpeed(1); showSpeedOSD(1) }

    private func showSpeedOSD(_ s: Double) {
        osd.show("倍速 \(ControlBar.speedText(s))", symbol: "gauge.with.dots.needle.67percent")
        layoutViews()
    }

    @objc func volumeUp(_ sender: Any?) { player.setVolume(player.volume + 5); showVolumeOSD() }
    @objc func volumeDown(_ sender: Any?) { player.setVolume(player.volume - 5); showVolumeOSD() }
    @objc func toggleMute(_ sender: Any?) {
        player.toggleMute()
        osd.show(player.muted ? "静音" : "取消静音", symbol: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        layoutViews()
    }

    private func showVolumeOSD() {
        let v = Int(player.volume.rounded())
        osd.show("音量 \(v)%", symbol: v == 0 ? "speaker.slash.fill" : v < 34 ? "speaker.wave.1.fill" : v < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill", duration: 1)
        layoutViews()
    }

    @objc func subtitleTrackItem(_ sender: NSMenuItem) {
        player.selectTrack(type: "sub", id: sender.tag < 0 ? nil : sender.tag)
        osd.show(sender.tag < 0 ? "字幕已关闭" : "字幕：\(sender.title)", symbol: "captions.bubble")
        layoutViews()
    }
    @objc func secondaryTrackItem(_ sender: NSMenuItem) { player.selectTrack(type: "secondary", id: sender.tag < 0 ? nil : sender.tag) }
    @objc func audioTrackItem(_ sender: NSMenuItem) {
        player.selectTrack(type: "audio", id: sender.tag)
        osd.show("音轨：\(sender.title)", symbol: "waveform")
        layoutViews()
    }

    @objc func subBigger(_ sender: Any?) { player.setSubScale(player.subScale + 0.1); subOSD("字幕大小 \(Int((min(2.5, player.subScale + 0.1) * 100).rounded()))%") }
    @objc func subSmaller(_ sender: Any?) { player.setSubScale(player.subScale - 0.1); subOSD("字幕大小 \(Int((max(0.4, player.subScale - 0.1) * 100).rounded()))%") }
    @objc func subUp(_ sender: Any?) { player.setSubPos(player.subPos - 2); subOSD("字幕上移") }
    @objc func subDown(_ sender: Any?) { player.setSubPos(player.subPos + 2); subOSD("字幕下移") }
    @objc func subDelayPlus(_ sender: Any?) { adjustSubDelay(0.1) }
    @objc func subDelayMinus(_ sender: Any?) { adjustSubDelay(-0.1) }
    @objc func subReset(_ sender: Any?) {
        player.setSubScale(1); player.setSubPos(100); player.setSubDelay(0)
        subOSD("字幕已恢复默认")
    }

    func adjustSubDelay(_ d: Double) {
        let v = ((player.subDelay + d) * 10).rounded() / 10
        player.setSubDelay(v)
        subOSD(String(format: "字幕延迟 %+.1f 秒", v))
    }

    private func subOSD(_ s: String) {
        osd.show(s, symbol: "captions.bubble")
        layoutViews()
    }

    @objc func toggleFloat(_ sender: Any?) {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
        osd.show(window.level == .floating ? "窗口置顶" : "取消置顶", symbol: "pin")
        layoutViews()
    }

    @objc func revealCurrent(_ sender: Any?) {
        if let u = player.current { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        open([URL(fileURLWithPath: path)])
    }

    @objc func clearRecent(_ sender: Any?) { History.shared.clear() }

    @objc func showSettings(_ sender: Any?) { settingsWindow.show(over: window) }

    @objc func setAsDefaultPlayer(_ sender: Any?) {
        let failed = DefaultApp.setAsDefault()
        let alert = NSAlert()
        alert.messageText = failed.isEmpty ? "已设为视频的默认播放器" : "有 \(failed.count) 种格式没设上"
        if !failed.isEmpty { alert.informativeText = failed.joined(separator: "、") }
        alert.beginSheetModal(for: window!)
    }

    // MARK: 菜单状态

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.identifier?.rawValue {
        case "recent":
            menu.removeAllItems()
            let recs = History.shared.records.prefix(15)
            for r in recs {
                let item = menu.addItem(withTitle: Media.title(of: r.url), action: #selector(openRecentItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = r.path
                item.isEnabled = FileManager.default.fileExists(atPath: r.path)
            }
            if !recs.isEmpty { menu.addItem(.separator()) }
            let clear = menu.addItem(withTitle: "清空最近记录", action: #selector(clearRecent(_:)), keyEquivalent: "")
            clear.target = self
            clear.isEnabled = !recs.isEmpty
        case "audioTracks": copyItems(from: trackMenu(type: "audio"), to: menu)
        case "subTracks": copyItems(from: trackMenu(type: "sub"), to: menu)
        case "secondaryTracks": copyItems(from: trackMenu(type: "secondary"), to: menu)
        case "speeds":
            let presets = speedMenu()
            // 保留前面的加快/减慢/恢复几项，后面换成档位
            while menu.items.count > 4 { menu.removeItem(at: 4) }
            for item in presets.items { presets.removeItem(item); menu.addItem(item) }
        default: break
        }
    }

    private func copyItems(from src: NSMenu, to dst: NSMenu) {
        dst.removeAllItems()
        for item in src.items { src.removeItem(item); dst.addItem(item) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasFile = player.current != nil
        switch item.action {
        case #selector(togglePlay(_:)):
            item.title = hasFile && !player.paused ? "暂停" : "播放"
            return hasFile
        case #selector(playNext(_:)): return player.hasNext
        case #selector(seekForward(_:)):
            item.title = "快进 \(Settings.seekStep) 秒"
            return hasFile
        case #selector(seekBackward(_:)):
            item.title = "快退 \(Settings.seekStep) 秒"
            return hasFile
        case #selector(playPrevious(_:)), #selector(seekForwardLong(_:)), #selector(seekBackwardLong(_:)), #selector(frameForward(_:)),
             #selector(showSpeedPanel(_:)), #selector(frameBackward(_:)), #selector(speedUp(_:)), #selector(speedDown(_:)), #selector(speedReset(_:)),
             #selector(revealCurrent(_:)), #selector(loadSubtitleFile(_:)), #selector(subBigger(_:)), #selector(subSmaller(_:)),
             #selector(subUp(_:)), #selector(subDown(_:)), #selector(subDelayPlus(_:)), #selector(subDelayMinus(_:)), #selector(subReset(_:)):
            return hasFile
        case #selector(windowSize(_:)): return hasFile && player.videoSize != nil && !isFullScreen
        case #selector(toggleFloat(_:)):
            item.state = window?.level == .floating ? .on : .off
            return true
        case #selector(toggleSidebar(_:)):
            item.title = sidebarVisible ? "隐藏侧栏" : "显示侧栏"
            return hasFile
        case #selector(showSidebarTab(_:)):
            item.state = sidebarShown && sidebar.tab.rawValue == item.tag ? .on : .off
            return hasFile
        case #selector(toggleMute(_:)):
            item.title = player.muted ? "取消静音" : "静音"
            return true
        case #selector(toggleFullScreenFromBar(_:)):
            item.title = isFullScreen ? "退出全屏" : "全屏"
            return true
        default:
            return true
        }
    }

    // MARK: 退出

    func shutdown() {
        if perfEnabled {
            let m = player.mpv
            NSLog("播放统计：掉帧 %@，延迟帧 %@，错时帧 %@，音画差 %@", m.string("frame-drop-count") ?? "?", m.string("vo-delayed-frame-count") ?? "?",
                  m.string("mistimed-frame-count") ?? "?", m.string("avsync") ?? "?")
        }
        player.prepareToQuit()
        videoLayer.shutdown()
        player.mpv.destroy()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
