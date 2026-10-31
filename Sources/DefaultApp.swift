import AppKit
import CoreServices
import UniformTypeIdentifiers

/// 把放映设成各种视频格式的默认打开方式。
enum DefaultApp {
    static let bundleID = "local.fangying"

    static var contentTypes: [UTType] {
        var seen = Set<String>()
        var list: [UTType] = []
        let base: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg, .mpeg2Video, .mpeg2TransportStream, .appleProtectedMPEG4Video]
        for t in base + Media.videoExts.sorted().compactMap({ UTType(filenameExtension: $0) }) {
            guard !t.isDynamic, seen.insert(t.identifier).inserted else { continue }
            list.append(t)
        }
        return list
    }

    static func handled(_ t: UTType) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: t) else { return false }
        return Bundle(url: app)?.bundleIdentifier == bundleID
    }

    /// 桌面上放一个替身（和墨览、拾回一样是书签文件）。重新构建时 app 会整个换掉，所以每次都重写。
    static func makeDesktopAlias() throws {
        let app = URL(fileURLWithPath: "/Applications/放映.app")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let data = try app.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: desktop.appendingPathComponent("放映"))
    }

    /// 返回没设上的格式。先用 LaunchServices 直接设；m4v 这类被「TV」占着的再走 NSWorkspace。
    @discardableResult
    static func setAsDefault() -> [String] {
        for t in contentTypes {
            LSSetDefaultRoleHandlerForContentType(t.identifier as CFString, .all, bundleID as CFString)
            LSSetDefaultRoleHandlerForContentType(t.identifier as CFString, .viewer, bundleID as CFString)
        }
        let path = Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath : "/Applications/放映.app"
        var pending = 0
        for t in contentTypes where !handled(t) {
            pending += 1
            NSWorkspace.shared.setDefaultApplication(at: URL(fileURLWithPath: path), toOpen: t) { _ in
                DispatchQueue.main.async { pending -= 1 }
            }
        }
        let end = Date().addingTimeInterval(8)
        while pending > 0, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return contentTypes.filter { !handled($0) }.map { $0.preferredFilenameExtension ?? $0.identifier }
    }
}
