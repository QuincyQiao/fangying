import AppKit

enum Style {
    static let text = NSColor(white: 1, alpha: 0.92)
    static let secondary = NSColor(white: 1, alpha: 0.58)
    static let faint = NSColor(white: 1, alpha: 0.36)
    static let hover = NSColor(white: 1, alpha: 0.10)
    static let current = NSColor(white: 1, alpha: 0.14)

    static func glass(cornerRadius: CGFloat, tint: CGFloat = 0.28) -> NSGlassEffectView {
        let g = NSGlassEffectView()
        g.cornerRadius = cornerRadius
        g.style = .regular
        g.tintColor = NSColor(white: 0, alpha: tint)
        return g
    }

    static func label(_ s: String = "", size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = text, mono: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        return l
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}

/// 图标按钮：白色 SF Symbol，悬停有圆形底，按下变暗。不抢键盘焦点。
final class IconButton: NSButton {
    var symbol: String { didSet { refresh() } }
    var pointSize: CGFloat { didSet { refresh() } }
    var tint = Style.text { didSet { contentTintColor = tint } }
    private var hovering = false { didSet { updateBackground() } }
    private var tracking: NSTrackingArea?

    init(_ symbol: String, size: CGFloat = 15, target: AnyObject?, action: Selector?) {
        self.symbol = symbol
        self.pointSize = size
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        refusesFirstResponder = true
        contentTintColor = tint
        wantsLayer = true
        layer?.cornerCurve = .continuous
        (cell as? NSButtonCell)?.highlightsBy = .contentsCellMask
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        image = Style.symbol(symbol, size: pointSize)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    private func updateBackground() {
        layer?.backgroundColor = hovering && isEnabled ? Style.hover.cgColor : nil
    }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35; updateBackground() } }

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

/// 文字按钮（倍速「1×」、「从头播放」）。
final class TextButton: NSButton {
    /// 平时的底色（「加载字幕文件…」用）
    var restColor: NSColor? { didSet { updateBackground() } }
    /// 当前选中的档位
    var isActive = false { didSet { updateBackground() } }
    private var hovering = false { didSet { updateBackground() } }
    private var tracking: NSTrackingArea?
    var textColor = Style.text { didSet { setText(title) } }
    var fontSize: CGFloat = 13 { didSet { setText(title) } }

    init(_ text: String, size: CGFloat = 13, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        fontSize = size
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerCurve = .continuous
        setText(text)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateBackground() {
        let color = isActive ? NSColor(white: 1, alpha: 0.22) : hovering ? Style.hover : restColor
        layer?.backgroundColor = color?.cgColor
    }

    func setText(_ s: String) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: textColor, .paragraphStyle: p,
        ])
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
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
}

/// 进度条 / 音量条：细轨道，悬停变粗并出现圆点；拖动时连续回调。
final class Scrubber: NSView {
    enum Phase { case began, changed, ended }

    var value: Double = 0 { didSet { if !dragging { layoutBars() } } }
    var buffered: Double? { didSet { layoutBars() } }
    var marks: [Double] = [] { didSet { rebuildMarks() } }
    var onScrub: ((Double, Phase) -> Void)?
    var onHover: ((Double?) -> Void)?
    var thin: CGFloat = 4
    var thick: CGFloat = 7
    var alwaysShowKnob = false

    private let track = CALayer()
    private let buffer = CALayer()
    private let fill = CALayer()
    private let knob = CALayer()
    private var markLayers: [CALayer] = []
    private(set) var dragging = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var dragValue: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
        buffer.backgroundColor = NSColor(white: 1, alpha: 0.20).cgColor
        fill.backgroundColor = NSColor(white: 1, alpha: 0.95).cgColor
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.35
        knob.shadowRadius = 3
        knob.shadowOffset = .zero
        knob.opacity = 0
        for l in [track, buffer, fill] { l.cornerCurve = .continuous; l.masksToBounds = true }
        layer?.addSublayer(track)
        track.addSublayer(buffer)
        track.addSublayer(fill)
        layer?.addSublayer(knob)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        rebuildMarks()
    }

    private var shown: Double { dragging ? dragValue : value }

    /// animated 只在悬停变粗/变细时用；播放进度每帧更新时不做动画。
    private func layoutBars(animated: Bool = false) {
        let expanded = hovering || dragging
        let h = expanded ? thick : thin
        let w = bounds.width
        let v = min(1, max(0, shown))
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.15)
        track.frame = CGRect(x: 0, y: (bounds.height - h) / 2, width: w, height: h)
        track.cornerRadius = h / 2
        fill.frame = CGRect(x: 0, y: 0, width: w * v, height: h)
        if let b = buffered {
            buffer.isHidden = false
            buffer.frame = CGRect(x: 0, y: 0, width: w * min(1, max(0, b)), height: h)
        } else {
            buffer.isHidden = true
        }
        let k: CGFloat = 13
        knob.frame = CGRect(x: w * v - k / 2, y: (bounds.height - k) / 2, width: k, height: k)
        knob.cornerRadius = k / 2
        knob.opacity = (expanded || alwaysShowKnob) ? 1 : 0
        for (layer, m) in zip(markLayers, visibleMarks) {
            layer.frame = CGRect(x: w * m - 1, y: 0, width: 2, height: h)
        }
        CATransaction.commit()
    }

    private var visibleMarks: [Double] { marks.filter { $0 > 0.005 && $0 < 0.995 } }

    private func rebuildMarks() {
        markLayers.forEach { $0.removeFromSuperlayer() }
        markLayers = visibleMarks.map { _ in
            let l = CALayer()
            l.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
            track.addSublayer(l)
            return l
        }
        layoutBars()
    }

    private func fraction(at event: NSEvent) -> Double {
        let p = convert(event.locationInWindow, from: nil)
        return Double(min(1, max(0, p.x / max(1, bounds.width))))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds.insetBy(dx: 0, dy: -6), options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layoutBars(animated: true)
        onHover?(fraction(at: event))
    }

    override func mouseMoved(with event: NSEvent) { onHover?(fraction(at: event)) }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layoutBars(animated: true)
        if !dragging { onHover?(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        dragValue = fraction(at: event)
        layoutBars()
        onScrub?(dragValue, .began)
    }

    override func mouseDragged(with event: NSEvent) {
        dragValue = fraction(at: event)
        layoutBars()
        onHover?(dragValue)
        onScrub?(dragValue, .changed)
    }

    override func mouseUp(with event: NSEvent) {
        dragValue = fraction(at: event)
        dragging = false
        value = dragValue
        onScrub?(dragValue, .ended)
        let p = convert(event.locationInWindow, from: nil)
        if !bounds.insetBy(dx: 0, dy: -6).contains(p) {
            hovering = false
            onHover?(nil)
        }
        layoutBars(animated: true)
    }
}

/// 圆角缩略图，铺满裁切；底部可显示看过的进度。
final class ThumbView: NSView {
    var image: NSImage? { didSet { imageLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) } }
    var progress: Double? { didSet { needsLayout = true } }
    var placeholderSymbol = "film" { didSet { placeholder.image = Style.symbol(placeholderSymbol, size: 18, weight: .regular) } }
    private let imageLayer = CALayer()
    private let barTrack = CALayer()
    private let bar = CALayer()
    private let placeholder = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        placeholder.image = Style.symbol(placeholderSymbol, size: 18, weight: .regular)
        placeholder.contentTintColor = Style.faint
        addSubview(placeholder)
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
        barTrack.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        bar.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(barTrack)
        layer?.addSublayer(bar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        placeholder.frame = bounds
        if let p = progress, p > 0.005 {
            let h: CGFloat = 3
            barTrack.isHidden = false
            bar.isHidden = false
            barTrack.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
            bar.frame = CGRect(x: 0, y: 0, width: bounds.width * min(1, p), height: h)
        } else {
            barTrack.isHidden = true
            bar.isHidden = true
        }
        CATransaction.commit()
    }
}

/// 屏幕上方的提示条：音量、倍速、字幕延迟这些变化；续播时带一个「从头播放」。
final class OSDView: NSView {
    private let glass = Style.glass(cornerRadius: 20, tint: 0.5)
    private let content = NSView()
    private let icon = NSImageView()
    private let text = Style.label(size: 14, weight: .medium)
    private(set) var button: TextButton?
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.contentView = content
        addSubview(glass)
        icon.contentTintColor = Style.text
        content.addSubview(icon)
        content.addSubview(text)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ message: String, symbol: String?, duration: TimeInterval = 1.4,
              buttonTitle: String? = nil, target: AnyObject? = nil, action: Selector? = nil) {
        text.stringValue = message
        icon.image = symbol.flatMap { Style.symbol($0, size: 15) }
        icon.isHidden = symbol == nil
        button?.removeFromSuperview()
        button = nil
        if let buttonTitle {
            let b = TextButton(buttonTitle, size: 13, target: target, action: action)
            b.textColor = NSColor.controlAccentColor.blended(withFraction: 0.35, of: .white) ?? .white
            content.addSubview(b)
            button = b
        }
        needsLayout = true
        superview?.needsLayout = true
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.isHidden = true
        }
    }

    var preferredSize: NSSize {
        text.sizeToFit()
        var w: CGFloat = 20 + text.frame.width + 20
        if !icon.isHidden { w += 24 }
        if let b = button { b.sizeToFit(); w += b.frame.width + 24 }
        return NSSize(width: ceil(w), height: 40)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        var x: CGFloat = 18
        if !icon.isHidden {
            icon.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: 20, height: 20)
            x += 26
        }
        text.sizeToFit()
        text.frame = NSRect(x: x, y: (bounds.height - text.frame.height) / 2, width: text.frame.width, height: text.frame.height)
        x += text.frame.width + 10
        if let b = button {
            b.sizeToFit()
            b.frame = NSRect(x: x, y: (bounds.height - 28) / 2, width: b.frame.width + 20, height: 28)
        }
    }
}

/// 顶部渐暗，衬托标题和红绿灯。
final class GradientView: NSView {
    private let gradient = CAGradientLayer()
    init(top: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        gradient.colors = [NSColor(white: 0, alpha: 0.55).cgColor, NSColor(white: 0, alpha: 0).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: top ? 1 : 0)
        gradient.endPoint = CGPoint(x: 0.5, y: top ? 0 : 1)
        layer?.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
