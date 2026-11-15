import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
func integer(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ((3 - $0) * 8)) }) }
var entries = Data()
let types = [16: ["icp4", "ic11"], 32: ["icp5", "ic12"], 128: ["ic07", "ic13"], 256: ["ic08", "ic14"], 512: ["ic09", "ic10"]]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let base = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
        NSGradient(starting: NSColor(calibratedRed: 0.19, green: 0.68, blue: 0.83, alpha: 1),
                   ending: NSColor(calibratedRed: 0.12, green: 0.29, blue: 0.68, alpha: 1))!.draw(in: base, angle: -65)
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: NSRect(x: 215, y: 215, width: 594, height: 594)).fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        for inset in [244.0, 276.0, 308.0] {
            let ring = NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset))
            ring.lineWidth = 3; ring.stroke()
        }
        NSColor.white.setFill()
        let note = NSBezierPath()
        note.move(to: NSPoint(x: 450, y: 367)); note.line(to: NSPoint(x: 450, y: 665))
        note.line(to: NSPoint(x: 692, y: 717)); note.line(to: NSPoint(x: 692, y: 421))
        note.line(to: NSPoint(x: 646, y: 421)); note.line(to: NSPoint(x: 646, y: 611))
        note.line(to: NSPoint(x: 496, y: 579)); note.line(to: NSPoint(x: 496, y: 367)); note.close(); note.fill()
        NSBezierPath(ovalIn: NSRect(x: 337, y: 304, width: 160, height: 106)).fill()
        NSBezierPath(ovalIn: NSRect(x: 533, y: 359, width: 160, height: 106)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: destination.appendingPathComponent(name))
        entries.append(Data(types[size]![scale - 1].utf8))
        entries.append(integer(png.count + 8))
        entries.append(png)
    }
}
let icon = Data("icns".utf8) + integer(entries.count + 8) + entries
guard let image = NSImage(data: icon), image.isValid else { fatalError("Invalid icon") }
try icon.write(to: destination.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
