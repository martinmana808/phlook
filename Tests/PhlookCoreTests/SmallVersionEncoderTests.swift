import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PhlookCore

struct SmallVersionEncoderTests {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Write a real PNG of the given pixel size so ImageIO can decode it.
    private func writePNG(_ url: URL, w: Int, h: Int) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    }

    private func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    @Test func photoIsDownscaledToLongEdge2048AsJpeg() throws {
        let dir = try tmp()
        let src = dir.appendingPathComponent("big.png")
        try writePNG(src, w: 4000, h: 3000)
        let proxyDir = dir.appendingPathComponent("proxy")

        let out = try SmallVersionEncoder().makeSmallVersion(from: src, fileType: "image", into: proxyDir)

        #expect(out.pathExtension == "jpg")
        #expect(out.deletingPathExtension().lastPathComponent == "big")
        let (w, h) = try #require(pixelSize(out))
        #expect(max(w, h) == 2048)                     // long edge clamped
        #expect(h == 1536)                             // aspect preserved (3000*2048/4000)
        let outSize = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! Int
        let inSize  = try FileManager.default.attributesOfItem(atPath: src.path)[.size] as! Int
        #expect(outSize < inSize)                      // smaller than source
    }

    @Test func unreadableSourceThrows() throws {
        let dir = try tmp()
        #expect(throws: (any Error).self) {
            try SmallVersionEncoder().makeSmallVersion(
                from: dir.appendingPathComponent("nope.png"), fileType: "image",
                into: dir.appendingPathComponent("proxy"))
        }
    }
}
