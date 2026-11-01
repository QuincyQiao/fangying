import AppKit

/// 画面下方浮着的玻璃控制条：上一排按钮，下一排进度。
final class ControlBar: NSView {
    unowned let controller: PlayerWindowController
    private let glass = Style.glass(cornerRadius: 26, tint: 0.52)
    private let content = NSView()

    let playButton: IconButton
    let prevButton: IconButton
    let nextButton: IconButton
    let volumeButton: IconButton
    let volumeSlider = Scrubber()
    let speedButton: TextButton
    let subtitleButton: IconButton
    let audioButton: IconButton
    let sidebarButton: IconButton
    let libraryButton: IconButton
    let fullscreenButton: IconButton
    let elapsed = Style.label(size: 12, weight: .medium, color: Style.secondary, mono: true)
    let remaining = Style.label(size: 12, weight: .medium, color: Style.secondary, mono: true)
    let scrubber = Scrubber()
    var showRemaining = UserDefaults.standard.object(forKey: "显示剩余时间") as? Bool ?? true

    init(controller: PlayerWindowController) {
        self.controller = controller
        playButton = IconButton("play.fill", size: 22, target: controller, action: #selector(PlayerWindowController.togglePlay(_:)))
        prevButton = IconButton("backward.end.fill", size: 15, target: controller, action: #selector(PlayerWindowController.playPrevious(_:)))
        nextButton = IconButton("forward.end.fill", size: 15, target: controller, action: #selector(PlayerWindowController.playNext(_:)))
        volumeButton = IconButton("speaker.wave.2.fill", size: 14, target: controller, action: #selector(PlayerWindowController.toggleMute(_:)))
        speedButton = TextButton("1×", size: 13, target: controller, action: #selector(PlayerWindowController.showSpeedPanel(_:)))
        subtitleButton = IconButton("captions.bubble", size: 15, target: controller, action: #selector(PlayerWindowController.showSubtitleMenu(_:)))
        audioButton = IconButton("waveform", size: 15, target: controller, action: #selector(PlayerWindowController.showAudioMenu(_:)))
        sidebarButton = IconButton("sidebar.right", size: 15, target: controller, action: #selector(PlayerWindowController.toggleSidebar(_:)))
        libraryButton = IconButton("macmini", size: 14, target: controller, action: #selector(PlayerWindowController.showRemoteBrowser(_:)))
        fullscreenButton = IconButton("arrow.up.left.and.arrow.down.right", size: 14, target: controller, action: #selector(PlayerWindowController.toggleFullScreenFromBar(_:)))
        super.init(frame: .zero)

        glass.contentView = content
        addSubview(glass)
        for v in [playButton, prevButton, nextButton, volumeButton, volumeSlider, speedButton, subtitleButton,
                  audioButton, sidebarButton, libraryButton, fullscreenButton, elapsed, remaining, scrubber] as [NSView] {
            content.addSubview(v)
        }
        elapsed.alignment = .left
        remaining.alignment = .right
        remaining.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleRemaining)))

        volumeSlider.thin = 3
        volumeSlider.thick = 5
        volumeSlider.onScrub = { [weak controller] v, _ in controller?.player.setVolume(v * 100) }
        scrubber.onScrub = { [weak controller] v, phase in controller?.scrub(to: v, phase: phase) }
        scrubber.onHover = { [weak self] v in
            guard let self else { return }
            self.controller.scrubberHover(fraction: v, in: self.scrubber)
        }

        prevButton.toolTip = "上一个"
        nextButton.toolTip = "下一个"
        speedButton.toolTip = "倍速"
        subtitleButton.toolTip = "字幕"
        audioButton.toolTip = "音轨"
        sidebarButton.toolTip = "侧栏"
        libraryButton.toolTip = "远程片库"
        fullscreenButton.toolTip = "全屏"
    }

    required init?(coder: NSCoder) { fatalError() }

    static let height: CGFloat = 86

    var isInteracting: Bool { scrubber.dragging || volumeSlider.dragging }

    @objc private func toggleRemaining() {
        showRemaining.toggle()
        UserDefaults.standard.set(showRemaining, forKey: "显示剩余时间")
        updateTime()
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let w = bounds.width, h = bounds.height
        let narrow = w < 520

        // 上排按钮
        let rowMid = h - 14 - 17
        func place(_ v: NSView, x: CGFloat, size: CGFloat) {
            v.frame = NSRect(x: x, y: rowMid - size / 2, width: size, height: size)
        }
        place(playButton, x: w / 2 - 20, size: 40)
        place(prevButton, x: w / 2 - 20 - 14 - 34, size: 34)
        place(nextButton, x: w / 2 + 20 + 14, size: 34)

        place(volumeButton, x: 14, size: 32)
        volumeSlider.isHidden = narrow
        volumeSlider.frame = NSRect(x: 50, y: rowMid - 8, width: 78, height: 16)

        var x = w - 14 - 32
        place(fullscreenButton, x: x, size: 32); x -= 34
        place(sidebarButton, x: x, size: 32); x -= 34
        place(audioButton, x: x, size: 32); x -= 34
        place(subtitleButton, x: x, size: 32); x -= 48
        speedButton.isHidden = narrow
        speedButton.frame = NSRect(x: x, y: rowMid - 14, width: 46, height: 28)
        libraryButton.isHidden = w < 600 || Settings.remoteHost == nil
        place(libraryButton, x: x - 36, size: 32)

        // 下排进度
        let barMid: CGFloat = 22
        let labelW: CGFloat = 64
        elapsed.frame = NSRect(x: 20, y: barMid - 8, width: labelW, height: 16)
        remaining.frame = NSRect(x: w - 20 - labelW, y: barMid - 8, width: labelW, height: 16)
        scrubber.frame = NSRect(x: 20 + labelW + 6, y: barMid - 10, width: w - 2 * (20 + labelW + 6), height: 20)
    }

    // MARK: 跟着播放器刷新

    func updateAll() {
        updatePlay()
        updateTime()
        updateVolume()
        updateSpeed()
        updateTracks()
        updateChapters()
        updateNavigation()
    }

    func updatePlay() {
        let p = controller.player
        playButton.symbol = (p.paused || p.idle) ? "play.fill" : "pause.fill"
        playButton.toolTip = p.paused ? "播放" : "暂停"
    }

    func updateTime() {
        let p = controller.player
        let d = p.duration
        let pos = scrubber.dragging ? scrubberPreviewTime : p.position
        elapsed.stringValue = formatTime(pos, likeDuration: d)
        if d > 0 {
            remaining.stringValue = showRemaining ? "-" + formatTime(max(0, d - pos), likeDuration: d) : formatTime(d)
            if !scrubber.dragging { scrubber.value = pos / d }
            if let c = p.cacheTime, c > pos + 1 { scrubber.buffered = min(1, c / d) } else { scrubber.buffered = nil }
        } else {
            remaining.stringValue = "--:--"
            scrubber.value = 0
            scrubber.buffered = nil
        }
        scrubber.isEnabled(d > 0)
    }

    var scrubberPreviewTime: Double = 0

    func updateVolume() {
        let p = controller.player
        let v = p.muted ? 0 : p.volume
        volumeButton.symbol = p.muted || v == 0 ? "speaker.slash.fill" : v < 34 ? "speaker.wave.1.fill" : v < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        if !volumeSlider.dragging { volumeSlider.value = min(1, v / 100) }
    }

    func updateSpeed() {
        let s = controller.player.speed
        speedButton.setText(Self.speedText(s))
        speedButton.textColor = abs(s - 1) < 0.001 ? Style.text : (NSColor.controlAccentColor.blended(withFraction: 0.3, of: .white) ?? .white)
    }

    static func speedText(_ s: Double) -> String {
        let t = s == s.rounded() ? String(format: "%.0f", s) : (s * 10 == (s * 10).rounded() ? String(format: "%.1f", s) : String(format: "%.2f", s))
        return t + "×"
    }

    func updateTracks() {
        let tracks = controller.player.tracks
        let hasSubs = tracks.contains { $0.type == "sub" }
        let subOn = tracks.contains { $0.type == "sub" && $0.selected }
        subtitleButton.symbol = subOn ? "captions.bubble.fill" : "captions.bubble"
        subtitleButton.tint = hasSubs ? Style.text : Style.secondary
        audioButton.isEnabled = tracks.filter { $0.type == "audio" }.count > 0
    }

    func updateChapters() {
        let p = controller.player
        scrubber.marks = p.duration > 0 ? p.chapters.map { $0.time / p.duration } : []
    }

    func updateNavigation() {
        let p = controller.player
        nextButton.isEnabled = p.hasNext
        prevButton.isEnabled = p.current != nil
    }

    func updateFullscreen(_ on: Bool) {
        fullscreenButton.symbol = on ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        fullscreenButton.toolTip = on ? "退出全屏" : "全屏"
    }
}

private extension Scrubber {
    func isEnabled(_ on: Bool) { alphaValue = on ? 1 : 0.4 }
}
