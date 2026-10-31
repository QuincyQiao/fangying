import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: PlayerWindowController!
    private var pendingURLs: [URL] = []
    private let launchArgs: [String]

    init(args: [String]) {
        launchArgs = args
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = PlayerWindowController()
        NSApp.mainMenu = MainMenu.build(controller: controller)
        // 截图检查界面时静音、不抢到最前面
        if ProcessInfo.processInfo.environment["FANGYING_DEMO"] != nil {
            controller.player.mpv.set("mute", true)
            controller.window?.orderBack(nil)
        } else {
            controller.showWindow(nil)
            NSApp.activate()
        }

        // 直接运行可执行文件时，命令行里的路径当作要打开的文件
        var files: [URL] = []
        var i = 1
        var seek: Double?
        var tab: SidebarView.Tab?
        var pause = false
        while i < launchArgs.count {
            let a = launchArgs[i]
            switch a {
            case "--seek": seek = Double(launchArgs[safe: i + 1] ?? ""); i += 1
            case "--sidebar":
                tab = ["列表": .playlist, "最近": .recent, "字幕": .subtitles][launchArgs[safe: i + 1] ?? ""]
                i += 1
            case "--pause": pause = true
            default: if !a.hasPrefix("-") { files.append(URL(fileURLWithPath: a)) }
            }
            i += 1
        }
        let urls = pendingURLs + files
        pendingURLs = []
        if !urls.isEmpty { controller.open(urls) }
        if seek != nil || tab != nil || pause {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let c = self?.controller else { return }
                if let s = seek { c.player.seek(to: s) }
                if pause { c.player.setPaused(true) }
                if let tab { c.setSidebar(visible: true, tab: tab) }
            }
        }
        // 截图检查进度条悬停预览：FANGYING_DEMO_HOVER=0.6
        if let h = ProcessInfo.processInfo.environment["FANGYING_DEMO_HOVER"], let f = Double(h) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let c = self?.controller else { return }
                c.scrubberHover(fraction: f, in: c.controlBar.scrubber)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if controller == nil { pendingURLs += urls } else { controller.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

let args = CommandLine.arguments
if args.contains("--self-test") {
    exit(SelfTest.run(args))
}
if let i = args.firstIndex(of: "--make-icon"), let out = args[safe: i + 1] {
    exit(IconMaker.write(to: URL(fileURLWithPath: out)) ? 0 : 1)
}
if args.contains("--set-default") {
    let failed = DefaultApp.setAsDefault()
    print(failed.isEmpty ? "已设为默认播放器" : "没设上：\(failed.joined(separator: "、"))")
    exit(0)
}

if args.contains("--desktop-alias") {
    do {
        try DefaultApp.makeDesktopAlias()
        print("桌面替身已放好")
    } catch {
        print("桌面替身没放上：\(error.localizedDescription)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate(args: args)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
