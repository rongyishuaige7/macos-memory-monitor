import CoreGraphics
import Foundation

enum MemoryMonitorBrand {
    static func ringPath() -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: 512, y: 512), radius: 292,
                    startAngle: -.pi / 4, endAngle: .pi * 19 / 12, clockwise: false)
        return path.copy(strokingWithWidth: 62, lineCap: .round, lineJoin: .round, miterLimit: 2)
    }

    static func monogramPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 354, y: 630))
        path.addLine(to: CGPoint(x: 354, y: 394))
        path.addLine(to: CGPoint(x: 512, y: 548))
        path.addLine(to: CGPoint(x: 670, y: 394))
        path.addLine(to: CGPoint(x: 670, y: 630))
        return path.copy(strokingWithWidth: 72, lineCap: .round, lineJoin: .round, miterLimit: 2)
    }

    static func symbolPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addPath(ringPath())
        path.addPath(monogramPath())
        let bounds = path.boundingBoxOfPath
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        var transform = CGAffineTransform(translationX: rect.midX - bounds.midX * scale,
                                         y: rect.midY - bounds.midY * scale).scaledBy(x: scale, y: scale)
        return path.copy(using: &transform)!
    }

    static func drawSymbol(in context: CGContext, rect: CGRect, color: CGColor) {
        context.addPath(symbolPath(in: rect))
        context.setFillColor(color)
        context.fillPath()
    }

    static func drawIcon(in context: CGContext, pixels: Int) {
        context.saveGState()
        defer { context.restoreGState() }
        let scale = CGFloat(pixels) / 1024
        context.scaleBy(x: scale, y: scale)
        let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                          cornerWidth: 184, cornerHeight: 184, transform: nil)
        context.saveGState()
        // Quartz shadow dimensions ignore the context transform.
        context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 26 * scale,
                          color: CGColor(gray: 0, alpha: 0.25))
        context.addPath(tile)
        context.setFillColor(color(0x111A1D))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(tile)
        context.clip()
        gradient(context, colors: [color(0x344246), color(0x172124), color(0x0D1417)],
                 start: CGPoint(x: 200, y: 80), end: CGPoint(x: 850, y: 980))
        context.restoreGState()
        context.addPath(tile)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
        context.setLineWidth(2)
        context.strokePath()

        context.saveGState()
        context.addPath(ringPath())
        context.clip()
        gradient(context, colors: [color(0x80F1D6), color(0x2BD1E8), color(0x2794EF)],
                 start: CGPoint(x: 280, y: 220), end: CGPoint(x: 720, y: 820))
        context.restoreGState()
        context.saveGState()
        context.addPath(monogramPath())
        context.clip()
        gradient(context, colors: [color(0xF3FFFD), color(0xC9F3F1)],
                 start: CGPoint(x: 512, y: 350), end: CGPoint(x: 512, y: 700))
        context.restoreGState()
    }

    static func color(_ rgb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private static func gradient(_ context: CGContext, colors: [CGColor], start: CGPoint, end: CGPoint) {
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
