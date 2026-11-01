import AppKit

/// 用户可调的设置，存在 UserDefaults 里，菜单「放映 → 设置…」改。
enum Settings {
    static let seekStepRange = 1...120

    /// 按左右方向键跳过的秒数
    static var seekStep: Int {
        get { (UserDefaults.standard.object(forKey: "方向键跳过秒数") as? Int) ?? 3 }
        set { UserDefaults.standard.set(min(seekStepRange.upperBound, max(seekStepRange.lowerBound, newValue)), forKey: "方向键跳过秒数") }
    }

    /// 单击画面时播放或暂停。默认关：点一下窗口只是切过来，不该动播放状态
    static var clickToPause: Bool {
        get { UserDefaults.standard.bool(forKey: "单击画面暂停") }
        set { UserDefaults.standard.set(newValue, forKey: "单击画面暂停") }
    }

    static let remoteChanged = Notification.Name("local.fangying.remote-changed")

    /// 远程电脑在 SSH 配置里的名字。不填就不显示远程片库
    static var remoteHost: String? {
        get {
            let s = UserDefaults.standard.string(forKey: "远程电脑")?.trimmingCharacters(in: .whitespaces) ?? ""
            return !s.isEmpty && Remote.isValidHost(s) ? s : nil
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "远程电脑")
            NotificationCenter.default.post(name: remoteChanged, object: nil)
        }
    }
}

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let stepField = NSTextField()
    private let stepper = NSStepper()
    private let clickPopup = NSPopUpButton()
    private let hostField = NSTextField()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 178),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)

        let v = window.contentView!
        let labelX: CGFloat = 24, controlX: CGFloat = 168
        let seekLabel = Style.label("左右方向键跳过", size: 14)
        seekLabel.frame = NSRect(x: labelX, y: 126, width: 136, height: 20)
        v.addSubview(seekLabel)

        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: Settings.seekStepRange.lowerBound)
        formatter.maximum = NSNumber(value: Settings.seekStepRange.upperBound)
        stepField.formatter = formatter
        stepField.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        stepField.alignment = .center
        stepField.frame = NSRect(x: controlX, y: 124, width: 56, height: 24)
        stepField.delegate = self
        v.addSubview(stepField)

        stepper.minValue = Double(Settings.seekStepRange.lowerBound)
        stepper.maxValue = Double(Settings.seekStepRange.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        stepper.frame = NSRect(x: controlX + 60, y: 124, width: 20, height: 24)
        v.addSubview(stepper)

        let unit = Style.label("秒", size: 14)
        unit.frame = NSRect(x: controlX + 88, y: 126, width: 30, height: 20)
        v.addSubview(unit)

        let clickLabel = Style.label("单击画面", size: 14)
        clickLabel.frame = NSRect(x: labelX, y: 80, width: 136, height: 20)
        v.addSubview(clickLabel)

        clickPopup.addItems(withTitles: ["不做任何事", "播放或暂停"])
        clickPopup.font = .systemFont(ofSize: 14)
        clickPopup.target = self
        clickPopup.action = #selector(clickChanged)
        clickPopup.frame = NSRect(x: controlX - 3, y: 76, width: 150, height: 28)
        v.addSubview(clickPopup)

        let hostLabel = Style.label("远程电脑", size: 14)
        hostLabel.frame = NSRect(x: labelX, y: 34, width: 136, height: 20)
        v.addSubview(hostLabel)

        hostField.placeholderString = "SSH 名称"
        hostField.font = .systemFont(ofSize: 14)
        hostField.frame = NSRect(x: controlX, y: 32, width: 144, height: 24)
        hostField.delegate = self
        v.addSubview(hostField)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        stepField.integerValue = Settings.seekStep
        stepper.integerValue = Settings.seekStep
        clickPopup.selectItem(at: Settings.clickToPause ? 1 : 0)
        hostField.stringValue = Settings.remoteHost ?? ""
    }

    func show(over parent: NSWindow?) {
        refresh()
        if let parent, let w = window, !w.isVisible {
            let f = parent.frame
            w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func stepperChanged() {
        Settings.seekStep = stepper.integerValue
        stepField.integerValue = Settings.seekStep
    }

    @objc private func clickChanged() { Settings.clickToPause = clickPopup.indexOfSelectedItem == 1 }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === hostField { return }
        guard let n = Int(stepField.stringValue), Settings.seekStepRange.contains(n) else { return }
        Settings.seekStep = n
        stepper.integerValue = n
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === hostField {
            let s = hostField.stringValue.trimmingCharacters(in: .whitespaces)
            Settings.remoteHost = Remote.isValidHost(s) ? s : nil
        }
        refresh()
    }
}
