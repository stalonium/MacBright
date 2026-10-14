// Renders the MacBright app icon and packs it into an .icns.
// Usage: swiftc Scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources/AppIcon.icns [preview.png]
import AppKit
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let previewPath = CommandLine.arguments.dropFirst(2).first

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0)
    )!
}

/// The macOS icon outline: a rounded rect with Apple's continuous ("squircle")
/// corners, using the well-known cubic approximation of UIKit's corner curve.
func squircle(in rect: CGRect, radius r: CGFloat) -> CGPath {
    // Each corner as (distance back along the incoming edge, distance along the outgoing edge), in units of r.
    let segments: [(to: (CGFloat, CGFloat), c1: (CGFloat, CGFloat), c2: (CGFloat, CGFloat))] = [
        ((0.63149399, 0.07491100), (1.08849323, 0), (0.86840689, 0)),
        ((0.07491100, 0.63149399), (0.37282392, 0.16905899), (0.16905899, 0.37282392)),
        ((0, 1.52866471), (0, 0.86840689), (0, 1.08849323)),
    ]
    let corners: [(corner: CGPoint, incoming: CGVector, outgoing: CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]

    let path = CGMutablePath()
    for (index, c) in corners.enumerated() {
        func point(_ p: (CGFloat, CGFloat)) -> CGPoint {
            CGPoint(
                x: c.corner.x - p.0 * r * c.incoming.dx + p.1 * r * c.outgoing.dx,
                y: c.corner.y - p.0 * r * c.incoming.dy + p.1 * r * c.outgoing.dy
            )
        }
        let start = point((1.52866471, 0))
        if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
        for segment in segments {
            path.addCurve(to: point(segment.to), control1: point(segment.c1), control2: point(segment.c2))
        }
    }
    path.closeSubpath()
    return path
}

/// Draws the icon on a 1024×1024 canvas (scaled to `size`).
func drawIcon(in ctx: CGContext, size: CGFloat) {
    let scale = size / 1024
    ctx.scaleBy(x: scale, y: scale)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body, radius: 185)
    let sun = CGPoint(x: 512, y: 512)

    // Drop shadow under the tile, like system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1747B8))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Clear-sky tile: bright blue at the top, deeper blue at the bottom.
    ctx.drawLinearGradient(
        gradient([(0, color(0x62B6FF)), (0.5, color(0x2F7DF2)), (1, color(0x1A4BCF))]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
    )

    // Soft halo around the sun — the "beyond SDR" light.
    ctx.drawRadialGradient(
        gradient([(0, color(0xFFFBEA, 0.9)), (0.5, color(0xFFF4D0, 0.32)), (1, color(0xFFFFFF, 0))]),
        startCenter: sun, startRadius: 150, endCenter: sun, endRadius: 330, options: []
    )

    // Rays: eight rounded strokes, long and short alternating.
    let rays = CGMutablePath()
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 2
        let inner: CGFloat = 222
        let outer: CGFloat = i.isMultiple(of: 2) ? 336 : 300
        rays.move(to: CGPoint(x: sun.x + cos(angle) * inner, y: sun.y + sin(angle) * inner))
        rays.addLine(to: CGPoint(x: sun.x + cos(angle) * outer, y: sun.y + sin(angle) * outer))
    }
    ctx.saveGState()
    ctx.addPath(rays.copy(strokingWithWidth: 46, lineCap: .round, lineJoin: .round, miterLimit: 1))
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([(0, color(0xFFF3B8)), (0.55, color(0xFFDA5C)), (1, color(0xFFC233))]),
        startCenter: sun, startRadius: 210, endCenter: sun, endRadius: 345, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // Sun disc: white-hot core fading to gold at the rim.
    let discRadius: CGFloat = 170
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60 * scale, color: color(0xFFD25A, 0.9))
    ctx.addEllipse(in: CGRect(x: sun.x - discRadius, y: sun.y - discRadius, width: discRadius * 2, height: discRadius * 2))
    ctx.setFillColor(color(0xFFD25A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: sun.x - discRadius, y: sun.y - discRadius, width: discRadius * 2, height: discRadius * 2))
    ctx.clip()
    let core = CGPoint(x: sun.x - 40, y: sun.y + 45)
    ctx.drawRadialGradient(
        gradient([(0, color(0xFFFFFF)), (0.45, color(0xFFF6D6)), (0.8, color(0xFFDB6E)), (1, color(0xFFB830))]),
        startCenter: core, startRadius: 0, endCenter: sun, endRadius: discRadius, options: [.drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // Subtle glass sheen on the upper half of the tile.
    ctx.drawLinearGradient(
        gradient([(0, color(0xFFFFFF, 0.14)), (1, color(0xFFFFFF, 0))]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: []
    )
    ctx.restoreGState()

    // Hairline inner edge to keep the tile crisp on dark backgrounds.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func renderPNG(size: Int, to url: URL) {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, size: CGFloat(size))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    renderPNG(size: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    renderPNG(size: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if let previewPath {
    renderPNG(size: 1024, to: URL(fileURLWithPath: previewPath))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output)")
