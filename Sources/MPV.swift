import Foundation
import OpenGL.GL3

/// libmpv 的薄封装。事件在 mpv 自己的线程上收，转到主线程交给 onEvent。
final class MPV {
    enum Event {
        case property(String, Any?)
        case startFile
        case fileLoaded
        case endFile(reason: mpv_end_file_reason, error: Int32)
        case videoReconfig
        case playbackRestart
        case shutdown
    }

    let handle: OpaquePointer
    var onEvent: ((Event) -> Void)?
    private(set) var renderContext: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "local.fangying.mpv-events")
    private var destroyed = false  // 只在 eventQueue 上读写

    // time-pos 每帧都会变，合并成一次主线程更新
    private let posLock = NSLock()
    private var latestPos: Double?
    private var posPending = false

    init(options: [(String, String)]) {
        guard let h = mpv_create() else { fatalError("mpv_create 失败") }
        handle = h
        for (k, v) in options {
            let r = mpv_set_option_string(handle, k, v)
            if r < 0 { NSLog("mpv 选项 %@=%@ 设置失败：%@", k, v, String(cString: mpv_error_string(r))) }
        }
        let r = mpv_initialize(handle)
        if r < 0 { fatalError("mpv 初始化失败：\(String(cString: mpv_error_string(r)))") }
        mpv_set_wakeup_callback(handle, { ctx in
            let me = Unmanaged<MPV>.fromOpaque(ctx!).takeUnretainedValue()
            me.eventQueue.async { me.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func observe(_ name: String, _ format: mpv_format) {
        mpv_observe_property(handle, 0, name, format)
    }

    private func drainEvents() {
        guard !destroyed else { return }
        while let ev = mpv_wait_event(handle, 0)?.pointee, ev.event_id != MPV_EVENT_NONE {
            var out: Event?
            switch ev.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                let p = ev.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                let name = String(cString: p.name)
                let value = MPV.decode(format: p.format, data: p.data)
                if name == "time-pos" {
                    posLock.lock()
                    latestPos = value as? Double
                    let schedule = !posPending
                    posPending = true
                    posLock.unlock()
                    if schedule {
                        DispatchQueue.main.async {
                            self.posLock.lock()
                            let v = self.latestPos
                            self.posPending = false
                            self.posLock.unlock()
                            self.onEvent?(.property("time-pos", v))
                        }
                    }
                    continue
                }
                out = .property(name, value)
            case MPV_EVENT_START_FILE: out = .startFile
            case MPV_EVENT_FILE_LOADED: out = .fileLoaded
            case MPV_EVENT_END_FILE:
                let e = ev.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                out = .endFile(reason: e.reason, error: e.error)
            case MPV_EVENT_VIDEO_RECONFIG: out = .videoReconfig
            case MPV_EVENT_PLAYBACK_RESTART: out = .playbackRestart
            case MPV_EVENT_SHUTDOWN: out = .shutdown
            default: break
            }
            if let out { DispatchQueue.main.async { self.onEvent?(out) } }
        }
    }

    // MARK: 命令

    @discardableResult
    func command(_ args: [String]) -> Int32 {
        withCArgs(args) { mpv_command(handle, $0) }
    }

    /// 不等 mpv 处理完就返回，拖进度条时用，免得卡住界面。
    func commandAsync(_ args: [String]) {
        _ = withCArgs(args) { mpv_command_async(handle, 0, $0) }
    }

    func commandNode(_ args: [String]) -> Any? {
        var result = mpv_node()
        let r = withCArgs(args) { mpv_command_ret(handle, $0, &result) }
        guard r >= 0 else {
            NSLog("mpv 命令 %@ 失败：%@", args.joined(separator: " "), String(cString: mpv_error_string(r)))
            return nil
        }
        defer { mpv_free_node_contents(&result) }
        return MPV.decode(node: result)
    }

    private func withCArgs<T>(_ args: [String], _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> T) -> T {
        let owned = args.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } } + [nil]
        return ptrs.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    // MARK: 属性

    func double(_ name: String) -> Double? {
        var v = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    func flag(_ name: String) -> Bool? {
        var v: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &v) >= 0 ? v != 0 : nil
    }

    func string(_ name: String) -> String? {
        guard let c = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    func node(_ name: String) -> Any? {
        var n = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &n) >= 0 else { return nil }
        defer { mpv_free_node_contents(&n) }
        return MPV.decode(node: n)
    }

    func set(_ name: String, _ value: String) {
        mpv_set_property_string(handle, name, value)
    }

    func set(_ name: String, _ value: Double) {
        var v = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
    }

    func set(_ name: String, _ value: Bool) {
        var v: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &v)
    }

    func setAsync(_ name: String, _ value: Double) {
        var v = value
        mpv_set_property_async(handle, 0, name, MPV_FORMAT_DOUBLE, &v)
    }

    func setAsync(_ name: String, _ value: Bool) {
        var v: Int32 = value ? 1 : 0
        mpv_set_property_async(handle, 0, name, MPV_FORMAT_FLAG, &v)
    }

    // MARK: 解码 mpv 的数据

    static func decode(format: mpv_format, data: UnsafeMutableRawPointer?) -> Any? {
        guard let data else { return nil }
        switch format {
        case MPV_FORMAT_FLAG: return data.load(as: Int32.self) != 0
        case MPV_FORMAT_DOUBLE: return data.load(as: Double.self)
        case MPV_FORMAT_INT64: return data.load(as: Int64.self)
        case MPV_FORMAT_STRING, MPV_FORMAT_OSD_STRING:
            guard let p = data.load(as: UnsafePointer<CChar>?.self) else { return nil }
            return String(cString: p)
        case MPV_FORMAT_NODE: return decode(node: data.load(as: mpv_node.self))
        default: return nil
        }
    }

    static func decode(node: mpv_node) -> Any? {
        switch node.format {
        case MPV_FORMAT_STRING: return node.u.string.map { String(cString: $0) }
        case MPV_FORMAT_FLAG: return node.u.flag != 0
        case MPV_FORMAT_INT64: return node.u.int64
        case MPV_FORMAT_DOUBLE: return node.u.double_
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee else { return [Any]() }
            return (0..<Int(list.num)).map { decode(node: list.values[$0]) as Any }
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee else { return [String: Any]() }
            var dict: [String: Any] = [:]
            for i in 0..<Int(list.num) {
                let key = String(cString: list.keys[i]!)
                if let v = decode(node: list.values[i]) { dict[key] = v }
            }
            return dict
        case MPV_FORMAT_BYTE_ARRAY:
            guard let ba = node.u.ba?.pointee, let p = ba.data else { return Data() }
            return Data(bytes: p, count: ba.size)
        default: return nil
        }
    }

    // MARK: OpenGL 渲染（在渲染线程上调用，调用时 GL 上下文已是当前上下文）

    private static let glLibrary = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)

    func createRenderContext(updateCallback: mpv_render_update_fn, context: UnsafeMutableRawPointer) -> Bool {
        let apiType = strdup("opengl")
        defer { free(apiType) }
        var glInit = mpv_opengl_init_params(get_proc_address: { _, name in
            guard let name else { return nil }
            return dlsym(MPV.glLibrary, name)
        }, get_proc_address_ctx: nil)
        var advanced: Int32 = 1
        var ctx: OpaquePointer?
        let r: Int32 = withUnsafeMutablePointer(to: &glInit) { glPtr in
            withUnsafeMutablePointer(to: &advanced) { advPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(glPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: UnsafeMutableRawPointer(advPtr)),
                    mpv_render_param(),
                ]
                return mpv_render_context_create(&ctx, handle, &params)
            }
        }
        guard r >= 0, let ctx else {
            NSLog("mpv 渲染上下文创建失败：%@", String(cString: mpv_error_string(r)))
            return false
        }
        renderContext = ctx
        mpv_render_context_set_update_callback(ctx, updateCallback, context)
        return true
    }

    /// 返回 mpv 有没有新画面要画。
    func renderUpdateWantsFrame() -> Bool {
        guard let ctx = renderContext else { return false }
        return mpv_render_context_update(ctx) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
    }

    /// 不在渲染调用里等显示时刻：等待由 VideoLayer 在锁外面做（frameDelay），主线程要重画时不用排队。
    func render(fbo: Int32, width: Int32, height: Int32, flip: Bool = true) {
        guard let ctx = renderContext else { return }
        var target = mpv_opengl_fbo(fbo: fbo, w: width, h: height, internal_format: 0)
        var flipY: Int32 = flip ? 1 : 0
        var block: Int32 = 0
        withUnsafeMutablePointer(to: &target) { t in
            withUnsafeMutablePointer(to: &flipY) { f in
                withUnsafeMutablePointer(to: &block) { b in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(t)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(f)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(b)),
                        mpv_render_param(),
                    ]
                    _ = mpv_render_context_render(ctx, &params)
                }
            }
        }
    }

    /// 下一帧离它该显示的时刻还有多少秒（renderUpdateWantsFrame 返回 true 之后才有意义）。
    func frameDelay() -> Double {
        guard let ctx = renderContext else { return 0 }
        var info = mpv_render_frame_info()
        let r = withUnsafeMutablePointer(to: &info) { p in
            mpv_render_context_get_info(ctx, mpv_render_param(type: MPV_RENDER_PARAM_NEXT_FRAME_INFO, data: UnsafeMutableRawPointer(p)))
        }
        guard r >= 0, info.flags & UInt64(MPV_RENDER_FRAME_INFO_PRESENT.rawValue) != 0, info.target_time > 0 else { return 0 }
        return Double(info.target_time - mpv_get_time_us(handle)) / 1_000_000
    }

    func reportSwap() {
        if let ctx = renderContext { mpv_render_context_report_swap(ctx) }
    }

    func freeRenderContext() {
        if let ctx = renderContext {
            mpv_render_context_set_update_callback(ctx, nil, nil)
            mpv_render_context_free(ctx)
            renderContext = nil
        }
    }

    /// 先停掉取事件的线程再销毁：两边同时碰 handle 会踩到已释放的内存（mpv 的 ta.c 断言崩溃）。
    func destroy() {
        mpv_set_wakeup_callback(handle, nil, nil)
        eventQueue.sync { destroyed = true }
        mpv_terminate_destroy(handle)
    }
}
