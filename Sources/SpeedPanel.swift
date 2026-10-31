import AppKit

/// 倍速面板：滑条自己调（0.25–4 倍，每格 0.05），下面留几个常用档。
final class SpeedPanel: NSViewController {
    private unowned let controller: PlayerWindowController
    private let titleLabel = Style.label("倍速", size: 14, weight: .medium, color: Style.secondary)
    private let value = Style.label(size: 22, weight: .semibold, mono: true)
    private let slider = NSSlider(value: 1, minValue: 0.25, maxValue: 4, target: nil, action: nil)
    private var presets: [TextButton] = []
    private var dragging = false

    init(controller: PlayerWindowController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let w: CGFloat = 304, h: CGFloat = 132, pad: CGFloat = 16
        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        titleLabel.frame = NSRect(x: pad, y: h - 38, width: 80, height: 20)
        value.alignment = .right
        value.frame = NSRect(x: w - pad - 120, y: h - 42, width: 120, height: 28)
        slider.frame = NSRect(x: pad, y: 52, width: w - 2 * pad, height: 24)
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        slider.refusesFirstResponder = true
        for sub in [titleLabel, value, slider] as [NSView] { v.addSubview(sub) }

        let speeds = PlayerWindowController.commonSpeeds
        let gap: CGFloat = 6
        let bw = ((w - 2 * pad - gap * CGFloat(speeds.count - 1)) / CGFloat(speeds.count)).rounded(.down)
        for (i, s) in speeds.enumerated() {
            let b = TextButton(ControlBar.speedText(s), size: 13, target: self, action: #selector(presetTapped(_:)))
            b.tag = Int(s * 100)
            b.frame = NSRect(x: pad + CGFloat(i) * (bw + gap), y: 14, width: bw, height: 30)
            presets.append(b)
            v.addSubview(b)
        }
        view = v
        preferredContentSize = v.frame.size
        update()
    }

    /// mpv 回报倍速时刷新；拖滑条的时候不跟回报抢。
    func update() {
        guard isViewLoaded else { return }
        let s = controller.player.speed
        if !dragging {
            slider.doubleValue = s
            value.stringValue = ControlBar.speedText(s)
        }
        for b in presets { b.isActive = abs(Double(b.tag) / 100 - s) < 0.001 }
    }

    @objc private func sliderChanged() {
        let type = NSApp.currentEvent?.type
        dragging = type == .leftMouseDragged || type == .leftMouseDown
        let s = (slider.doubleValue * 20).rounded() / 20
        value.stringValue = ControlBar.speedText(s)
        controller.player.setSpeed(s)
    }

    @objc private func presetTapped(_ sender: TextButton) {
        dragging = false
        controller.player.setSpeed(Double(sender.tag) / 100)
    }
}
