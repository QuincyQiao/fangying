import AppKit
import CoreImage
import UniformTypeIdentifiers

/// 用代码画图标：浅色磨砂玻璃底板上一只放映镜头。镜圈是透明厚玻璃，镜片是深蓝玻璃，中间浮着一个磨砂白播放三角。
enum IconMaker {
    static func write(to url: URL) -> Bool {
        let ctx = newContext()
        draw(in: ctx)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    private static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let ci = CIContext(options: [.workingColorSpace: p3])
    private static let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    private static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    private static let radius: CGFloat = 185
    private static let center = CGPoint(x: 512, y: 512)

    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: p3, components: [r, g, b, a])! }
    private static func w(_ a: CGFloat) -> CGColor { c(1, 1, 1, a) }
    private static func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
        c(CGFloat(h >> 16 & 0xff) / 255, CGFloat(h >> 8 & 0xff) / 255, CGFloat(h & 0xff) / 255, a)
    }
    private static func grad(_ cols: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
        CGGradient(colorsSpace: p3, colors: cols as CFArray, locations: locs)!
    }
    private static func circle(_ r: CGFloat, _ o: CGPoint = center) -> CGRect { CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r) }

    private static func newContext() -> CGContext {
        CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// 在单独一层上画，高斯模糊后叠回来（柔光、反光、影子用）
    private static func blurred(_ sigma: CGFloat, _ paint: (CGContext) -> Void) -> CGImage {
        let ctx = newContext()
        paint(ctx)
        let img = CIImage(cgImage: ctx.makeImage()!)
        let out = img.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: img.extent)
        return ci.createCGImage(out, from: img.extent, format: .RGBA8, colorSpace: p3)!
    }

    /// 沿形状内缘的一圈高光：左上亮、右下暗，像光从左上打在玻璃边上
    private static func rim(_ ctx: CGContext, _ path: CGPath, width: CGFloat, top: CGFloat, bottom: CGFloat, bounds: CGRect) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(grad([w(top), w(top * 0.35), w(bottom), w(bottom * 2.2)], [0, 0.35, 0.7, 1]),
                               start: CGPoint(x: bounds.minX, y: bounds.maxY), end: CGPoint(x: bounds.maxX, y: bounds.minY), options: [])
        ctx.restoreGState()
    }

    private static func roundedTriangle(cx: CGFloat, cy: CGFloat, h: CGFloat, r: CGFloat) -> CGPath {
        let wd = h * 0.9
        let a = CGPoint(x: cx - wd / 2, y: cy + h / 2), b = CGPoint(x: cx + wd / 2, y: cy), d = CGPoint(x: cx - wd / 2, y: cy - h / 2)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: (a.x + d.x) / 2, y: (a.y + d.y) / 2))
        p.addArc(tangent1End: a, tangent2End: b, radius: r)
        p.addArc(tangent1End: b, tangent2End: d, radius: r)
        p.addArc(tangent1End: d, tangent2End: a, radius: r)
        p.closeSubpath()
        return p
    }

    static func draw(in ctx: CGContext) {
        let tile = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // —— 底板：半透明磨砂玻璃，放在壁纸上能透出底色 ——
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: c(0, 0, 0, 0.28))
        ctx.addPath(tile); ctx.setFillColor(hex(0xC9D3E2, 0.72)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(tile); ctx.clip()
        ctx.clear(full)
        ctx.drawLinearGradient(grad([w(0.80), hex(0xC9D3E2, 0.72)]), start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
        let sheen = CGMutablePath()
        sheen.move(to: CGPoint(x: body.minX, y: body.maxY))
        sheen.addLine(to: CGPoint(x: body.minX + 620, y: body.maxY))
        sheen.addCurve(to: CGPoint(x: body.minX, y: body.minY + 260), control1: CGPoint(x: 420, y: 640), control2: CGPoint(x: 260, y: 520))
        sheen.closeSubpath()
        ctx.draw(blurred(18) { g in
            g.addPath(sheen); g.clip()
            g.drawLinearGradient(grad([w(0.45), w(0.22), w(0)], [0, 0.5, 1]), start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: 560, y: 480), options: [])
        }, in: full)
        ctx.restoreGState()
        rim(ctx, CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: radius - 3, cornerHeight: radius - 3, transform: nil),
            width: 7, top: 1.0, bottom: 0.25, bounds: body)
        ctx.saveGState()
        ctx.addPath(tile); ctx.setStrokeColor(c(0.25, 0.32, 0.45, 0.22)); ctx.setLineWidth(2); ctx.strokePath()
        ctx.restoreGState()

        // —— 镜头投在底板上的影子 ——
        ctx.draw(blurred(26) { g in
            g.setFillColor(c(0, 0, 0, 0.2)); g.fillEllipse(in: circle(296, CGPoint(x: 512, y: 486)))
        }, in: full)

        // —— 镜圈：透明厚玻璃，透出底板，边缘锐亮 ——
        let outer = circle(300), inner = circle(232)
        let ring = CGMutablePath(); ring.addEllipse(in: outer); ring.addEllipse(in: inner)
        ctx.saveGState()
        ctx.addPath(ring); ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(grad([w(0.32), w(0.11), w(0.18)], [0, 0.5, 1]),
                               start: CGPoint(x: outer.minX, y: outer.maxY), end: CGPoint(x: outer.maxX, y: outer.minY), options: [])
        ctx.addEllipse(in: outer.insetBy(dx: 9, dy: 9)); ctx.setStrokeColor(c(0, 0, 0, 0.22)); ctx.setLineWidth(6); ctx.strokePath()
        ctx.draw(blurred(9) { g in
            g.addArc(center: center, radius: 266, startAngle: .pi * 0.52, endAngle: .pi * 1.08, clockwise: false)
            g.setStrokeColor(w(0.62)); g.setLineWidth(16); g.setLineCap(.round); g.strokePath()
        }, in: full)
        ctx.draw(blurred(16) { g in
            g.addArc(center: center, radius: 252, startAngle: -.pi * 0.42, endAngle: -.pi * 0.08, clockwise: false)
            g.setStrokeColor(c(0.75, 0.88, 1, 0.55)); g.setLineWidth(22); g.setLineCap(.round); g.strokePath()
        }, in: full)
        ctx.restoreGState()
        rim(ctx, CGPath(ellipseIn: outer.insetBy(dx: 1.5, dy: 1.5), transform: nil), width: 3.5, top: 1.0, bottom: 0.25, bounds: outer)
        // 内缘反过来，右下亮（光从玻璃里透出来）
        ctx.saveGState()
        ctx.addPath(CGPath(ellipseIn: inner.insetBy(dx: -1.5, dy: -1.5), transform: nil)); ctx.setLineWidth(3.5); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(grad([w(0.15), w(0.9)]), start: CGPoint(x: inner.minX, y: inner.maxY), end: CGPoint(x: inner.maxX, y: inner.minY), options: [])
        ctx.restoreGState()

        // —— 镜片：深蓝玻璃，冷色镀膜反光、几层光学圈、左上一片弧光 ——
        let glass = circle(224)
        ctx.saveGState()
        ctx.addEllipse(in: glass); ctx.clip()
        ctx.drawRadialGradient(grad([hex(0x1F3A5F, 0.96), hex(0x0B1424, 0.97), hex(0x04070D, 0.98)], [0, 0.55, 1]),
                               startCenter: CGPoint(x: 480, y: 560), startRadius: 0, endCenter: center, endRadius: 224, options: [.drawsAfterEndLocation])
        ctx.draw(blurred(38) { g in
            g.setFillColor(c(0.30, 0.68, 1.0, 0.55)); g.fillEllipse(in: CGRect(x: 545, y: 545, width: 170, height: 120))
            g.setFillColor(c(0.35, 0.95, 0.85, 0.22)); g.fillEllipse(in: CGRect(x: 330, y: 330, width: 120, height: 80))
        }, in: full)
        for (r, a) in [(176.0, 0.10), (122.0, 0.07)] as [(CGFloat, CGFloat)] {
            ctx.addEllipse(in: circle(r)); ctx.setStrokeColor(w(a)); ctx.setLineWidth(2.5); ctx.strokePath()
        }
        ctx.draw(blurred(5) { g in
            let arc = CGMutablePath()
            arc.addArc(center: center, radius: 206, startAngle: .pi * 0.56, endAngle: .pi * 1.04, clockwise: false)
            arc.addArc(center: CGPoint(x: 548, y: 478), radius: 182, startAngle: .pi * 1.04, endAngle: .pi * 0.56, clockwise: true)
            arc.closeSubpath()
            g.addPath(arc); g.clip()
            g.drawLinearGradient(grad([w(0.42), w(0.0)]), start: CGPoint(x: 380, y: 680), end: CGPoint(x: 330, y: 420), options: [])
        }, in: full)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: 368, y: 618, width: 46, height: 30)); ctx.setFillColor(w(0.85)); ctx.fillPath()
        ctx.restoreGState()

        // —— 播放三角：磨砂白玻璃，浮在镜片上 ——
        let tri = roundedTriangle(cx: 526, cy: 508, h: 158, r: 22)
        ctx.draw(blurred(12) { g in g.translateBy(x: 0, y: -8); g.addPath(tri); g.setFillColor(c(0, 0, 0, 0.55)); g.fillPath() }, in: full)
        ctx.saveGState()
        ctx.addPath(tri); ctx.clip()
        ctx.drawLinearGradient(grad([w(0.97), c(0.82, 0.89, 0.98, 0.86)]), start: CGPoint(x: 512, y: 590), end: CGPoint(x: 512, y: 430), options: [])
        ctx.restoreGState()
        rim(ctx, tri, width: 5, top: 1.0, bottom: 0.25, bounds: CGRect(x: 455, y: 430, width: 145, height: 160))
    }
}
