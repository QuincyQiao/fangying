import AppKit

/// 没在放东西时的首页：一个「打开」和最近看过的封面。
final class HomeView: NSView {
    unowned let controller: PlayerWindowController
    private let background = CAGradientLayer()
    private let openButton: PillButton
    private let recentTitle = Style.label("最近看过", size: 17, weight: .semibold, color: Style.text)
    private var cards: [RecentCard] = []
    private let mark = NSImageView()

    init(controller: PlayerWindowController) {
        self.controller = controller
        openButton = PillButton(title: "打开视频", symbol: "play.rectangle.on.rectangle", target: controller,
                                action: #selector(PlayerWindowController.openDocument(_:)))
        super.init(frame: .zero)
        wantsLayer = true
        background.colors = [NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).cgColor,
                             NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1).cgColor]
        background.type = .radial
        background.startPoint = CGPoint(x: 0.5, y: 0.75)
        background.endPoint = CGPoint(x: 1.25, y: -0.1)
        layer?.addSublayer(background)
        mark.image = Style.symbol("play.circle", size: 54, weight: .ultraLight)
        mark.contentTintColor = NSColor(white: 1, alpha: 0.22)
        addSubview(mark)
        addSubview(openButton)
        addSubview(recentTitle)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: History.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func reload() {
        guard !isHidden || cards.isEmpty else { return }
        cards.forEach { $0.removeFromSuperview() }
        let recs = History.shared.records.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(10)
        cards = recs.map { r in
            let c = RecentCard(record: r)
            c.onOpen = { [weak self] in self?.controller.open([r.url]) }
            c.onRemove = { History.shared.remove(path: r.path) }
            addSubview(c)
            return c
        }
        recentTitle.isHidden = cards.isEmpty
        needsLayout = true
    }

    override var isHidden: Bool { didSet { if !isHidden { reload() } } }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        CATransaction.commit()
        let w = bounds.width, h = bounds.height
        let btn = openButton.preferredSize

        if cards.isEmpty {
            mark.frame = NSRect(x: (w - 70) / 2, y: h / 2 + 20, width: 70, height: 70)
            openButton.frame = NSRect(x: (w - btn.width) / 2, y: h / 2 - 50, width: btn.width, height: btn.height)
            mark.isHidden = false
            return
        }
        mark.isHidden = true
        let gap: CGFloat = 20
        let usable = w - 96
        let maxCols = max(2, min(5, Int((usable + gap) / (220 + gap))))
        let maxRows = h > 640 ? 2 : 1
        let visible = min(cards.count, maxCols * maxRows)
        let cols = min(maxCols, visible)
        let cardW = min(300, floor((usable - CGFloat(maxCols - 1) * gap) / CGFloat(maxCols)))
        let cardH = (cardW * 9 / 16).rounded() + 50
        let rows = Int(ceil(Double(visible) / Double(cols)))
        let gridW = CGFloat(cols) * cardW + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * cardH + CGFloat(rows - 1) * gap
        let left = ((w - gridW) / 2).rounded()
        let total = btn.height + 48 + 34 + gridH
        var y = ((h + total) / 2).rounded()
        y -= btn.height
        openButton.frame = NSRect(x: (w - btn.width) / 2, y: y, width: btn.width, height: btn.height)
        y -= 48
        recentTitle.frame = NSRect(x: left + 2, y: y - 22, width: 200, height: 22)
        y -= 34
        for (i, c) in cards.enumerated() {
            c.isHidden = i >= visible
            guard i < visible else { continue }
            let col = i % cols, row = i / cols
            c.frame = NSRect(x: left + CGFloat(col) * (cardW + gap), y: y - cardH - CGFloat(row) * (cardH + gap), width: cardW, height: cardH)
        }
    }
}

/// 玻璃胶囊按钮。
final class PillButton: NSView {
    private let glass = Style.glass(cornerRadius: 24, tint: 0.18)
    private let content = NSView()
    private let icon = NSImageView()
    private let label: NSTextField
    private weak var target: AnyObject?
    private let action: Selector
    private var hovering = false { didSet { glass.tintColor = NSColor(white: hovering ? 1 : 0, alpha: hovering ? 0.10 : 0.18) } }
    private var tracking: NSTrackingArea?

    init(title: String, symbol: String, target: AnyObject, action: Selector) {
        label = Style.label(title, size: 15, weight: .semibold)
        self.target = target
        self.action = action
        super.init(frame: .zero)
        icon.image = Style.symbol(symbol, size: 16)
        icon.contentTintColor = Style.text
        glass.contentView = content
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        addSubview(glass)
        content.addSubview(icon)
        content.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize {
        label.sizeToFit()
        return NSSize(width: ceil(label.frame.width) + 24 + 28 + 26, height: 48)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        label.sizeToFit()
        let total = 22 + 8 + label.frame.width
        let x = (bounds.width - total) / 2
        icon.frame = NSRect(x: x, y: (bounds.height - 22) / 2, width: 22, height: 22)
        label.frame = NSRect(x: x + 30, y: (bounds.height - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { alphaValue = 0.75 }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { NSApp.sendAction(action, to: target, from: self) }
    }
}

/// 首页上的一张最近看过。
final class RecentCard: NSView {
    let record: WatchRecord
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    private let thumb = ThumbView()
    private let title = Style.label(size: 13, weight: .medium)
    private let detail = Style.label(size: 12, color: Style.secondary)
    private var tracking: NSTrackingArea?

    init(record: WatchRecord) {
        self.record = record
        super.init(frame: .zero)
        wantsLayer = true
        thumb.layer?.cornerRadius = 10
        thumb.progress = record.finished ? nil : record.progress
        title.stringValue = Media.title(of: record.url)
        if record.finished {
            detail.stringValue = "已看完 · \(relativeDay(record.updated))"
        } else if let r = record.resumePosition {
            detail.stringValue = "看到 \(formatTime(r, likeDuration: record.duration)) / \(formatTime(record.duration))"
        } else {
            detail.stringValue = relativeDay(record.updated)
        }
        addSubview(thumb)
        addSubview(title)
        addSubview(detail)
        if let snap = Thumbnails.shared.snapshot(for: record.path) {
            thumb.image = snap
        } else {
            Thumbnails.shared.poster(for: record.url) { [weak self] img, _ in self?.thumb.image = img }
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "在访达中显示", action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(withTitle: "从最近记录中移除", action: #selector(remove), keyEquivalent: "").target = self
        self.menu = menu
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let th = w * 9 / 16
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

    override func mouseExited(with event: NSEvent) { thumb.layer?.borderWidth = 0 }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
    override func mouseDown(with event: NSEvent) {}

    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([record.url]) }
    @objc private func remove() { onRemove?() }
}
