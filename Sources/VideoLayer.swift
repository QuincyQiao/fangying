import AppKit
import OpenGL.GL3

/// 画面层：mpv 用 OpenGL 往这里画。mpv 有新帧时在渲染线程上 display()；窗口变大小时 Core Animation 会在主线程上要一帧，两边用同一把锁。
final class VideoLayer: CAOpenGLLayer {
    unowned let mpv: MPV
    let renderQueue: DispatchQueue
    private let cglPixelFormat: CGLPixelFormatObj
    private let cglContext: CGLContextObj
    private let lock: NSRecursiveLock
    private var wantsFrame = false
    private var forceDraw = true
    private(set) var edr = false
    private(set) var forcedDraws = 0

    init(mpv: MPV) {
        self.mpv = mpv
        renderQueue = DispatchQueue(label: "local.fangying.render", qos: .userInteractive)
        lock = NSRecursiveLock()
        (cglPixelFormat, cglContext) = VideoLayer.makeContext()
        super.init()
        isOpaque = true
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        colorspace = CGColorSpace(name: CGColorSpace.displayP3)

        CGLSetCurrentContext(cglContext)
        _ = mpv.createRenderContext(updateCallback: { ctx in
            let layer = Unmanaged<VideoLayer>.fromOpaque(ctx!).takeUnretainedValue()
            layer.renderQueue.async { layer.mpvHasUpdate() }
        }, context: Unmanaged.passUnretained(self).toOpaque())
        CGLSetCurrentContext(nil)
    }

    override init(layer: Any) {
        let other = layer as! VideoLayer
        mpv = other.mpv
        renderQueue = other.renderQueue
        lock = other.lock
        cglPixelFormat = other.cglPixelFormat
        cglContext = other.cglContext
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func makeContext() -> (CGLPixelFormatObj, CGLContextObj) {
        func choose(_ floatColor: Bool) -> CGLPixelFormatObj? {
            var attrs: [CGLPixelFormatAttribute] = [
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
                kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
            ]
            if floatColor { attrs += [kCGLPFAColorSize, CGLPixelFormatAttribute(64), kCGLPFAColorFloat] }
            attrs.append(CGLPixelFormatAttribute(0))
            var pf: CGLPixelFormatObj?
            var count: GLint = 0
            CGLChoosePixelFormat(attrs, &pf, &count)
            return pf
        }
        guard let pf = choose(true) ?? choose(false) else { fatalError("没有可用的 OpenGL 像素格式") }
        var ctx: CGLContextObj?
        CGLCreateContext(pf, nil, &ctx)
        guard let ctx else { fatalError("OpenGL 上下文创建失败") }
        var swap: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)
        CGLEnable(ctx, kCGLCEMPEngine)
        return (pf, ctx)
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        CGLRetainPixelFormat(cglPixelFormat)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        CGLRetainContext(cglContext)
    }

    override var bounds: CGRect {
        didSet { if bounds.size != oldValue.size { forceDraw = true } }
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        forceDraw || wantsFrame
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        if forceDraw { forcedDraws += 1 }
        wantsFrame = false
        forceDraw = false
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        if mpv.renderContext != nil, viewport[2] > 0, viewport[3] > 0 {
            mpv.render(fbo: fbo, width: viewport[2], height: viewport[3])
        } else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        glFlush()
    }

    override func display() {
        lock.lock()
        defer { lock.unlock() }
        super.display()
        CATransaction.flush()
        mpv.reportSwap()
    }

    private func mpvHasUpdate() {
        lock.lock()
        defer { lock.unlock() }
        guard mpv.renderContext != nil else { return }
        // mpv 在这里会顺带处理截图这类要用 GL 的请求，GL 上下文必须是当前的
        CGLLockContext(cglContext)
        CGLSetCurrentContext(cglContext)
        let wants = mpv.renderUpdateWantsFrame()
        let delay = wants ? mpv.frameDelay() : 0
        CGLUnlockContext(cglContext)
        guard wants else { return }
        // mpv 提前把帧交过来，等到该显示的时刻再画。这段等待不占锁，窗口变大小时主线程不用等
        if delay > 0.001, delay < 0.2 {
            lock.unlock()
            Thread.sleep(forTimeInterval: delay)
            lock.lock()
        }
        wantsFrame = true
        display()
    }

    func redraw() {
        renderQueue.async {
            self.lock.lock()
            self.forceDraw = true
            self.display()
            self.lock.unlock()
        }
    }

    /// HDR 片子在支持 EDR 的屏幕上按 PQ 输出，交给系统映射亮度；否则 mpv 自己压到普通亮度。
    func setEDR(_ on: Bool) {
        guard on != edr else { return }
        edr = on
        wantsExtendedDynamicRangeContent = on
        colorspace = CGColorSpace(name: on ? CGColorSpace.itur_2100_PQ : CGColorSpace.displayP3)
        if on {
            mpv.set("target-trc", "pq")
            mpv.set("target-prim", "bt.2020")
        } else {
            mpv.set("target-trc", "auto")
            mpv.set("target-prim", "display-p3")
        }
        redraw()
    }

    /// 退出前在渲染线程上释放 mpv 的渲染上下文（必须在 GL 上下文是当前上下文时做）。
    func shutdown() {
        renderQueue.sync {
            lock.lock()
            CGLSetCurrentContext(cglContext)
            mpv.freeRenderContext()
            CGLSetCurrentContext(nil)
            lock.unlock()
        }
    }
}
