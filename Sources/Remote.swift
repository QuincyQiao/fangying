import AppKit

/// 远程电脑上的文件。地址写成 ssh://主机/路径，观看记录、封面和列表都认这个地址，真正播放时才换成本机转接的 HTTP 地址。
/// 全程只走现有的 SSH（SFTP 子系统）：对方不用装东西，也不用开新端口。
struct RemoteEntry {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Date
}

enum RemoteError: Error {
    case disconnected       // 连接断了，重连后可以再试
    case failed(UInt32)     // 对方回了错误：文件不存在、没有权限
}

// MARK: - SFTP

/// 一条 SFTP 连接。调用都是阻塞的，可以从多个线程同时调用；连接断了，下一次调用自动重连。
final class SFTPClient {
    struct Attrs {
        var size: UInt64 = 0
        var permissions: UInt32 = 0
        var modified: UInt32 = 0
        var isDirectory: Bool { permissions & 0o170000 == 0o040000 }
        var isLink: Bool { permissions & 0o170000 == 0o120000 }
    }

    /// 打开的文件。句柄跟着连接走，连接换了要重新打开。
    final class OpenFile {
        fileprivate let handle: Data
        fileprivate let link: Link
        fileprivate init(handle: Data, link: Link) { self.handle = handle; self.link = link }
    }

    fileprivate enum Op {
        static let initialize: UInt8 = 1, version: UInt8 = 2, open: UInt8 = 3, close: UInt8 = 4, read: UInt8 = 5
        static let opendir: UInt8 = 11, readdir: UInt8 = 12, realpath: UInt8 = 16, stat: UInt8 = 17
        static let status: UInt8 = 101, handle: UInt8 = 102, data: UInt8 = 103, name: UInt8 = 104, attrs: UInt8 = 105
    }
    private static let statusEOF: UInt32 = 1
    /// 一次并行发这么多个读请求，一窗 2 MB
    static let chunk = 64 * 1024, window = 32

    private let command: [String]
    private let connectLock = NSLock()
    private var current: Link?
    private var lastFailure = Date.distantPast

    init(command: [String]) { self.command = command }

    private func link() throws -> Link {
        connectLock.lock()
        defer { connectLock.unlock() }
        if let l = current, l.alive { return l }
        // 刚连失败过就别再等一轮超时，列表、封面同时来的时候一个个排着等会很久
        if Date().timeIntervalSince(lastFailure) < 3 { throw RemoteError.disconnected }
        guard let l = Link(command: command) else {
            lastFailure = Date()
            throw RemoteError.disconnected
        }
        current = l
        return l
    }

    /// 合上盖子再打开时，旧连接其实已经断了，但要等心跳超时才知道。直接换掉。
    func dropLink() {
        connectLock.lock()
        let l = current
        current = nil
        connectLock.unlock()
        l?.shutdown()
    }

    /// 只读的单个请求：连接刚好断了就换一条再试一次。
    private func call(_ kind: UInt8, _ body: Data) throws -> (kind: UInt8, body: Data) {
        for _ in 0..<2 {
            let l = try link()
            if let r = l.exchange([(kind, body)])?.first { return r }
        }
        throw RemoteError.disconnected
    }

    private static func check(_ reply: (kind: UInt8, body: Data)) throws {
        if reply.kind == Op.status {
            var r = Reader(reply.body)
            throw RemoteError.failed(r.u32() ?? 4)
        }
    }

    func home() throws -> String {
        let reply = try call(Op.realpath, sftpString("."))
        try SFTPClient.check(reply)
        var r = Reader(reply.body)
        guard reply.kind == Op.name, r.u32() ?? 0 > 0, let name = r.string() else { throw RemoteError.failed(4) }
        return String(decoding: name, as: UTF8.self)
    }

    func stat(_ path: String) throws -> Attrs {
        let reply = try call(Op.stat, sftpString(path))
        try SFTPClient.check(reply)
        var r = Reader(reply.body)
        return r.attrs()
    }

    func list(_ path: String) throws -> [(name: String, attrs: Attrs)] {
        let l = try link()
        guard let opened = l.exchange([(Op.opendir, sftpString(path))])?.first else { throw RemoteError.disconnected }
        try SFTPClient.check(opened)
        var r = Reader(opened.body)
        guard let handle = r.string() else { throw RemoteError.failed(4) }
        defer { _ = l.exchange([(Op.close, sftpString(handle))]) }
        var out: [(name: String, attrs: Attrs)] = []
        while true {
            guard let reply = l.exchange([(Op.readdir, sftpString(handle))])?.first else { throw RemoteError.disconnected }
            var r = Reader(reply.body)
            if reply.kind == Op.status {
                let code = r.u32() ?? 4
                if code == SFTPClient.statusEOF { return out }
                throw RemoteError.failed(code)
            }
            guard reply.kind == Op.name, let count = r.u32() else { throw RemoteError.failed(4) }
            for _ in 0..<count {
                guard let name = r.string(), r.string() != nil else { throw RemoteError.failed(4) }
                out.append((String(decoding: name, as: UTF8.self), r.attrs()))
            }
        }
    }

    func open(_ path: String) throws -> OpenFile {
        let l = try link()
        let body = sftpString(path) + sftpUInt32(1) + sftpUInt32(0)   // 只读
        guard let reply = l.exchange([(Op.open, body)])?.first else { throw RemoteError.disconnected }
        try SFTPClient.check(reply)
        var r = Reader(reply.body)
        guard let handle = r.string() else { throw RemoteError.failed(4) }
        return OpenFile(handle: handle, link: l)
    }

    func close(_ file: OpenFile) {
        guard file.link.alive else { return }
        _ = file.link.exchange([(Op.close, sftpString(file.handle))])
    }

    /// 读一窗数据。返回空表示读到头了。
    func read(_ file: OpenFile, offset: UInt64, length: Int) throws -> Data {
        var requests: [(UInt8, Data)] = []
        var sizes: [Int] = []
        var pos = 0
        while pos < length, requests.count < SFTPClient.window {
            let n = min(SFTPClient.chunk, length - pos)
            requests.append((Op.read, sftpString(file.handle) + sftpUInt64(offset + UInt64(pos)) + sftpUInt32(UInt32(n))))
            sizes.append(n)
            pos += n
        }
        guard let replies = file.link.exchange(requests) else { throw RemoteError.disconnected }
        var out = Data()
        for (reply, size) in zip(replies, sizes) {
            if reply.kind == Op.status {
                var r = Reader(reply.body)
                let code = r.u32() ?? 4
                if code == SFTPClient.statusEOF { break }
                throw RemoteError.failed(code)
            }
            var r = Reader(reply.body)
            guard reply.kind == Op.data, let chunk = r.string() else { throw RemoteError.failed(4) }
            out.append(chunk)
            // 中间短读后面的数据接不上，这一窗到此为止，调用方从这里接着读
            if chunk.count < size { break }
        }
        return out
    }
}

private func sftpUInt32(_ v: UInt32) -> Data {
    withUnsafeBytes(of: v.bigEndian) { Data($0) }
}

private func sftpUInt64(_ v: UInt64) -> Data {
    withUnsafeBytes(of: v.bigEndian) { Data($0) }
}

private func sftpString(_ s: Data) -> Data { sftpUInt32(UInt32(s.count)) + s }
private func sftpString(_ s: String) -> Data { sftpString(Data(s.utf8)) }

private struct Reader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func u32() -> UInt32? {
        guard offset + 4 <= data.endIndex else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(data[offset + i]) }
        offset += 4
        return v
    }

    mutating func u64() -> UInt64? {
        guard let hi = u32(), let lo = u32() else { return nil }
        return UInt64(hi) << 32 | UInt64(lo)
    }

    mutating func string() -> Data? {
        guard let n = u32(), offset + Int(n) <= data.endIndex else { return nil }
        defer { offset += Int(n) }
        return data.subdata(in: offset..<(offset + Int(n)))
    }

    mutating func attrs() -> SFTPClient.Attrs {
        var a = SFTPClient.Attrs()
        guard let flags = u32() else { return a }
        if flags & 0x1 != 0 { a.size = u64() ?? 0 }
        if flags & 0x2 != 0 { _ = u64() }
        if flags & 0x4 != 0 { a.permissions = u32() ?? 0 }
        if flags & 0x8 != 0 {
            _ = u32()
            a.modified = u32() ?? 0
        }
        if flags & 0x8000_0000 != 0, let count = u32() {
            for _ in 0..<count {
                _ = string()
                _ = string()
            }
        }
        return a
    }
}

/// 一个 ssh 进程。断了就整个换掉，打开的文件句柄跟着失效。
fileprivate final class Link {
    private final class Waiter {
        let done = DispatchSemaphore(value: 0)
        var reply: (kind: UInt8, body: Data)?
    }

    /// 等回复的上限。网断了 ssh 自己的心跳要 45 秒才退出
    private static let timeout: TimeInterval = 30

    private let process = Process()
    private let toChild = Pipe()
    private let fromChild = Pipe()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var waiters: [UInt32: Waiter] = [:]
    private var nextID: UInt32 = 1
    private let greeted = DispatchSemaphore(value: 0)
    private(set) var alive = true

    init?(command: [String]) {
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let thread = Thread { [self] in readLoop() }
        thread.name = "放映 SFTP"
        thread.start()
        var hello = Data([SFTPClient.Op.initialize])
        hello.append(sftpUInt32(3))
        guard writeAll(toChild.fileHandleForWriting.fileDescriptor, sftpUInt32(UInt32(hello.count)) + hello),
              greeted.wait(timeout: .now() + 15) == .success, alive else {
            shutdown()
            return nil
        }
    }

    /// 一次发一批请求，按顺序收回。连接断了返回 nil。
    func exchange(_ requests: [(UInt8, Data)]) -> [(kind: UInt8, body: Data)]? {
        var list: [Waiter] = []
        var packet = Data()
        lock.lock()
        guard alive else {
            lock.unlock()
            return nil
        }
        for (kind, body) in requests {
            let id = nextID
            nextID &+= 1
            let w = Waiter()
            waiters[id] = w
            list.append(w)
            packet.append(sftpUInt32(UInt32(body.count + 5)))
            packet.append(kind)
            packet.append(sftpUInt32(id))
            packet.append(body)
        }
        lock.unlock()
        writeLock.lock()
        let sent = writeAll(toChild.fileHandleForWriting.fileDescriptor, packet)
        writeLock.unlock()
        guard sent else {
            shutdown()
            return nil
        }
        var out: [(kind: UInt8, body: Data)] = []
        for w in list {
            if w.done.wait(timeout: .now() + Link.timeout) == .timedOut {
                shutdown()
                return nil
            }
            guard let r = w.reply else { return nil }
            out.append(r)
        }
        return out
    }

    func shutdown() {
        lock.lock()
        let wasAlive = alive
        alive = false
        let pending = waiters
        waiters = [:]
        lock.unlock()
        guard wasAlive else { return }
        pending.values.forEach { $0.done.signal() }
        greeted.signal()
        if process.isRunning { process.terminate() }
    }

    private func readLoop() {
        let fd = fromChild.fileHandleForReading.fileDescriptor
        while let head = readExactly(fd, 4) {
            var r = Reader(head)
            guard let n = r.u32(), n >= 1, n <= 1 << 24, let body = readExactly(fd, Int(n)) else { break }
            let kind = body[body.startIndex]
            if kind == SFTPClient.Op.version {
                greeted.signal()
                continue
            }
            var rest = Reader(body.subdata(in: (body.startIndex + 1)..<body.endIndex))
            guard let id = rest.u32() else { break }
            lock.lock()
            let w = waiters.removeValue(forKey: id)
            lock.unlock()
            w?.reply = (kind, body.subdata(in: (body.startIndex + 5)..<body.endIndex))
            w?.done.signal()
        }
        shutdown()
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var out = Data(count: count)
        var got = 0
        let ok = out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            while got < count {
                let n = read(fd, raw.baseAddress! + got, count - got)
                if n > 0 {
                    got += n
                } else if n == 0 || errno != EINTR {
                    return false
                }
            }
            return true
        }
        return ok ? out : nil
    }
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        var sent = 0
        while sent < raw.count {
            let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
            if n > 0 {
                sent += n
            } else if errno != EINTR {
                return false
            }
        }
        return true
    }
}

// MARK: - 本机转接

/// 本机 127.0.0.1 上的小 HTTP 服务：mpv 和 FFmpeg 读它，它再经 SFTP 读远程文件。
/// 支持 Range，跳转时 mpv 断开旧连接、发新请求。地址里带随机口令，本机别的程序猜不到。
final class RemoteBridge {
    static let shared = RemoteBridge()

    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let lock = NSLock()
    private var port: UInt16 = 0
    /// 网络断了等它回来接着传的上限，和 Player 给 mpv 的 network-timeout 一致
    static let reconnectWait: TimeInterval = 120

    func url(for remote: URL) -> String {
        start()
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#;")
        let path = remote.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? remote.path
        return "http://127.0.0.1:\(port)/\(token)/\(remote.host ?? "")\(path)"
    }

    private func start() {
        lock.lock()
        defer { lock.unlock() }
        guard port == 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return
        }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "放映 本机转接"
        thread.start()
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let c = accept(listener, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return
            }
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [self] in
                serve(c)
                close(c)
            }
            thread.name = "放映 转接连接"
            thread.start()
        }
    }

    private func readHead(_ fd: Int32) -> String? {
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while head.count < 16 * 1024 {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return nil }
            head.append(contentsOf: buffer[0..<n])
            if head.range(of: Data("\r\n\r\n".utf8)) != nil { return String(decoding: head, as: UTF8.self) }
        }
        return nil
    }

    private func respond(_ fd: Int32, _ status: String, headers: [String] = []) {
        let text = (["HTTP/1.1 \(status)", "Connection: close"] + headers).joined(separator: "\r\n") + "\r\n\r\n"
        _ = writeAll(fd, Data(text.utf8))
    }

    /// 解析 Range 头，返回闭区间。没有 Range 时返回 nil。
    static func parseRange(_ value: String, size: UInt64) -> ClosedRange<UInt64>? {
        guard value.hasPrefix("bytes="), size > 0 else { return nil }
        let first = value.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false).first ?? ""
        let parts = first.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let tail = UInt64(parts[1]), tail > 0 else { return nil }
            return (size - min(tail, size))...(size - 1)
        }
        guard let start = UInt64(parts[0]), start < size else { return nil }
        let end = parts[1].isEmpty ? size - 1 : min(UInt64(parts[1]) ?? size - 1, size - 1)
        return end >= start ? start...end : nil
    }

    private func serve(_ fd: Int32) {
        guard let head = readHead(fd) else { return }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            respond(fd, "405 Method Not Allowed")
            return
        }
        let prefix = "/\(token)/"
        guard parts[1].hasPrefix(prefix) else {
            respond(fd, "403 Forbidden")
            return
        }
        let rest = parts[1].dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/"), let path = String(rest[slash...]).removingPercentEncoding else {
            respond(fd, "404 Not Found")
            return
        }
        let client = Remote.shared.client(for: String(rest[..<slash]))
        let size: UInt64
        do {
            size = try client.stat(path).size
        } catch RemoteError.disconnected {
            respond(fd, "503 Service Unavailable")
            return
        } catch {
            respond(fd, "404 Not Found")
            return
        }
        let header = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
        let rangeText = header.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let range = rangeText.flatMap { RemoteBridge.parseRange($0, size: size) }
        if rangeText != nil, range == nil {
            respond(fd, "416 Range Not Satisfiable", headers: ["Content-Range: bytes */\(size)"])
            return
        }
        let start = range?.lowerBound ?? 0
        let end = range?.upperBound ?? (size == 0 ? 0 : size - 1)
        var headers = ["Accept-Ranges: bytes", "Content-Type: application/octet-stream",
                       "Content-Length: \(size == 0 ? 0 : end - start + 1)"]
        if range != nil { headers.append("Content-Range: bytes \(start)-\(end)/\(size)") }
        respond(fd, range == nil ? "200 OK" : "206 Partial Content", headers: headers)
        guard parts[0] == "GET", size > 0 else { return }
        stream(path, from: start, through: end, client: client, to: fd)
    }

    private func stream(_ path: String, from start: UInt64, through end: UInt64, client: SFTPClient, to fd: Int32) {
        var file: SFTPClient.OpenFile?
        var pos = start
        let windowBytes = UInt64(SFTPClient.chunk * SFTPClient.window)
        while pos <= end {
            do {
                if file == nil { file = try client.open(path) }
                let chunk = try client.read(file!, offset: pos, length: Int(min(end - pos + 1, windowBytes)))
                if chunk.isEmpty { break }
                // 写是阻塞的：mpv 缓冲够了不再读，这里就停着，不会多传
                guard writeAll(fd, chunk) else { break }
                pos += UInt64(chunk.count)
            } catch RemoteError.disconnected {
                // 网断了或电脑睡过：连接留着，等网回来接着传，mpv 那边只是在缓冲
                file = nil
                guard waitForLink(client, peer: fd) else { break }
            } catch {
                break
            }
        }
        if let file { client.close(file) }
    }

    private func waitForLink(_ client: SFTPClient, peer fd: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(RemoteBridge.reconnectWait)
        while Date() < deadline {
            var byte: UInt8 = 0
            if recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0 { return false }
            if (try? client.home()) != nil { return true }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }
}

// MARK: - 对上层的接口

final class Remote {
    static let shared = Remote()

    /// 自测时直接起本机的 sftp-server，不经过 ssh
    var commandOverride: [String]?

    private let lock = NSLock()
    private var clients: [String: SFTPClient] = [:]
    private var stamps: [String: String] = [:]
    private let queue = DispatchQueue(label: "local.fangying.remote", qos: .userInitiated, attributes: .concurrent)
    /// 全部视频只列这么大以上的，短素材不进片库
    static let minimumVideoSize = 50 * 1024 * 1024

    private init() {
        // ssh 进程退出后再往管道写会收到 SIGPIPE，默认处理是杀掉整个程序
        signal(SIGPIPE, SIG_IGN)
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let all = Array(self.clients.values)
            self.lock.unlock()
            all.forEach { $0.dropLink() }
        }
    }

    /// 主机名只收 SSH 配置里的别名这类写法，防止被当成 ssh 的参数
    static func isValidHost(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first != "-" else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || ".-_".unicodeScalars.contains($0) }
    }

    private static let ssh = ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                              "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]

    func client(for host: String) -> SFTPClient {
        lock.lock()
        defer { lock.unlock() }
        if let c = clients[host] { return c }
        let c = SFTPClient(command: commandOverride ?? (Remote.ssh + ["-s", host, "sftp"]))
        clients[host] = c
        return c
    }

    /// 文件大小和修改时间，封面缓存用它判断片子换没换
    func stamp(for url: URL) -> String {
        lock.lock()
        defer { lock.unlock() }
        return stamps[Media.key(url)] ?? ""
    }

    private func remember(_ entries: [RemoteEntry]) {
        lock.lock()
        for e in entries where !e.isDirectory {
            stamps[Media.key(e.url)] = "\(e.size)-\(Int(e.modified.timeIntervalSince1970))"
        }
        lock.unlock()
    }

    func home(host: String, completion: @escaping (URL?) -> Void) {
        queue.async { [self] in
            let path = try? client(for: host).home()
            DispatchQueue.main.async { completion(path.map { Media.remoteURL(host: host, path: $0) }) }
        }
    }

    /// 列一个文件夹，跳过隐藏文件。完成回调在主线程，连不上时是 nil。
    func list(_ folder: URL, completion: @escaping ([RemoteEntry]?) -> Void) {
        queue.async { [self] in
            let entries = try? entries(in: folder)
            if let entries { remember(entries) }
            DispatchQueue.main.async { completion(entries) }
        }
    }

    private func entries(in folder: URL) throws -> [RemoteEntry] {
        let host = folder.host ?? ""
        let c = client(for: host)
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        var out: [RemoteEntry] = []
        for (name, attrs) in try c.list(folder.path) where !name.hasPrefix(".") {
            var a = attrs
            if a.isLink, let target = try? c.stat(base + name) { a = target }
            out.append(RemoteEntry(url: Media.remoteURL(host: host, path: base + name), name: name, isDirectory: a.isDirectory,
                                   size: a.size, modified: Date(timeIntervalSince1970: TimeInterval(a.modified))))
        }
        return out
    }

    /// 文件夹里的片子列表和字幕。字幕除了同一层，也看 Subs、字幕这些常见的子文件夹。
    func neighbours(of url: URL, completion: @escaping (_ playlist: [URL], _ subtitles: [URL]) -> Void) {
        queue.async { [self] in
            let folder = url.deletingLastPathComponent()
            guard let list = try? entries(in: folder) else {
                DispatchQueue.main.async { completion([], []) }
                return
            }
            remember(list)
            let kind = Media.kind(of: url)
            let files = list.filter { !$0.isDirectory }.map(\.url)
            var subtitles = files.filter { Media.kind(of: $0) == .subtitle }
            let folders: Set<String> = ["sub", "subs", "subtitle", "subtitles", "字幕"]
            for e in list where e.isDirectory && folders.contains(e.name.lowercased()) {
                subtitles += ((try? entries(in: e.url)) ?? []).filter { !$0.isDirectory }.map(\.url).filter { Media.kind(of: $0) == .subtitle }
            }
            let playlist = Media.sorted(files.filter { Media.kind(of: $0) == kind })
            DispatchQueue.main.async { completion(playlist, subtitles) }
        }
    }

    /// 和片名对得上的字幕，规则同 mpv 的 sub-auto=fuzzy：字幕文件名里含片名。
    static func subtitles(for video: URL, in all: [URL]) -> [URL] {
        let stem = video.deletingPathExtension().lastPathComponent.lowercased()
        return all.filter { $0.deletingPathExtension().lastPathComponent.lowercased().contains(stem) }
    }

    /// 片库：用 Spotlight 一次列出对方家目录下的大视频，最新的在前，隐藏文件夹和下划线开头的工程文件夹不算。
    func videos(host: String, completion: @escaping ([RemoteEntry]?) -> Void) {
        let query = "kMDItemContentTypeTree == \"public.movie\" && kMDItemFSSize > \(Remote.minimumVideoSize)"
        let script = "mdfind -0 -onlyin \"$HOME\" '\(query)' | xargs -0 stat -f '%z%t%m%t%N'"
        queue.async { [self] in
            guard let output = run(host: host, script: script) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var entries: [RemoteEntry] = []
            for line in output.split(separator: "\n") {
                let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard f.count == 3, let size = UInt64(f[0]), let time = TimeInterval(f[1]), !Remote.isHidden(f[2]) else { continue }
                let url = Media.remoteURL(host: host, path: f[2])
                if Media.isPlayable(url) {
                    entries.append(RemoteEntry(url: url, name: url.lastPathComponent, isDirectory: false, size: size, modified: Date(timeIntervalSince1970: time)))
                }
            }
            entries.sort { $0.modified > $1.modified }
            remember(entries)
            DispatchQueue.main.async { completion(entries) }
        }
    }

    static func isHidden(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") || $0.hasPrefix("_") || $0 == "Library" }
    }

    /// 每个文件夹下面（含子文件夹）有多少个视频，「只显示有视频的文件夹」和文件夹后面的数字用它。
    static func videoCounts(_ videos: [RemoteEntry]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for v in videos {
            var folder = (v.url.path as NSString).deletingLastPathComponent
            while folder != "/", !folder.isEmpty {
                counts[folder, default: 0] += 1
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        return counts
    }

    /// 对方 Finder 侧边栏里的文件夹，只读。不是 Mac 或读不到时是空的。
    func favorites(host: String, home: URL, completion: @escaping ([URL]) -> Void) {
        let script = #"cd "$HOME/Library/Application Support/com.apple.sharedfilelist" && base64 -i "$(ls -t com.apple.LSSharedFileList.FavoriteItems.sfl* | head -1)""#
        queue.async { [self] in
            var found: [URL] = []
            if let text = run(host: host, script: script), let archive = Data(base64Encoded: text, options: .ignoreUnknownCharacters) {
                let c = client(for: host)
                found = Remote.finderFavorites(in: archive, home: home.path)
                    .filter { (try? c.stat($0))?.isDirectory == true }
                    .map { Media.remoteURL(host: host, path: $0) }
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    /// Finder 的列表是字典组成的 keyed archive，书签里存的是创建时的路径。账号改过名的话旧路径要换到现在的家目录。
    static func finderFavorites(in archive: Data, home: String) -> [String] {
        let types: [AnyClass] = [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self,
                                 NSUUID.self, NSURL.self, NSDate.self, NSSet.self]
        guard let root = (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: types, from: archive)) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        for item in items {
            let properties = item["CustomItemProperties"] as? [String: Any]
            guard properties?["com.apple.LSSharedFileList.ItemIsHidden"] as? Bool != true,
                  let bookmark = item["Bookmark"] as? Data,
                  let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path else { continue }
            let parts = path.split(separator: "/").map(String.init)
            let moved = parts.count >= 2 && parts[0] == "Users" && parts[1] != "Shared"
                ? ([home] + parts.dropFirst(2)).joined(separator: "/") : path
            if !out.contains(moved) { out.append(moved) }
        }
        return out
    }

    private func run(host: String, script: String) -> String? {
        let p = Process()
        if commandOverride != nil {
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
        } else {
            p.executableURL = URL(fileURLWithPath: Remote.ssh[0])
            p.arguments = Array(Remote.ssh.dropFirst()) + [host, script]
        }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timeout.cancel()
        // xargs 没东西可传时退出码不是 0，只要 ssh 连上了就算成功
        guard p.terminationReason == .exit, p.terminationStatus != 255 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
