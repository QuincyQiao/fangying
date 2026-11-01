import Foundation
import UniformTypeIdentifiers

enum Media {
    static let videoExts: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "mk3d", "webm", "avi", "divx", "xvid", "wmv", "asf", "flv", "f4v",
        "rmvb", "rm", "ts", "m2ts", "mts", "tp", "trp", "m2t", "mpg", "mpeg", "mpe", "m1v", "m2v", "vob",
        "ogv", "ogm", "3gp", "3g2", "dv", "mxf", "hevc", "h264", "264", "265", "y4m", "amv", "nut", "wtv",
    ]
    static let audioExts: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "ogg", "oga", "opus", "wma", "ape",
        "wv", "dsf", "dff", "mka", "ac3", "eac3", "dts", "tta", "caf",
    ]
    static let subtitleExts: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "sami", "ttml", "lrc"]

    enum Kind { case video, audio, subtitle, folder, other }

    static func kind(of url: URL) -> Kind {
        var isDir: ObjCBool = false
        if url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url.pathExtension.lowercased() == "app" ? .other : .folder
        }
        let ext = url.pathExtension.lowercased()
        if videoExts.contains(ext) { return .video }
        if audioExts.contains(ext) { return .audio }
        if subtitleExts.contains(ext) { return .subtitle }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        return .other
    }

    static func isPlayable(_ url: URL) -> Bool {
        let k = kind(of: url)
        return k == .video || k == .audio
    }

    /// 按访达的方式排序：「第2集」排在「第10集」前面。
    static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func contents(of folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return items
    }

    /// 打开一个文件时，同文件夹里同类（视频或音频）的文件按顺序组成播放列表。
    static func siblings(of url: URL) -> [URL] {
        let me = normalized(url)
        let k = kind(of: me)
        let list = sorted(contents(of: me.deletingLastPathComponent()).map(normalized).filter { kind(of: $0) == k })
        return list.contains(me) ? list : sorted(list + [me])
    }

    /// 同一个文件可能有 /var 和 /private/var、带不带 .. 几种写法，比较前统一一下。
    static func normalized(_ url: URL) -> URL {
        url.isFileURL ? URL(fileURLWithPath: url.resolvingSymlinksInPath().standardizedFileURL.path) : url
    }

    /// 打开文件夹：先看这一层；这一层没有视频就往下找（按相对路径排序）。
    static func playable(inFolder folder: URL) -> [URL] {
        let top = contents(of: folder)
        let videos = top.filter { kind(of: $0) == .video }
        if !videos.isEmpty { return sorted(videos) }
        let audios = top.filter { kind(of: $0) == .audio }
        if !audios.isEmpty { return sorted(audios) }
        var found: [URL] = []
        if let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let u as URL in e where kind(of: u) == .video { found.append(u) }
        }
        let base = folder.standardizedFileURL.path
        return found.sorted {
            let a = String($0.standardizedFileURL.path.dropFirst(base.count))
            let b = String($1.standardizedFileURL.path.dropFirst(base.count))
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// 打开方式里一次选了多个文件或文件夹时，组成一个播放列表。
    static func playlist(for urls: [URL]) -> (items: [URL], start: Int) {
        let files = urls.filter { isPlayable($0) }
        let folders = urls.filter { kind(of: $0) == .folder }
        if urls.count == 1, let only = files.first {
            let list = siblings(of: only)
            return (list, list.firstIndex(of: normalized(only)) ?? 0)
        }
        var items = sorted(files.map(normalized))
        for f in folders { items += playable(inFolder: f) }
        return (items, 0)
    }

    static func title(of url: URL) -> String {
        url.isFileURL || isRemote(url) ? url.deletingPathExtension().lastPathComponent : (url.host ?? url.absoluteString)
    }

    // MARK: 远程文件

    static func isRemote(_ url: URL) -> Bool { url.scheme == "ssh" }

    static func remoteURL(host: String, path: String) -> URL {
        var c = URLComponents()
        c.scheme = "ssh"
        c.host = host
        c.path = path
        return c.url ?? URL(fileURLWithPath: path)
    }

    /// 观看记录和缓存用的键：本地是路径，远程是整个地址。
    static func key(_ url: URL) -> String { url.isFileURL ? url.path : url.absoluteString }
    static func url(forKey key: String) -> URL {
        key.hasPrefix("ssh://") ? (URL(string: key) ?? URL(fileURLWithPath: key)) : URL(fileURLWithPath: key)
    }

    /// 交给 mpv 和 FFmpeg 打开的地址。
    static func playbackTarget(_ url: URL) -> String {
        if url.isFileURL { return url.path }
        return isRemote(url) ? RemoteBridge.shared.url(for: url) : url.absoluteString
    }
}

func formatTime(_ seconds: Double, likeDuration ref: Double = 0) -> String {
    guard seconds.isFinite else { return "--:--" }
    let s = Int(max(0, seconds).rounded(.down))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 || ref >= 3600 { return String(format: "%d:%02d:%02d", h, m, sec) }
    return String(format: "%d:%02d", m, sec)
}

/// 「3 分钟前」「昨天」「10月12日」
func relativeDay(_ date: Date) -> String {
    let now = Date()
    let diff = now.timeIntervalSince(date)
    if diff < 60 { return "刚刚" }
    if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "\(Int(diff / 3600)) 小时前" }
    if cal.isDateInYesterday(date) { return "昨天" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = cal.isDate(date, equalTo: now, toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
    return f.string(from: date)
}

/// 轨道语言码换成中文名。
func languageName(_ code: String?) -> String? {
    guard let raw = code?.lowercased(), !raw.isEmpty, raw != "und" else { return nil }
    let map: [String: String] = [
        "chs": "简体中文", "sc": "简体中文", "zh-hans": "简体中文", "zh-cn": "简体中文", "zh-sg": "简体中文", "gb": "简体中文",
        "cht": "繁体中文", "tc": "繁体中文", "zh-hant": "繁体中文", "zh-tw": "繁体中文", "zh-hk": "繁体中文", "big5": "繁体中文",
        "chi": "中文", "zho": "中文", "zh": "中文", "chn": "中文", "cn": "中文", "cmn": "普通话", "yue": "粤语",
        "eng": "英语", "en": "英语", "jpn": "日语", "ja": "日语", "jp": "日语", "kor": "韩语", "ko": "韩语",
        "fre": "法语", "fra": "法语", "fr": "法语", "ger": "德语", "deu": "德语", "de": "德语", "spa": "西班牙语", "es": "西班牙语",
        "rus": "俄语", "ru": "俄语", "ita": "意大利语", "it": "意大利语", "por": "葡萄牙语", "pt": "葡萄牙语", "tha": "泰语", "th": "泰语",
        "vie": "越南语", "vi": "越南语", "ara": "阿拉伯语", "ar": "阿拉伯语", "hin": "印地语", "hi": "印地语",
        "chs_eng": "简英双语", "cht_eng": "繁英双语", "chs_jpn": "简日双语", "cht_jpn": "繁日双语",
    ]
    if let name = map[raw] { return name }
    if let name = map[raw.replacingOccurrences(of: "&", with: "_").replacingOccurrences(of: "-", with: "_")] { return name }
    if let name = Locale(identifier: "zh_CN").localizedString(forLanguageCode: raw) { return name }
    return raw
}
