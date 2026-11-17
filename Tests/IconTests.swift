import AppKit

func loadPixels(_ url: URL, size: Int) throws -> [UInt8] {
    let data = try Data(contentsOf: url)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == size, image.height == size else {
        fatalError("Invalid image dimensions: \(url.lastPathComponent), expected \(size)x\(size)")
    }
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: size, height: size,
                                bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    return pixels
}

let original = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let decoded = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let expected = try loadPixels(original.appendingPathComponent(name), size: size * scale)
        let actual = try loadPixels(decoded.appendingPathComponent(name), size: size * scale)
        let meanDifference = Double(zip(actual, expected).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) })
            / Double(expected.count)
        let alphaMatches = stride(from: 3, to: actual.count, by: 4).allSatisfy { actual[$0] == expected[$0] }
        // System conversion of legacy 16/32 px representations can shift edge
        // colors slightly. Require identical alpha and an average error < 2%.
        // PNG-backed Retina and larger representations must match exactly.
        let legacy = scale == 1 && size <= 32
        guard alphaMatches && (legacy ? meanDifference < 5 : actual == expected) else {
            fatalError("ICNS round-trip corrupted \(name): mean channel difference \(meanDifference)")
        }
        print("PASS \(name): dimensions, transparency and artwork verified (mean channel difference \(meanDifference))")
    }
}
