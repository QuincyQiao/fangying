import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// 每个文件看到哪、看完没有。存在 ~/Library/Application Support/放映/观看记录.json，最近的在前。
struct WatchRecord: Codable, Equatable {
    var path: String
    var position: Double
    var duration: Double
    var finished: Bool
    var updated: Date

    var url: URL { URL(fileURLWithPath: path) }
    var progress: Double { duration > 0 ? min(1, position / duration) : 0 }
    /// 再打开时从这里接着放；看完了或只看了开头就从头放。
    var resumePosition: Double? {
        guard !finished, duration > 0, position > 10, position < duration - 15 else { return nil }
        return position
    }
}

final class History {
    static let shared = History()
    static let changed = Notification.Name("local.fangying.history-changed")

    private(set) var records: [WatchRecord] = []
    private let fileURL: URL
    private var saveScheduled = false
    private let limit = 300

    init(directory: URL = History.defaultDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("观看记录.json")
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = (try? decoder.decode([WatchRecord].self, from: data)) ?? []
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("放映")
    }

    func record(for path: String) -> WatchRecord? { records.first { $0.path == path } }

    func update(path: String, position: Double, duration: Double, finished: Bool, touch: Bool = true) {
        var r = record(for: path) ?? WatchRecord(path: path, position: 0, duration: 0, finished: false, updated: Date())
        r.position = finished ? 0 : position
        if duration > 0 { r.duration = duration }
        r.finished = finished || (r.finished && position < 1)
        if touch { r.updated = Date() }
        records.removeAll { $0.path == path }
        records.insert(r, at: 0)
        if records.count > limit { records.removeLast(records.count - limit) }
        changedSoon()
    }

    /// 开始看一个文件：之前看完的，这次重新算「没看完」。
    func started(path: String, duration: Double) {
        var r = record(for: path) ?? WatchRecord(path: path, position: 0, duration: duration, finished: false, updated: Date())
        if duration > 0 { r.duration = duration }
        r.finished = false
        r.updated = Date()
        records.removeAll { $0.path == path }
        records.insert(r, at: 0)
        changedSoon()
    }

    func remove(path: String) {
        records.removeAll { $0.path == path }
        Thumbnails.shared.removeSnapshot(for: path)
        changedSoon()
    }

    func clear() {
        for r in records { Thumbnails.shared.removeSnapshot(for: r.path) }
        records.removeAll()
        changedSoon()
    }

    private func changedSoon() {
        NotificationCenter.default.post(name: History.changed, object: self)
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.save() }
    }

    func save() {
        saveScheduled = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(records) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// 缩略图：列表里的封面（片子 10% 处）、最近看过的停留画面、进度条悬停预览。
final class Thumbnails {
    static let shared = Thumbnails()

    let directory: URL
    private let posters = NSCache<NSString, NSImage>()
    private var durations: [String: Double] = [:]
    private let lock = NSLock()
    private var pending: [String: [(NSImage?, Double?) -> Void]] = [:]
    private let posterQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()
    private let previewQueue = DispatchQueue(label: "local.fangying.preview", qos: .userInitiated)
    private var previewToken = 0

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.fangying")
        for sub in ["封面", "停留画面"] {
            try? FileManager.default.createDirectory(at: directory.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    static func key(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func posterKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = "\(values?.fileSize ?? 0)-\(Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
        return Thumbnails.key(url.path + "|" + stamp)
    }

    func cachedDuration(for url: URL) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return durations[url.path]
    }

    /// 列表封面和时长。完成回调在主线程。
    func poster(for url: URL, completion: @escaping (NSImage?, Double?) -> Void) {
        let memKey = url.path as NSString
        if let img = posters.object(forKey: memKey) {
            completion(img, cachedDuration(for: url))
            return
        }
        lock.lock()
        if pending[url.path] != nil {
            pending[url.path]!.append(completion)
            lock.unlock()
            return
        }
        pending[url.path] = [completion]
        lock.unlock()

        posterQueue.addOperation { [weak self] in
            guard let self else { return }
            let key = self.posterKey(for: url)
            let jpg = self.directory.appendingPathComponent("封面/\(key).jpg")
            let meta = self.directory.appendingPathComponent("封面/\(key).txt")
            var image: NSImage? = nil
            var duration: Double? = nil
            if let img = NSImage(contentsOf: jpg) {
                image = img
                duration = (try? String(contentsOf: meta, encoding: .utf8)).flatMap { Double($0) }
            } else if FileManager.default.fileExists(atPath: url.path) {
                var info = fy_info()
                if fy_probe(url.path, &info) >= 0 { duration = info.duration }
                let fraction = (duration ?? 0) > 30 ? 0.1 : 0.3
                if let cg = Thumbnails.frame(url.path, seconds: 0, fraction: fraction, maxW: 320, maxH: 180, keyframeOnly: true) {
                    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    Thumbnails.writeJPEG(cg, to: jpg)
                }
                try? String(duration ?? 0).write(to: meta, atomically: true, encoding: .utf8)
            }
            self.lock.lock()
            if let d = duration { self.durations[url.path] = d }
            let callbacks = self.pending.removeValue(forKey: url.path) ?? []
            self.lock.unlock()
            if let image { self.posters.setObject(image, forKey: memKey) }
            DispatchQueue.main.async { callbacks.forEach { $0(image, duration) } }
        }
    }

    /// 进度条悬停预览：只做最新一次请求，旧的直接丢掉。
    func preview(for url: URL, at seconds: Double, completion: @escaping (NSImage?, Double) -> Void) {
        lock.lock()
        previewToken += 1
        let token = previewToken
        lock.unlock()
        previewQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = token != self.previewToken
            self.lock.unlock()
            if stale { return }
            let cg = Thumbnails.frame(url.path, seconds: seconds, fraction: -1, maxW: 320, maxH: 180, keyframeOnly: true)
            let img = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            DispatchQueue.main.async {
                self.lock.lock()
                let current = token == self.previewToken
                self.lock.unlock()
                if current { completion(img, seconds) }
            }
        }
    }

    // MARK: 停留画面（最近看过列表用）

    func snapshotURL(for path: String) -> URL {
        directory.appendingPathComponent("停留画面/\(Thumbnails.key(path)).jpg")
    }

    func snapshot(for path: String) -> NSImage? {
        let memKey = ("snap:" + path) as NSString
        if let img = posters.object(forKey: memKey) { return img }
        guard let img = NSImage(contentsOf: snapshotURL(for: path)) else { return nil }
        posters.setObject(img, forKey: memKey)
        return img
    }

    func saveSnapshot(_ image: CGImage, for path: String) {
        let small = Thumbnails.scaled(image, maxW: 480, maxH: 270) ?? image
        Thumbnails.writeJPEG(small, to: snapshotURL(for: path))
        posters.setObject(NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height)),
                          forKey: ("snap:" + path) as NSString)
    }

    func removeSnapshot(for path: String) {
        try? FileManager.default.removeItem(at: snapshotURL(for: path))
        posters.removeObject(forKey: ("snap:" + path) as NSString)
    }

    // MARK: 工具

    static func frame(_ path: String, seconds: Double, fraction: Double, maxW: Int, maxH: Int, keyframeOnly: Bool) -> CGImage? {
        var img = fy_image()
        guard fy_thumbnail(path, seconds, fraction, Int32(maxW), Int32(maxH), keyframeOnly ? 1 : 0, &img) == 0,
              let data = img.data else { return nil }
        defer { fy_image_free(&img) }
        return makeImage(bgra: data, width: Int(img.width), height: Int(img.height), stride: Int(img.stride))
    }

    static func makeImage(bgra: UnsafeRawPointer, width: Int, height: Int, stride: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
              let dst = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        for y in 0..<height {
            memcpy(dst + y * rowBytes, bgra + y * stride, width * 4)
        }
        return ctx.makeImage()
    }

    static func scaled(_ image: CGImage, maxW: Int, maxH: Int) -> CGImage? {
        let s = min(Double(maxW) / Double(image.width), Double(maxH) / Double(image.height), 1)
        let w = max(2, Int((Double(image.width) * s).rounded())), h = max(2, Int((Double(image.height) * s).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
