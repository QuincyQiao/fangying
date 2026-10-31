import AppKit
import OpenGL.GL3

/// 构建时跑的自测：用 ffmpeg 造各种格式的样片，检查 mpv 读取、字幕自动加载和编码识别、旋转、HDR、章节、
/// 缩略图、离屏渲染、观看记录。`--self-test bundle` 只检查打包后的库能不能加载。
enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        if ok { print("  ✓ \(what)") } else { print("  ✗ \(what)"); failures += 1 }
    }

    static func run(_ args: [String]) -> Int32 {
        let only = args.drop { $0 != "--self-test" }.dropFirst().first { !$0.hasPrefix("-") }
        if only == "bundle" { return bundleCheck() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("放映自测-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let groups: [(String, (URL) -> Void)] = [
            ("media", testMedia), ("history", testHistory), ("samples", makeSamples), ("thumb", testThumbs),
            ("mpv", testMPV), ("render", testRender),
        ]
        for (name, f) in groups {
            if let only, only != name, !(name == "samples" && ["thumb", "mpv", "render"].contains(only)) { continue }
            print("【\(name)】")
            f(dir)
        }
        print(failures == 0 ? "自测全部通过" : "自测有 \(failures) 项没过")
        return failures == 0 ? 0 : 1
    }

    // MARK: 文件名排序、语言名

    static func testMedia(_ dir: URL) {
        let names = ["第10集.mkv", "第2集.mkv", "第1集.mkv", "S01E11.mkv", "S01E9.mkv"].map { URL(fileURLWithPath: "/x/\($0)") }
        check(Media.sorted(names).map { $0.lastPathComponent } == ["S01E9.mkv", "S01E11.mkv", "第1集.mkv", "第2集.mkv", "第10集.mkv"], "按集数自然排序")
        check(Track.guessLanguage("chs")?.name == "简体中文" && Track.guessLanguage("cht")?.name == "繁体中文"
              && Track.guessLanguage("chs&eng")?.name == "简英双语" && Track.guessLanguage("简日双语")?.name == "简日双语"
              && Track.guessLanguage("eng")?.name == "英语" && Track.guessLanguage("Chinese Simplified")?.name == "简体中文", "字幕站的语言写法认得出")
        check(Media.kind(of: URL(fileURLWithPath: "/a/b.RMVB")) == .video, "RMVB 认作视频")
        check(Media.kind(of: URL(fileURLWithPath: "/a/b.ass")) == .subtitle, "ASS 认作字幕")
        check(languageName("chs") == "简体中文" && languageName("eng") == "英语" && languageName("und") == nil, "语言码换中文")
        check(formatTime(3725) == "1:02:05" && formatTime(65) == "1:05" && formatTime(65, likeDuration: 4000) == "0:01:05", "时间格式")
        check(ControlBar.speedText(1.25) == "1.25×" && ControlBar.speedText(1.5) == "1.5×" && ControlBar.speedText(2) == "2×", "倍速文字")
        check(Settings.seekStep == 3 && !Settings.clickToPause, "默认左右键跳 3 秒、单击画面不动播放")
        let chapters: [(title: String, time: Double)] = [("冷柜里的凹痕", 0), ("空气在推瓶壁", 28.1), ("先找真正的封口", 69.1)]
        check(Player.chapterTitle(in: chapters, at: 30) == "空气在推瓶壁" && Player.chapterTitle(in: chapters, at: 500) == "先找真正的封口"
              && Player.chapterTitle(in: [], at: 30) == "", "悬停时间对应到章节名")
    }

    // MARK: 观看记录

    static func testHistory(_ dir: URL) {
        let hdir = dir.appendingPathComponent("记录")
        let h = History(directory: hdir)
        h.update(path: "/v/a.mkv", position: 600, duration: 1500, finished: false)
        h.update(path: "/v/b.mkv", position: 1490, duration: 1500, finished: true)
        h.save()
        let h2 = History(directory: hdir)
        check(h2.records.count == 2 && h2.records.first?.path == "/v/b.mkv", "记录能存能读，最近的在前")
        check(h2.record(for: "/v/a.mkv")?.resumePosition == 600, "没看完的从 10:00 接着放")
        check(h2.record(for: "/v/b.mkv")?.resumePosition == nil, "看完的从头放")
        h2.update(path: "/v/c.mkv", position: 5, duration: 1500, finished: false)
        check(h2.record(for: "/v/c.mkv")?.resumePosition == nil, "只看了开头的从头放")
    }

    // MARK: 样片

    static var samples: [String: URL] = [:]

    static func ffmpeg(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + args
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func makeSamples(_ dir: URL) {
        let v = ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"]
        let t = ["-t", "4", "-g", "25"]
        let meta = dir.appendingPathComponent("章节.txt")
        try? ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=2000\ntitle=开头\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=2000\nEND=4000\ntitle=结尾\n"
            .write(to: meta, atomically: true, encoding: .utf8)
        let jobs: [(String, [String])] = [
            ("测试 第1集.mkv", v + ["-f", "ffmetadata", "-i", meta.path, "-map", "0:v", "-map", "1:a", "-map_chapters", "2"] + t + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
            ("测试 第2集.mkv", v + t + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
            ("测试 第10集.mp4", v + t + ["-c:v", "libx265", "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-c:a", "aac", "-x265-params", "log-level=error"]),
            ("老片.avi", v + t + ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "libmp3lame"]),
            ("网页.webm", v + t + ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-c:a", "libopus"]),
            ("直播.flv", v + t + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
            ("电视.ts", v + t + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
            ("竖屏.mp4", ["-display_rotation", "90"] + v + t + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
            ("HDR.mp4", v + t + ["-c:v", "libx265", "-tag:v", "hvc1", "-pix_fmt", "yuv420p10le", "-color_primaries", "bt2020",
                                  "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
                                  "-x265-params", "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc", "-c:a", "aac"]),
        ]
        let group = DispatchGroup()
        let lock = NSLock()
        for (name, a) in jobs {
            group.enter()
            DispatchQueue.global().async {
                let out = dir.appendingPathComponent(name)
                let ok = ffmpeg(a + [out.path])
                lock.lock(); if ok { samples[name] = out }; lock.unlock()
                group.leave()
            }
        }
        group.wait()
        check(samples.count == jobs.count, "造出 \(samples.count)/\(jobs.count) 个样片")
        // 外挂字幕：简体用 GB18030 编码（老字幕站常见），英文用 UTF-8；还有一个放在 Subs 子文件夹
        // 外挂字幕：简体用 GB18030、繁体用 Big5（老字幕站常见），英文用 UTF-8；还有一个放在 Subs 子文件夹
        func enc(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        let lines = ["你好，世界", "今天的天气真不错，我们去公园走走吧。", "你昨天晚上为什么没有回我的消息？", "这件事情我们明天再讨论，先休息一下。",
                     "他说的那些话，我一个字都不相信。", "快点上车，电影马上就要开始了！", "我从来没有想过会在这里遇见你。",
                     "如果当初我们没有分开，现在会是什么样子？", "别担心，一切都会好起来的。", "谢谢你一直陪在我身边。"]
        func srt(_ ls: [String]) -> String {
            var out = ""
            for i in 0..<36 {
                let a = 0.5 + Double(i) * 3, b = a + 2.8
                func ts(_ x: Double) -> String { String(format: "00:%02d:%02d,%03d", Int(x) / 60, Int(x) % 60, Int((x - x.rounded(.down)) * 1000)) }
                out += "\(i + 1)\n\(ts(a)) --> \(ts(b))\n\(ls[i % ls.count])\n\n"
            }
            return out
        }
        try? srt(lines).data(using: enc(.GB_18030_2000))?.write(to: dir.appendingPathComponent("测试 第1集.chs.srt"))
        let trad = lines.map { $0.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? $0 }
        try? srt(trad).data(using: enc(.big5))?.write(to: dir.appendingPathComponent("测试 第10集.cht.srt"))
        try? srt(["Hello world"]).write(to: dir.appendingPathComponent("测试 第1集.eng.srt"), atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Subs"), withIntermediateDirectories: true)
        try? "[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize\nStyle: Default,PingFang SC,40\n\n[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:00.50,0:00:03.50,Default,日文字幕\n"
            .write(to: dir.appendingPathComponent("Subs/测试 第2集.jpn.ass"), atomically: true, encoding: .utf8)
        let list = Media.siblings(of: dir.appendingPathComponent("测试 第2集.mkv")).map { $0.lastPathComponent }.filter { $0.hasPrefix("测试") }
        check(Array(list.prefix(3)) == ["测试 第1集.mkv", "测试 第2集.mkv", "测试 第10集.mp4"], "同文件夹连播顺序：\(list.prefix(3).joined(separator: "、"))")
    }

    // MARK: 缩略图

    static func testThumbs(_ dir: URL) {
        for (name, url) in samples.sorted(by: { $0.key < $1.key }) {
            var info = fy_info()
            let r = fy_probe(url.path, &info)
            let cg = Thumbnails.frame(url.path, seconds: 2, fraction: -1, maxW: 320, maxH: 180, keyframeOnly: false)
            check(r == 0 && abs(info.duration - 4) < 0.3 && cg != nil && (cg!.width <= 320 && cg!.height <= 180),
                  "\(name)：时长 \(String(format: "%.2f", info.duration)) 秒，缩略图 \(cg.map { "\($0.width)×\($0.height)" } ?? "无")")
            if name == "竖屏.mp4" {
                check(info.width == 360 && info.height == 640 && (cg?.height ?? 0) > (cg?.width ?? 0), "竖屏片按旋转后的方向读尺寸和出图")
            }
        }
        let start = Date()
        for _ in 0..<5 { _ = Thumbnails.frame(samples["测试 第10集.mp4"]!.path, seconds: 3, fraction: -1, maxW: 320, maxH: 180, keyframeOnly: true) }
        let ms = Date().timeIntervalSince(start) / 5 * 1000
        check(ms < 150, "悬停预览一张 \(Int(ms)) 毫秒")
    }

    // MARK: mpv 读取

    static func spin(until timeout: TimeInterval, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    static func headlessMPV() -> MPV {
        MPV(options: Player.options.filter { $0.0 != "vo" } + [("vo", "null"), ("ao", "null"), ("pause", "yes")])
    }

    static func testMPV(_ dir: URL) {
        let mpv = headlessMPV()
        var loaded = false, failed = false
        mpv.onEvent = { e in
            switch e {
            case .fileLoaded: loaded = true
            case .endFile(let reason, _): if reason == MPV_END_FILE_REASON_ERROR { failed = true }
            default: break
            }
        }
        func load(_ url: URL) -> Bool {
            loaded = false; failed = false
            mpv.command(["loadfile", url.path, "replace"])
            return spin(until: 8) { loaded || failed } && loaded
        }
        func tracks() -> [Track] { (mpv.node("track-list") as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(Track.init) } }

        for (name, url) in samples.sorted(by: { $0.key < $1.key }) {
            let ok = load(url)
            let d = mpv.double("duration") ?? 0
            let t = tracks()
            check(ok && abs(d - 4) < 0.3 && t.contains { $0.type == "video" } && t.contains { $0.type == "audio" },
                  "\(name)：能放，\(String(format: "%.2f", d)) 秒，\(t.filter { $0.type == "video" }.first.map { Track.codecName($0.codec ?? "") } ?? "无画面")")
        }

        if let ep1 = samples["测试 第1集.mkv"], load(ep1) {
            let subs = tracks().filter { $0.type == "sub" }
            check(subs.filter { $0.external }.count == 2, "自动加载同名字幕 \(subs.count) 条")
            let best = subs.max { ($0.guess(videoBaseName: "测试 第1集")?.rank ?? 0) < ($1.guess(videoBaseName: "测试 第1集")?.rank ?? 0) }
            check(best?.externalFilename?.contains(".chs.") == true, "按文件名挑中简体中文")
            check(best?.displayName(videoBaseName: "测试 第1集") == "简体中文 · SRT · 外挂", "字幕名字：\(best?.displayName(videoBaseName: "测试 第1集") ?? "无")")
            if let best { mpv.set("sid", String(best.id)) }
            mpv.command(["seek", "1.5", "absolute+exact"])
            let text = { mpv.string("sub-text") ?? "" }
            _ = spin(until: 3) { text() == "你好，世界" }
            check(text() == "你好，世界", "GB18030 编码的字幕认得出：「\(text())」")
            let chapters = mpv.node("chapter-list") as? [Any] ?? []
            check(chapters.count == 2, "读到 \(chapters.count) 个章节")
        }
        if let ep10 = samples["测试 第10集.mp4"], load(ep10) {
            let sub = tracks().first { $0.type == "sub" }
            check(sub?.displayName(videoBaseName: "测试 第10集") == "繁体中文 · SRT · 外挂", "繁体字幕名字：\(sub?.displayName(videoBaseName: "测试 第10集") ?? "无")")
            if let sub { mpv.set("sid", String(sub.id)) }
            mpv.command(["seek", "3.6", "absolute+exact"])
            let text = { mpv.string("sub-text") ?? "" }
            _ = spin(until: 3) { text().hasPrefix("今天的天氣") }
            check(text().hasPrefix("今天的天氣"), "Big5 编码的字幕认得出：「\(text())」")
        }
        if let ep2 = samples["测试 第2集.mkv"], load(ep2) {
            let subs = tracks().filter { $0.type == "sub" }
            check(subs.contains { $0.externalFilename?.contains("/Subs/") == true }, "Subs 子文件夹里的字幕也加载")
        }
        if let rot = samples["竖屏.mp4"], load(rot) {
            _ = spin(until: 3) { mpv.node("video-params") != nil }
            let p = mpv.node("video-params") as? [String: Any] ?? [:]
            let rotate = p["rotate"] as? Int64 ?? 0
            let w = p["dw"] as? Int64 ?? 0, h = p["dh"] as? Int64 ?? 0
            let shown = rotate % 180 == 90 ? (h, w) : (w, h)
            check(shown == (360, 640), "竖屏片按 360×640 显示（rotate=\(rotate), dw×dh=\(w)×\(h)）")
        }
        if let hdr = samples["HDR.mp4"], load(hdr) {
            _ = spin(until: 3) { mpv.node("video-params") != nil }
            let p = mpv.node("video-params") as? [String: Any] ?? [:]
            check(p["gamma"] as? String == "pq", "认出 HDR（gamma=\(p["gamma"] as? String ?? "?")）")
        }
        mpv.destroy()

        // 真能出声：用真实声卡（音量 0）放一个 AAC 片子，音频输出必须是 CoreAudio 起来了
        let real = MPV(options: Player.options.filter { $0.0 != "vo" } + [("vo", "null"), ("volume", "0"), ("pause", "no")])
        var playing = false
        real.onEvent = { if case .playbackRestart = $0 { playing = true } }
        if let ep1 = samples["测试 第1集.mkv"] {
            real.command(["loadfile", ep1.path, "replace"])
            _ = spin(until: 6) { playing && real.string("current-ao") != nil }
            // 退回 AVFoundation 也能出声，但调音量要等 2 秒，单独提示
            let ao = real.string("current-ao") ?? "无"
            check(ao != "无", "音频输出起来了：\(ao)")
            if ao != "coreaudio", ao != "无" { print("    注意：CoreAudio 没起来，退回了 \(ao)，调音量会有延迟") }
        }
        real.destroy()
    }

    // MARK: 离屏渲染：和窗口里同一条 OpenGL 路径

    static func testRender(_ dir: URL) {
        guard let url = samples["测试 第1集.mkv"] else { check(false, "没有样片"); return }
        let attrs: [CGLPixelFormatAttribute] = [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
                                                kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, CGLPixelFormatAttribute(0)]
        var pf: CGLPixelFormatObj?
        var n: GLint = 0
        CGLChoosePixelFormat(attrs, &pf, &n)
        var ctx: CGLContextObj?
        guard let pf else { check(false, "OpenGL 像素格式"); return }
        CGLCreateContext(pf, nil, &ctx)
        guard let ctx else { check(false, "OpenGL 上下文"); return }
        CGLSetCurrentContext(ctx)
        let W: GLsizei = 320, H: GLsizei = 180
        var tex: GLuint = 0, fbo: GLuint = 0
        glGenTextures(1, &tex)
        glBindTexture(GLenum(GL_TEXTURE_2D), tex)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, W, H, 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), tex, 0)
        check(glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE), "建好离屏画布")

        let mpv = MPV(options: Player.options + [("ao", "null")])
        var loaded = false
        mpv.onEvent = { if case .fileLoaded = $0 { loaded = true } }
        let ok = mpv.createRenderContext(updateCallback: { _ in }, context: UnsafeMutableRawPointer(bitPattern: 1)!)
        check(ok, "mpv 渲染上下文（OpenGL）")
        mpv.command(["loadfile", url.path, "replace", "-1", "start=1"])
        _ = spin(until: 8) { loaded }
        mpv.set("pause", true)
        var rendered = 0
        var pixels = [UInt8](repeating: 0, count: Int(W * H * 4))
        var avg = 0.0, distinct = Set<UInt32>()
        func measure() {
            glFinish()
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
            glReadPixels(0, 0, W, H, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixels)
            var sum = 0
            distinct = []
            for i in stride(from: 0, to: pixels.count, by: 4 * 37) {
                sum += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                distinct.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
            }
            avg = Double(sum) / Double(pixels.count / (4 * 37) * 3)
        }
        _ = spin(until: 6) {
            if mpv.renderUpdateWantsFrame() {
                mpv.render(fbo: Int32(fbo), width: Int32(W), height: Int32(H), flip: false)
                mpv.reportSwap()
                rendered += 1
                measure()
            }
            return avg > 30
        }
        print("    硬件解码：\(mpv.string("hwdec-current") ?? "?")，平均亮度 \(Int(avg))")
        if avg <= 30 {
            mpv.set("hwdec", "no")
            mpv.command(["seek", "2", "absolute+exact"])
            _ = spin(until: 4) {
                if mpv.renderUpdateWantsFrame() {
                    mpv.render(fbo: Int32(fbo), width: Int32(W), height: Int32(H), flip: false)
                    mpv.reportSwap()
                    rendered += 1
                    measure()
                }
                return avg > 30
            }
            print("    软件解码再试：平均亮度 \(Int(avg))")
        }
        check(rendered > 0 && avg > 30 && distinct.count > 20, "画出了画面（\(rendered) 帧，平均亮度 \(Int(avg))，\(distinct.count) 种颜色）")

        // 停留画面用的截图
        // mpv 截图要渲染线程配合（和应用里一样放到后台线程去等，这里主线程继续推渲染）
        var shot: [String: Any]?
        var shotDone = false
        DispatchQueue.global().async {
            let r = mpv.commandNode(["screenshot-raw", "video", "bgra"]) as? [String: Any]
            DispatchQueue.main.async { shot = r; shotDone = true }
        }
        _ = spin(until: 5) {
            if mpv.renderUpdateWantsFrame() { mpv.render(fbo: Int32(fbo), width: Int32(W), height: Int32(H), flip: false) }
            return shotDone
        }
        check((shot?["w"] as? Int64) == 640 && (shot?["data"] as? Data)?.isEmpty == false, "截取当前画面 \(shot?["w"] ?? 0)×\(shot?["h"] ?? 0)")

        mpv.freeRenderContext()
        mpv.destroy()
        CGLSetCurrentContext(nil)
        CGLDestroyContext(ctx)
    }

    // MARK: 打包后的检查

    static func bundleCheck() -> Int32 {
        print("【bundle】")
        check(mpv_client_api_version() >= 0x20005, "libmpv 加载成功（接口 \(mpv_client_api_version() >> 16).\(mpv_client_api_version() & 0xffff)）")
        var info = fy_info()
        check(fy_probe("/不存在.mkv", &info) < 0, "FFmpeg 加载成功")
        let mpv = headlessMPV()
        check(mpv.string("mpv-version")?.hasPrefix("mpv") == true, "mpv 能初始化：\(mpv.string("mpv-version") ?? "?")")
        mpv.destroy()
        return failures == 0 ? 0 : 1
    }
}
