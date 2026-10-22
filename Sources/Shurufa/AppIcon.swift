import AppKit

/// 同一份矢量轮廓用于应用图标、界面标志与菜单栏模板图标。
enum FanyiXIcon {
    private static let green = CGColor(red: 0.10, green: 0.76, blue: 0.55, alpha: 1)

    private static func letter(in rect: CGRect) -> CGPath {
        let points: [CGPoint] = [
            CGPoint(x: 0.315, y: 0.22), CGPoint(x: 0.435, y: 0.22),
            CGPoint(x: 0.435, y: 0.44), CGPoint(x: 0.66, y: 0.44),
            CGPoint(x: 0.66, y: 0.55), CGPoint(x: 0.435, y: 0.55),
            CGPoint(x: 0.435, y: 0.67), CGPoint(x: 0.745, y: 0.67),
            CGPoint(x: 0.745, y: 0.78), CGPoint(x: 0.315, y: 0.78)
        ].map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        let radius = rect.width * 0.012
        let path = CGMutablePath()
        for index in points.indices {
            let point = points[index]
            let previous = points[(index + points.count - 1) % points.count]
            let next = points[(index + 1) % points.count]
            func toward(_ other: CGPoint) -> CGPoint {
                let distance = hypot(other.x - point.x, other.y - point.y)
                let fraction = min(radius / distance, 0.5)
                return CGPoint(x: point.x + (other.x - point.x) * fraction, y: point.y + (other.y - point.y) * fraction)
            }
            let start = toward(previous), end = toward(next)
            if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
            path.addQuadCurve(to: end, control: point)
        }
        path.closeSubpath()
        return path
    }

    static func bitmap(pixels: Int, appIcon: Bool = false, template: Bool = false) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.clear(canvas)
        let tile = appIcon ? canvas.insetBy(dx: canvas.width * 0.10, dy: canvas.height * 0.10) : canvas
        if !template {
            context.setFillColor(green)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.height * 0.225, transform: nil))
            context.fillPath()
        }
        let letterBounds = template
            ? CGRect(x: canvas.width * -0.189, y: canvas.height * -0.15, width: canvas.width * 1.3, height: canvas.height * 1.3) : tile
        context.setFillColor(template ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.addPath(letter(in: letterBounds)); context.fillPath()
        return bitmap
    }

    static func image(size: CGFloat, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        let bitmap = bitmap(pixels: Int((size * 2).rounded()), template: template)
        bitmap.size = image.size
        image.addRepresentation(bitmap)
        image.isTemplate = template
        return image
    }
}
