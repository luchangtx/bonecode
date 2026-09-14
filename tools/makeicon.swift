// Generates the BoneCode app icon at every size macOS needs.
// Compiled and run by build.sh; no external dependencies.

import AppKit

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.iconset"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

/// One iconset entry: file name suffix and the pixel size to render.
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func render(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    let s = CGFloat(size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let context = NSGraphicsContext.current?.cgContext else { return nil }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // ---- rounded square with a vertical gradient
    let inset = s * 0.055
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = (s - inset * 2) * 0.235
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    let top = NSColor(srgbRed: 0.196, green: 0.243, blue: 0.353, alpha: 1)
    let bottom = NSColor(srgbRed: 0.086, green: 0.106, blue: 0.161, alpha: 1)
    if let gradient = NSGradient(starting: top, ending: bottom) {
        gradient.draw(in: shape, angle: -90)
    } else {
        top.setFill()
        shape.fill()
    }

    // ---- subtle inner border so the icon reads on light and dark backgrounds
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10).setStroke()
    shape.lineWidth = max(1, s * 0.006)
    shape.stroke()

    // ---- accent underline
    let barHeight = max(1.5, s * 0.032)
    let barWidth = (s - inset * 2) * 0.42
    let bar = NSBezierPath(roundedRect: NSRect(
        x: (s - barWidth) / 2,
        y: body.minY + (s - inset * 2) * 0.135,
        width: barWidth,
        height: barHeight
    ), xRadius: barHeight / 2, yRadius: barHeight / 2)
    NSColor(srgbRed: 0.208, green: 0.455, blue: 0.945, alpha: 1).setFill()
    bar.fill()

    // ---- "</>" glyph
    let text = "</>" as NSString
    let fontSize = s * 0.40
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(srgbRed: 0.937, green: 0.957, blue: 1.0, alpha: 1)
    ]
    let textSize = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (s - textSize.width) / 2,
                          y: (s - textSize.height) / 2 + s * 0.045),
              withAttributes: attributes)

    return rep.representation(using: .png, properties: [:])
}

var written = 0
for (name, size) in entries {
    guard let data = render(size: size) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        continue
    }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(name)
    do {
        try data.write(to: url)
        written += 1
    } catch {
        FileHandle.standardError.write(Data("failed to write \(name): \(error)\n".utf8))
    }
}
print("wrote \(written)/\(entries.count) icon images to \(outputDirectory)")
