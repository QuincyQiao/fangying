import AppKit
import IOKit.pwr_mgt
import MediaPlayer

struct Track: Equatable {
    let id: Int
    let type: String          // video / audio / sub
    let title: String?
    let lang: String?
    let codec: String?
    let external: Bool
    let externalFilename: String?
    let selected: Bool
    let isDefault: Bool
    let forced: Bool
    let channels: Int?
    let albumArt: Bool

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? Int64, let type = dict["type"] as? String else { return nil }
        self.id = Int(id)
        self.type = type
        title = dict["title"] as? String
        lang = dict["lang"] as? String
        codec = dict["codec"] as? String
        external = dict["external"] as? Bool ?? false
        externalFilename = dict["external-filename"] as? String
        selected = dict["selected"] as? Bool ?? false
        isDefault = dict["default"] as? Bool ?? false
        forced = dict["forced"] as? Bool ?? false
        channels = (dict["demux-channel-count"] as? Int64).map(Int.init) ?? (dict["audio-channels"] as? Int64).map(Int.init)
        albumArt = dict["albumart"] as? Bool ?? false
    }

    /// 外挂字幕的文件名。远程字幕是转接地址，里面的中文是转义过的
    private var externalName: String? {
        guard let f = externalFilename else { return nil }
        return f.hasPrefix("http") ? (f.removingPercentEncoding ?? f) : f
    }

    /// 外挂字幕文件名里视频名后面那一截，比如「电影.chs&eng.ass」里的「chs&eng」。
    func externalHint(videoBaseName: String?) -> String? {
        guard external, let name = externalName else { return nil }
        var stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        if let base = videoBaseName, stem.hasPrefix(base) { stem = String(stem.dropFirst(base.count)) }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ". _-[]()"))
        return stem.isEmpty ? nil : stem
    }

    /// 从语言码、标题、文件名猜字幕语言，rank 越大越优先（简体 > 简英双语 > 中文 > 繁体 > 英语）。
    func guess(videoBaseName: String?) -> (name: String, rank: Int)? {
        Track.guessLanguage([lang, title, externalHint(videoBaseName: videoBaseName)].compactMap { $0 }.joined(separator: " "))
    }

    static func guessLanguage(_ text: String) -> (name: String, rank: Int)? {
        let lower = text.lowercased()
        let tokens = Set(lower.components(separatedBy: CharacterSet(charactersIn: " ._-&+[](),/\\|")).filter { !$0.isEmpty })
        func any(_ set: Set<String>) -> Bool { !tokens.isDisjoint(with: set) }
        let simp = any(["chs", "sc", "gb", "zhs", "hans", "zh-hans", "zh-cn", "cn", "simplified", "简体", "简中", "简体中文"]) || lower.contains("简")
        let trad = any(["cht", "tc", "big5", "zht", "hant", "zh-tw", "zh-hk", "tw", "hk", "traditional", "繁体", "繁體", "繁中"]) || lower.contains("繁")
        let zh = simp || trad || any(["chi", "zho", "zh", "chn", "chinese", "中文", "中字"]) || lower.contains("中")
        let en = any(["en", "eng", "english"]) || lower.contains("英")
        let ja = any(["ja", "jpn", "jp", "japanese"]) || lower.contains("日")
        let other = en ? "英" : "日"
        if simp && (en || ja) { return ("简\(other)双语", 95) }
        if trad && (en || ja) { return ("繁\(other)双语", 68) }
        if simp { return ("简体中文", 100) }
        if trad { return ("繁体中文", 70) }
        if zh && (en || ja) { return ("中\(other)双语", 92) }
        if zh { return ("中文", 90) }
        if en { return ("英语", 40) }
        if ja { return ("日语", 30) }
        return nil
    }

    /// 菜单里显示的名字，例如「简体中文 · ASS · 外挂」。
    func displayName(videoBaseName: String?) -> String {
        let g = guess(videoBaseName: videoBaseName)
        var name: String
        let t = title?.trimmingCharacters(in: .whitespaces) ?? ""
        if external {
            name = g?.name ?? externalHint(videoBaseName: videoBaseName) ?? URL(fileURLWithPath: externalName ?? "").lastPathComponent
        } else if !t.isEmpty {
            // 「CHS」「chs&eng」这类代号换成中文名；写成句子的标题照原样
            let codeLike = t.count <= 12 && t.unicodeScalars.allSatisfy { $0.isASCII } && !t.contains(" ")
            name = codeLike ? (g?.name ?? t) : t
            if let l = languageName(lang), !codeLike, !name.contains(l), Track.guessLanguage(t) == nil { name += " · \(l)" }
        } else {
            name = g?.name ?? languageName(lang) ?? (type == "sub" ? "字幕 \(id)" : type == "audio" ? "音轨 \(id)" : "画面 \(id)")
        }
        var parts = [name]
        if let c = codec { parts.append(Track.codecName(c)) }
        if type == "audio", let ch = channels {
            parts.append(ch == 1 ? "单声道" : ch == 2 ? "立体声" : ch == 6 ? "5.1" : ch == 8 ? "7.1" : "\(ch) 声道")
        }
        if external { parts.append("外挂") }
        if forced { parts.append("强制") }
        return parts.joined(separator: " · ")
    }

    static func codecName(_ c: String) -> String {
        let map = ["subrip": "SRT", "ass": "ASS", "ssa": "SSA", "hdmv_pgs_subtitle": "PGS", "dvd_subtitle": "VobSub",
                   "webvtt": "VTT", "mov_text": "文本", "dvb_subtitle": "DVB", "aac": "AAC", "ac3": "AC-3",
                   "eac3": "E-AC-3", "dts": "DTS", "truehd": "TrueHD", "flac": "FLAC", "opus": "Opus", "mp3": "MP3",
                   "vorbis": "Vorbis", "alac": "ALAC", "h264": "H.264", "hevc": "HEVC", "av1": "AV1", "vp9": "VP9"]
        if let n = map[c] { return n }
        if c.hasPrefix("pcm") { return "PCM" }
        return c.uppercased()
    }
}

/// 播放核心：管 mpv、播放列表、观看记录、正在播放信息、防睡眠。界面通过 onChange 收变化。
final class Player {
    enum Change { case file, playlist, position, pause, duration, volume, speed, tracks, video, chapters, subtitle, idle, buffering, cache, ended, error(String), resumed(Double) }

    let mpv: MPV
    var onChange: ((Change) -> Void)?

    private(set) var playlist: [URL] = []
    private(set) var index = -1
    var current: URL? { playlist.indices.contains(index) ? playlist[index] : nil }
    var hasNext: Bool { index + 1 < playlist.count }
    var hasPrevious: Bool { index > 0 }

    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = true
    private(set) var volume: Double = 100
    private(set) var muted = false
    private(set) var speed: Double = 1
    private(set) var tracks: [Track] = []
    private(set) var chapters: [(title: String, time: Double)] = []
    private(set) var videoSize: CGSize?
    private(set) var isHDR = false
    private(set) var idle = true
    private(set) var loading = false
    private(set) var buffering = false
    private(set) var cacheTime: Double?
    private(set) var eofReached = false
    private(set) var subScale = 1.0
    private(set) var subPos = 100.0
    private(set) var subDelay = 0.0

    var hasVideo: Bool { tracks.contains { $0.type == "video" && $0.selected && !$0.albumArt } }
    var title: String { current.map(Media.title(of:)) ?? "放映" }

    private var lastHistoryWrite = Date.distantPast
    private var lastSnapshot: [String: Date] = [:]
    private var sleepAssertion: IOPMAssertionID = 0
    private var pendingResume: Double?
    private var remoteSubtitles: [URL] = []
    private var addedSubtitles: Set<URL> = []
    private let snapshotQueue = DispatchQueue(label: "local.fangying.snapshot", qos: .utility)

    static let defaultsVolume = "音量"
    static let defaultsSubScale = "字幕大小"
    static let defaultsSubPos = "字幕位置"

    init() {
        let d = UserDefaults.standard
        volume = d.object(forKey: Player.defaultsVolume) as? Double ?? 100
        subScale = d.object(forKey: Player.defaultsSubScale) as? Double ?? 1
        subPos = d.object(forKey: Player.defaultsSubPos) as? Double ?? 100
        mpv = MPV(options: Player.options + [
            ("volume", String(volume)), ("sub-scale", String(subScale)), ("sub-pos", String(subPos)),
        ])
        let observed: [(String, mpv_format)] = [
            ("pause", MPV_FORMAT_FLAG), ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
            ("volume", MPV_FORMAT_DOUBLE), ("mute", MPV_FORMAT_FLAG), ("speed", MPV_FORMAT_DOUBLE),
            ("track-list", MPV_FORMAT_NODE), ("video-params", MPV_FORMAT_NODE), ("chapter-list", MPV_FORMAT_NODE),
            ("eof-reached", MPV_FORMAT_FLAG), ("idle-active", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG),
            ("demuxer-cache-time", MPV_FORMAT_DOUBLE), ("sub-scale", MPV_FORMAT_DOUBLE), ("sub-pos", MPV_FORMAT_DOUBLE),
            ("sub-delay", MPV_FORMAT_DOUBLE), ("sid", MPV_FORMAT_STRING), ("secondary-sid", MPV_FORMAT_STRING),
            ("aid", MPV_FORMAT_STRING),
        ]
        for (name, format) in observed { mpv.observe(name, format) }
        mpv.onEvent = { [weak self] in self?.handle($0) }
        setupRemoteCommands()
    }

    static let options: [(String, String)] = [
        ("vo", "libmpv"), ("hwdec", "auto-safe"), ("profile", "high-quality"),
        // 音频走 CoreAudio：设备缓冲约 50 毫秒。AVFoundation 输出自带 2 秒缓冲，软件音量要等 2 秒才生效，只作退路。
        // 一些 DisplayPort 显示器上，mpv 默认把 AAC 解成分声道浮点（floatp）交给 CoreAudio、或者请求单声道布局，
        // 都会初始化失败（设声道布局报 -50）然后没声音。改成交错浮点、声道只在立体声/5.1/7.1 里挑（单声道升成立体声），音质不变。
        // 软件音量和倍速在 audio-buffer 之前生效，所以缓冲也从默认 0.2 秒降到 0.06 秒
        ("ao", "coreaudio,avfoundation"), ("audio-format", "float"), ("audio-channels", "stereo,5.1,7.1"), ("audio-buffer", "0.06"),
        // mpv 自带的统计、控制台、右键菜单等脚本用不上
        ("load-stats-overlay", "no"), ("load-console", "no"), ("load-commands", "no"), ("load-auto-profiles", "no"),
        ("load-select", "no"), ("load-context-menu", "no"), ("load-positioning", "no"),
        ("config", "no"), ("load-scripts", "no"), ("osc", "no"), ("ytdl", "no"), ("terminal", ProcessInfo.processInfo.environment["FANGYING_MPV_LOG"] == nil ? "no" : "yes"),
        ("input-default-bindings", "no"), ("input-vo-keyboard", "no"), ("input-media-keys", "no"),
        ("msg-level", ProcessInfo.processInfo.environment["FANGYING_MPV_LOG"] ?? "all=error"), ("idle", "yes"), ("keep-open", "yes"), ("stop-screensaver", "no"),
        ("audio-client-name", "放映"), ("volume-max", "150"), ("target-prim", "display-p3"),
        ("demuxer-max-bytes", "400MiB"), ("demuxer-max-back-bytes", "150MiB"),
        ("reset-on-next-file", "sub-delay,audio-delay"),
        // 字幕：同名、带语言后缀、放在 Subs/字幕 子文件夹里的都自动加载，优先中文
        ("sub-auto", "fuzzy"), ("sub-file-paths", "sub:subs:Sub:Subs:SUBS:subtitle:subtitles:Subtitles:字幕"),
        ("slang", "zh-Hans,zh-CN,chs,sc,zh,chi,zho,chn,cht,tc,zh-Hant,zh-TW,zh-HK,en,eng"),
        ("sub-font", "PingFang SC"), ("sub-font-size", "44"), ("sub-color", "#FFFFFF"),
        ("sub-outline-size", "2.2"), ("sub-outline-color", "#D9000000"),
        ("sub-shadow-offset", "1.2"), ("sub-shadow-color", "#73000000"), ("sub-margin-y", "36"),
        ("secondary-sub-pos", "8"),
    ]

    // MARK: 打开与切换

    func open(_ urls: [URL]) {
        let (items, start) = Media.playlist(for: urls)
        guard !items.isEmpty else { return }
        playlist = items
        remoteSubtitles = []
        play(at: start)
        if let url = current, Media.isRemote(url), items.count == 1 { loadRemoteNeighbours(of: url) }
    }

    /// 远程文件的同文件夹列表要走网络，先放起来，列表回来再补上连播和字幕。
    private func loadRemoteNeighbours(of url: URL) {
        Remote.shared.neighbours(of: url) { [weak self] list, subtitles in
            guard let self, self.current == url else { return }
            self.remoteSubtitles = subtitles
            if let i = list.firstIndex(of: url) {
                self.playlist = list
                self.index = i
                self.onChange?(.playlist)
            }
            self.addRemoteSubtitles()
        }
    }

    /// mpv 的 sub-auto 只看本地文件夹，远程的字幕这里自己加。要等片子打开之后。
    private func addRemoteSubtitles() {
        guard let url = current, Media.isRemote(url), !loading else { return }
        let subs = Remote.subtitles(for: url, in: remoteSubtitles).filter { !addedSubtitles.contains($0) }
        guard !subs.isEmpty else { return }
        addedSubtitles.formUnion(subs)
        DispatchQueue.global(qos: .userInitiated).async { [weak self, mpv] in
            for s in subs { mpv.command(["sub-add", Media.playbackTarget(s), "auto"]) }
            DispatchQueue.main.async {
                if self?.current == url { self?.chooseSubtitle() }
            }
        }
    }

    func play(at i: Int) {
        guard playlist.indices.contains(i) else { return }
        // 换片前同步截一张停留画面，异步的话会和换片抢
        saveProgress(snapshot: true, sync: true)
        index = i
        let url = playlist[i]
        eofReached = false
        position = 0
        let key = Media.key(url)
        duration = Thumbnails.shared.cachedDuration(for: url) ?? History.shared.record(for: key)?.duration ?? 0
        tracks = []
        chapters = []
        loading = true
        pendingResume = History.shared.record(for: key)?.resumePosition
        addedSubtitles = []
        var args = ["loadfile", Media.playbackTarget(url), "replace", "-1"]
        var opts: [String] = []
        if let r = pendingResume { opts.append("start=\(r)") }
        // 网络流 mpv 默认能缓存多少读多少，按流量计费时很浪费；提前 90 秒够了
        if Media.isRemote(url) { opts += ["cache=yes", "cache-secs=90", "network-timeout=\(Int(RemoteBridge.reconnectWait))"] }
        if !opts.isEmpty { args.append(opts.joined(separator: ",")) }
        mpv.command(args)
        mpv.set("pause", false)
        onChange?(.file)
    }

    func next() { if hasNext { play(at: index + 1) } }
    /// 放了 5 秒以上先回到开头，再按一次才是上一个。
    func previous() {
        if position > 5 || !hasPrevious { seek(to: 0); return }
        play(at: index - 1)
    }

    /// 某个时刻落在哪一章。
    static func chapterTitle(in chapters: [(title: String, time: Double)], at t: Double) -> String {
        chapters.last { $0.time <= t }?.title ?? ""
    }

    func removeFromPlaylist(at i: Int) {
        guard playlist.indices.contains(i), i != index else { return }
        playlist.remove(at: i)
        if i < index { index -= 1 }
        onChange?(.file)
    }

    func stop() {
        saveProgress(snapshot: true, sync: true)
        mpv.command(["stop"])
        playlist = []
        index = -1
        onChange?(.file)
    }

    // MARK: 播放控制

    func togglePause() {
        if idle, current == nil { return }
        if eofReached, paused {
            seek(to: 0)
            mpv.set("pause", false)
            return
        }
        mpv.set("pause", !paused)
    }

    func setPaused(_ p: Bool) { mpv.set("pause", p) }

    func seek(to t: Double, exact: Bool = true) {
        guard current != nil else { return }
        let target = duration > 0 ? min(max(0, t), duration) : max(0, t)
        position = target
        mpv.commandAsync(["seek", String(target), exact ? "absolute+exact" : "absolute+keyframes"])
        onChange?(.position)
    }

    func seek(by delta: Double) {
        guard current != nil else { return }
        let base = position
        seek(to: base + delta, exact: abs(delta) < 15)
    }

    func frameStep(forward: Bool) {
        mpv.command([forward ? "frame-step" : "frame-back-step"])
    }

    /// 界面先按新音量刷新，再异步交给 mpv，不等它回话。
    func setVolume(_ v: Double) {
        let nv = (min(150, max(0, v)) * 10).rounded() / 10
        volume = nv
        mpv.setAsync("volume", nv)
        if muted, nv > 0 {
            muted = false
            mpv.setAsync("mute", false)
        }
        UserDefaults.standard.set(nv, forKey: Player.defaultsVolume)
        onChange?(.volume)
    }

    func toggleMute() {
        muted.toggle()
        mpv.setAsync("mute", muted)
        onChange?(.volume)
    }

    func setSpeed(_ s: Double) { mpv.set("speed", min(4, max(0.25, (s * 100).rounded() / 100))) }

    func selectTrack(type: String, id: Int?) {
        let prop = type == "audio" ? "aid" : type == "secondary" ? "secondary-sid" : "sid"
        mpv.set(prop, id.map(String.init) ?? "no")
    }

    func addSubtitle(_ url: URL) {
        mpv.command(["sub-add", url.path, "select"])
    }

    func setSubScale(_ v: Double) {
        let nv = min(2.5, max(0.4, (v * 100).rounded() / 100))
        mpv.set("sub-scale", nv)
        UserDefaults.standard.set(nv, forKey: Player.defaultsSubScale)
    }

    func setSubPos(_ v: Double) {
        let nv = min(110, max(40, v.rounded()))
        mpv.set("sub-pos", nv)
        UserDefaults.standard.set(nv, forKey: Player.defaultsSubPos)
    }

    func setSubDelay(_ v: Double) { mpv.set("sub-delay", (v * 10).rounded() / 10) }

    // MARK: mpv 事件

    private func handle(_ event: MPV.Event) {
        switch event {
        case .property(let name, let value):
            handleProperty(name, value)
        case .startFile:
            loading = true
        case .fileLoaded:
            loading = false
            idle = false
            if let d = mpv.double("duration"), d > 0 { duration = d }
            if let url = current { History.shared.started(path: Media.key(url), duration: duration) }
            chooseSubtitle()
            addRemoteSubtitles()
            if let r = pendingResume { onChange?(.resumed(r)) }
            pendingResume = nil
            updateNowPlaying()
            onChange?(.duration)
        case .endFile(let reason, let error):
            loading = false
            if reason == MPV_END_FILE_REASON_ERROR {
                let msg = String(cString: mpv_error_string(error))
                NSLog("播放失败：%@", msg)
                onChange?(.error(current.flatMap { Media.isRemote($0) ? $0.host : nil }.map { "放不了，可能连不上 \($0)" } ?? "这个文件放不了"))
            }
        case .playbackRestart:
            updateNowPlaying()
        case .videoReconfig, .shutdown:
            break
        }
    }

    private func handleProperty(_ name: String, _ value: Any?) {
        switch name {
        case "time-pos":
            guard let t = value as? Double else { return }
            position = t
            if Date().timeIntervalSince(lastHistoryWrite) > 5, !paused { saveProgress(snapshot: false) }
            onChange?(.position)
        case "pause":
            paused = value as? Bool ?? true
            updateSleepAssertion()
            updateNowPlaying()
            if paused { saveProgress(snapshot: true) }
            onChange?(.pause)
        case "duration":
            if let d = value as? Double, d > 0 { duration = d }
            onChange?(.duration)
        case "volume", "mute":
            break  // 音量以界面这边为准（setVolume 已经先改了），mpv 回报的旧值不再覆盖
        case "speed":
            speed = value as? Double ?? 1
            updateNowPlaying()
            onChange?(.speed)
        case "track-list":
            tracks = (value as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(Track.init) }
            updateSleepAssertion()
            onChange?(.tracks)
        case "sid", "aid", "secondary-sid":
            onChange?(.tracks)
        case "video-params":
            if let p = value as? [String: Any], let w = p["dw"] as? Int64, let h = p["dh"] as? Int64, w > 0, h > 0 {
                let rotate = (p["rotate"] as? Int64) ?? 0
                videoSize = rotate % 180 == 90 ? CGSize(width: Int(h), height: Int(w)) : CGSize(width: Int(w), height: Int(h))
                let gamma = p["gamma"] as? String ?? ""
                isHDR = ["pq", "hlg"].contains(gamma)
            } else {
                videoSize = nil
                isHDR = false
            }
            onChange?(.video)
        case "chapter-list":
            chapters = (value as? [Any] ?? []).compactMap {
                guard let d = $0 as? [String: Any], let t = d["time"] as? Double else { return nil }
                return (d["title"] as? String ?? "", t)
            }
            onChange?(.chapters)
        case "eof-reached":
            let eof = value as? Bool ?? false
            guard eof != eofReached else { return }
            eofReached = eof
            if eof { reachedEnd() }
        case "idle-active":
            idle = value as? Bool ?? true
            onChange?(.idle)
        case "paused-for-cache":
            buffering = value as? Bool ?? false
            onChange?(.buffering)
        case "demuxer-cache-time":
            cacheTime = value as? Double
            onChange?(.cache)
        case "sub-scale":
            subScale = value as? Double ?? subScale
            onChange?(.subtitle)
        case "sub-pos":
            subPos = value as? Double ?? subPos
            onChange?(.subtitle)
        case "sub-delay":
            subDelay = value as? Double ?? 0
            onChange?(.subtitle)
        default:
            break
        }
    }

    /// mpv 只认标准语言码，字幕站常见的 .chs / .简体 / chs&eng 它不认；这里按文件名再挑一次，中文优先。
    private func chooseSubtitle() {
        let all = (mpv.node("track-list") as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(Track.init) }
        let subs = all.filter { $0.type == "sub" }
        guard !subs.isEmpty else { return }
        let base = current.map(Media.title(of:))
        let ranked = subs.map { ($0, $0.guess(videoBaseName: base)?.rank ?? 0) }
        guard let best = ranked.max(by: { $0.1 < $1.1 }), best.1 >= 90 else { return }
        let selected = ranked.first { $0.0.selected }
        if selected == nil || selected!.1 < best.1 { mpv.set("sid", String(best.0.id)) }
    }

    private func reachedEnd() {
        guard let url = current else { return }
        if duration > 0 { position = duration }
        History.shared.update(path: Media.key(url), position: 0, duration: duration, finished: true)
        if hasNext {
            play(at: index + 1)
        } else {
            onChange?(.ended)
        }
    }

    // MARK: 观看记录

    func saveProgress(snapshot: Bool, sync: Bool = false) {
        guard let url = current, url.isFileURL || Media.isRemote(url), duration > 0, !loading else { return }
        lastHistoryWrite = Date()
        let key = Media.key(url)
        let remaining = duration - position
        let finished = eofReached || position / duration >= 0.95 || remaining < 10
        History.shared.update(path: key, position: position, duration: duration, finished: finished)
        guard snapshot, hasVideo else { return }
        if !sync, let last = lastSnapshot[key], Date().timeIntervalSince(last) < 10 { return }
        lastSnapshot[key] = Date()
        takeSnapshot(for: key, sync: sync)
    }

    func takeSnapshot(for path: String, sync: Bool) {
        let work = { [mpv] in
            let raw = mpv.commandNode(["screenshot-raw", "video", "bgra"])
            guard let node = raw as? [String: Any],
                  let w = node["w"] as? Int64, let h = node["h"] as? Int64, let stride = node["stride"] as? Int64,
                  let data = node["data"] as? Data, w > 0, h > 0, stride > 0 else {
                NSLog("停留画面截取失败：%@", String(describing: (raw as? [String: Any])?.filter { $0.key != "data" } ?? raw))
                return
            }
            let image: CGImage? = data.withUnsafeBytes { raw in
                Thumbnails.makeImage(bgra: raw.baseAddress!, width: Int(w), height: Int(h), stride: Int(stride))
            }
            if let image { Thumbnails.shared.saveSnapshot(image, for: path) }
            DispatchQueue.main.async { NotificationCenter.default.post(name: History.changed, object: nil) }
        }
        if sync { work() } else { snapshotQueue.async(execute: work) }
    }

    /// 退出前：记下进度和停留画面。
    func prepareToQuit() {
        if let url = current, url.isFileURL || Media.isRemote(url), duration > 0, !loading {
            let finished = eofReached || position / duration >= 0.95 || duration - position < 10
            History.shared.update(path: Media.key(url), position: position, duration: duration, finished: finished)
            if hasVideo { takeSnapshot(for: Media.key(url), sync: true) }
        }
        History.shared.save()
        releaseSleepAssertion()
    }

    // MARK: 防止播放时屏幕睡眠

    private func updateSleepAssertion() {
        if !paused, hasVideo {
            guard sleepAssertion == 0 else { return }
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "放映正在播放视频" as CFString, &sleepAssertion)
        } else {
            releaseSleepAssertion()
        }
    }

    private func releaseSleepAssertion() {
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: 键盘媒体键和控制中心

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePause(); return .success }
        c.playCommand.addTarget { [weak self] _ in self?.setPaused(false); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.setPaused(true); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.hasNext else { return .noSuchContent }
            self.next(); return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime); return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.seek(by: 10); return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.seek(by: -10); return .success }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard current != nil, !idle || loading else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        center.playbackState = paused ? .paused : .playing
    }
}
