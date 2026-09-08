import AppKit
import Foundation

@main
struct BrandExporter {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "BrandExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass an output directory"])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let iconset = output.appendingPathComponent("MemoryMonitor.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
                try png(width: size * scale, height: size * scale, to: iconset.appendingPathComponent(name)) {
                    MemoryMonitorBrand.drawIcon(in: $0, pixels: size * scale)
                }
            }
        }
        try png(width: 1024, height: 1024, to: output.appendingPathComponent("MemoryMonitor.png")) {
            MemoryMonitorBrand.drawIcon(in: $0, pixels: 1024)
        }
        for (name, ink) in [("Logo", UInt32(0x159EC4)), ("Logo-Black", UInt32(0x172124)), ("Logo-White", UInt32(0xFFFFFF))] {
            try png(width: 1024, height: 1024, to: output.appendingPathComponent(name + ".png")) {
                MemoryMonitorBrand.drawSymbol(in: $0, rect: CGRect(x: 96, y: 96, width: 832, height: 832),
                                              color: MemoryMonitorBrand.color(ink))
            }
            try svg(to: output.appendingPathComponent(name + ".svg"), ink: ink)
        }
        try pdf(to: output.appendingPathComponent("Logo.pdf"))
        try proof(to: output.appendingPathComponent("Logo-Preview.png"))
        print("Exported brand assets: \(output.path)")
    }

    private static func png(width: Int, height: Int, to url: URL, draw: (CGContext) -> Void) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure() }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw failure()
        }
        try data.write(to: url)
    }

    private static func svg(to url: URL, ink: UInt32) throws {
        let root = XMLElement(name: "svg", uri: "http://www.w3.org/2000/svg")
        root.addNamespace(XMLNode.namespace(withName: "", stringValue: "http://www.w3.org/2000/svg") as! XMLNode)
        for (name, value) in [("viewBox", "0 0 1024 1024"), ("width", "1024"), ("height", "1024"), ("role", "img")] {
            root.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
        }
        root.addChild(XMLElement(name: "title", stringValue: "Memory Monitor"))
        let path = MemoryMonitorBrand.symbolPath(in: CGRect(x: 96, y: 96, width: 832, height: 832))
        var segments: [String] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            func point(_ index: Int) -> String { String(format: "%.3f %.3f", locale: Locale(identifier: "en_US_POSIX"),
                                                       element.points[index].x, element.points[index].y) }
            switch element.type {
            case .moveToPoint: segments.append("M " + point(0))
            case .addLineToPoint: segments.append("L " + point(0))
            case .addQuadCurveToPoint: segments.append("Q " + point(0) + " " + point(1))
            case .addCurveToPoint: segments.append("C " + point(0) + " " + point(1) + " " + point(2))
            case .closeSubpath: segments.append("Z")
            @unknown default: break
            }
        }
        let element = XMLElement(name: "path")
        element.addAttribute(XMLNode.attribute(withName: "d", stringValue: segments.joined(separator: " ")) as! XMLNode)
        element.addAttribute(XMLNode.attribute(withName: "fill", stringValue: String(format: "#%06X", ink)) as! XMLNode)
        root.addChild(element)
        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        try document.xmlData(options: .nodePrettyPrint).write(to: url)
    }

    private static func pdf(to url: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else { throw failure() }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: 1024)
        context.scaleBy(x: 1, y: -1)
        MemoryMonitorBrand.drawSymbol(in: context, rect: CGRect(x: 96, y: 96, width: 832, height: 832),
                                      color: MemoryMonitorBrand.color(0x172124))
        context.endPDFPage()
        context.closePDF()
    }

    private static func proof(to url: URL) throws {
        try png(width: 1280, height: 800, to: url) { context in
            context.setFillColor(MemoryMonitorBrand.color(0xF3F5F5))
            context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
            context.saveGState()
            context.translateBy(x: 75, y: 42)
            MemoryMonitorBrand.drawIcon(in: context, pixels: 560)
            context.restoreGState()
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            ("Memory\nMonitor" as NSString).draw(at: NSPoint(x: 710, y: 210), withAttributes: [
                .font: NSFont.systemFont(ofSize: 66, weight: .semibold),
                .foregroundColor: NSColor(cgColor: MemoryMonitorBrand.color(0x172124))!
            ])
            NSGraphicsContext.restoreGraphicsState()
            context.setFillColor(MemoryMonitorBrand.color(0x172124))
            context.fill(CGRect(x: 0, y: 622, width: 1280, height: 178))
            for (index, size) in [16, 32, 64, 96].enumerated() {
                MemoryMonitorBrand.drawSymbol(in: context, rect: CGRect(x: 120 + index * 160, y: 710 - size / 2,
                    width: size, height: size), color: MemoryMonitorBrand.color(0xF3FFFD))
            }
            MemoryMonitorBrand.drawSymbol(in: context, rect: CGRect(x: 844, y: 662, width: 96, height: 96),
                                          color: MemoryMonitorBrand.color(0x2BD1E8))
            context.setFillColor(MemoryMonitorBrand.color(0xF3F5F5))
            context.fill(CGRect(x: 1048, y: 622, width: 232, height: 178))
            MemoryMonitorBrand.drawSymbol(in: context, rect: CGRect(x: 1116, y: 662, width: 96, height: 96),
                                          color: MemoryMonitorBrand.color(0x172124))
        }
    }

    private static func failure() -> NSError { NSError(domain: "BrandExporter", code: 2) }
}
