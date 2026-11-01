import AppKit

/// 菜单栏。快捷键都在这里，菜单上看得到。
enum MainMenu {
    static func build(controller c: PlayerWindowController) -> NSMenu {
        let main = NSMenu()

        func menu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            build(m)
            item.submenu = m
        }

        enum To { case controller, app, chain }
        func add(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], to: To = .controller, tag: Int = 0) {
            let item = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            switch to {
            case .controller: item.target = c
            case .app: item.target = NSApp
            case .chain: item.target = nil
            }
            item.tag = tag
        }

        func dynamic(_ m: NSMenu, _ title: String, id: String) {
            let item = m.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            sub.identifier = NSUserInterfaceItemIdentifier(id)
            sub.delegate = c
            item.submenu = sub
        }

        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

        menu("放映") { m in
            add(m, "关于放映", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", [], to: .app)
            m.addItem(.separator())
            add(m, "设置…", #selector(PlayerWindowController.showSettings(_:)), ",", [.command])
            add(m, "设为视频的默认播放器", #selector(PlayerWindowController.setAsDefaultPlayer(_:)), "", [])
            m.addItem(.separator())
            add(m, "隐藏放映", #selector(NSApplication.hide(_:)), "h", to: .app)
            add(m, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], to: .app)
            add(m, "全部显示", #selector(NSApplication.unhideAllApplications(_:)), "", [], to: .app)
            m.addItem(.separator())
            add(m, "退出放映", #selector(NSApplication.terminate(_:)), "q", to: .app)
        }

        menu("文件") { m in
            add(m, "打开…", #selector(PlayerWindowController.openDocument(_:)), "o")
            add(m, "远程片库…", #selector(PlayerWindowController.showRemoteBrowser(_:)), "o", [.command, .option])
            dynamic(m, "打开最近", id: "recent")
            m.addItem(.separator())
            add(m, "加载字幕文件…", #selector(PlayerWindowController.loadSubtitleFile(_:)), "o", [.command, .shift])
            add(m, "在访达中显示", #selector(PlayerWindowController.revealCurrent(_:)), "r", [.command, .shift])
            m.addItem(.separator())
            add(m, "关闭", #selector(NSWindow.performClose(_:)), "w", to: .chain)
        }

        menu("播放") { m in
            add(m, "播放", #selector(PlayerWindowController.togglePlay(_:)), " ", [])
            m.addItem(.separator())
            add(m, "快进 \(Settings.seekStep) 秒", #selector(PlayerWindowController.seekForward(_:)), right, [])
            add(m, "快退 \(Settings.seekStep) 秒", #selector(PlayerWindowController.seekBackward(_:)), left, [])
            add(m, "快进 30 秒", #selector(PlayerWindowController.seekForwardLong(_:)), right, [.shift])
            add(m, "快退 30 秒", #selector(PlayerWindowController.seekBackwardLong(_:)), left, [.shift])
            add(m, "下一帧", #selector(PlayerWindowController.frameForward(_:)), ".", [])
            add(m, "上一帧", #selector(PlayerWindowController.frameBackward(_:)), ",", [])
            m.addItem(.separator())
            let speedItem = m.addItem(withTitle: "倍速", action: nil, keyEquivalent: "")
            let speeds = NSMenu(title: "倍速")
            speeds.identifier = NSUserInterfaceItemIdentifier("speeds")
            speeds.delegate = c
            add(speeds, "加快", #selector(PlayerWindowController.speedUp(_:)), "]", [])
            add(speeds, "减慢", #selector(PlayerWindowController.speedDown(_:)), "[", [])
            add(speeds, "恢复正常速度", #selector(PlayerWindowController.speedReset(_:)), "\\", [])
            speeds.addItem(.separator())
            speedItem.submenu = speeds
            m.addItem(.separator())
            add(m, "下一个", #selector(PlayerWindowController.playNext(_:)), right, [.command])
            add(m, "上一个", #selector(PlayerWindowController.playPrevious(_:)), left, [.command])
        }

        menu("视频") { m in
            add(m, "全屏", #selector(PlayerWindowController.toggleFullScreenFromBar(_:)), "f", [.command, .control])
            add(m, "窗口置顶", #selector(PlayerWindowController.toggleFloat(_:)), "t", [.command, .option])
            let sizes = m.addItem(withTitle: "窗口大小", action: nil, keyEquivalent: "")
            let sm = NSMenu(title: "窗口大小")
            add(sm, "一半", #selector(PlayerWindowController.windowSize(_:)), "0", [.command], tag: 50)
            add(sm, "原始大小", #selector(PlayerWindowController.windowSize(_:)), "1", [.command], tag: 100)
            add(sm, "两倍", #selector(PlayerWindowController.windowSize(_:)), "2", [.command], tag: 200)
            add(sm, "铺满屏幕", #selector(PlayerWindowController.windowSize(_:)), "3", [.command], tag: 0)
            sizes.submenu = sm
            m.addItem(.separator())
            add(m, "显示侧栏", #selector(PlayerWindowController.toggleSidebar(_:)), "s", [.command, .control])
            add(m, "播放列表", #selector(PlayerWindowController.showSidebarTab(_:)), "l", [.command, .option], tag: SidebarView.Tab.playlist.rawValue)
            add(m, "最近看过", #selector(PlayerWindowController.showSidebarTab(_:)), "r", [.command, .option], tag: SidebarView.Tab.recent.rawValue)
        }

        menu("音频") { m in
            dynamic(m, "音轨", id: "audioTracks")
            m.addItem(.separator())
            add(m, "音量加大", #selector(PlayerWindowController.volumeUp(_:)), up, [])
            add(m, "音量减小", #selector(PlayerWindowController.volumeDown(_:)), down, [])
            add(m, "静音", #selector(PlayerWindowController.toggleMute(_:)), "m", [])
        }

        menu("字幕") { m in
            dynamic(m, "字幕", id: "subTracks")
            dynamic(m, "第二字幕", id: "secondaryTracks")
            add(m, "加载字幕文件…", #selector(PlayerWindowController.loadSubtitleFile(_:)), "o", [.command, .shift])
            m.addItem(.separator())
            add(m, "字幕变大", #selector(PlayerWindowController.subBigger(_:)), "=", [.command, .option])
            add(m, "字幕变小", #selector(PlayerWindowController.subSmaller(_:)), "-", [.command, .option])
            add(m, "字幕上移", #selector(PlayerWindowController.subUp(_:)), up, [.command, .option])
            add(m, "字幕下移", #selector(PlayerWindowController.subDown(_:)), down, [.command, .option])
            add(m, "字幕提前 0.1 秒", #selector(PlayerWindowController.subDelayMinus(_:)), "z", [])
            add(m, "字幕推后 0.1 秒", #selector(PlayerWindowController.subDelayPlus(_:)), "x", [])
            add(m, "字幕恢复默认", #selector(PlayerWindowController.subReset(_:)), "", [])
            m.addItem(.separator())
            add(m, "字幕设置", #selector(PlayerWindowController.showSidebarTab(_:)), "", [], tag: SidebarView.Tab.subtitles.rawValue)
        }

        let windowMenu = NSMenu(title: "窗口")
        add(windowMenu, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m", to: .chain)
        add(windowMenu, "缩放", #selector(NSWindow.performZoom(_:)), "", [], to: .chain)
        windowMenu.addItem(.separator())
        add(windowMenu, "前置全部窗口", #selector(NSApplication.arrangeInFront(_:)), "", [], to: .app)
        main.addItem(withTitle: "窗口", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}
