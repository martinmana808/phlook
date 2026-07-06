import Foundation
import CoreGraphics
import ImageIO

public enum TestFixtures {
    public static func writeJPEG(at url: URL, width: Int, height: Int, captureDate: Date? = nil) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw NSError(domain: "TestFixtures", code: 1) }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            throw NSError(domain: "TestFixtures", code: 2)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw NSError(domain: "TestFixtures", code: 3)
        }
        var properties: CFDictionary?
        if let captureDate {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: f.string(from: captureDate)]
            properties = [kCGImagePropertyExifDictionary: exif] as CFDictionary
        }
        CGImageDestinationAddImage(dest, cgImage, properties)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "TestFixtures", code: 4)
        }
    }
}
