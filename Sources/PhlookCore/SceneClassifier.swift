import Foundation
import ImageIO
import Vision

/// On-device scene/object classification via `VNClassifyImageRequest` — no
/// network, no custom models, just Vision's built-in ~1000-label taxonomy
/// mapped down to the curated `SceneCategory` set. Mirrors `KindDetector`'s
/// shape: a pure mapping layer (`categories(forIdentifiers:threshold:)`,
/// thoroughly tested) plus a thin Vision-calling entry point.
public enum SceneClassifier {
    /// identifier substring (lowercased) → categories it maps to. Order
    /// doesn't matter; a single identifier can contribute multiple bits
    /// (e.g. "beach" implies both `.beach` and `.water`).
    static let substringTable: [(substring: String, categories: [SceneCategory])] = [
        ("beach", [.beach, .water]),
        ("coast", [.beach, .water]),
        ("food", [.food]),
        ("meal", [.food]),
        ("fruit", [.food]),
        ("vegetable", [.food]),
        ("dish", [.food]),
        ("dog", [.animal]),
        ("cat", [.animal]),
        ("animal", [.animal]),
        ("bird", [.animal]),
        ("pet", [.animal]),
        ("wildlife", [.animal]),
        ("car", [.vehicle]),
        ("vehicle", [.vehicle]),
        ("truck", [.vehicle]),
        ("motorcycle", [.vehicle]),
        ("bicycle", [.vehicle]),
        ("bus", [.vehicle]),
        ("plant", [.plant, .nature]),
        ("flower", [.plant, .nature]),
        ("tree", [.plant, .nature]),
        ("forest", [.nature, .plant]),
        ("mountain", [.nature]),
        ("landscape", [.nature]),
        ("document", [.document, .text]),
        ("text", [.text]),
        ("paper", [.document]),
        ("receipt", [.document, .text]),
        ("sky", [.sky]),
        ("cloud", [.sky]),
        ("sunset", [.sky, .nature]),
        ("sunrise", [.sky, .nature]),
        ("building", [.building]),
        ("architecture", [.building]),
        ("house", [.building]),
        ("skyscraper", [.building]),
        ("water", [.water]),
        ("sea", [.water]),
        ("lake", [.water]),
        ("river", [.water]),
        ("ocean", [.water]),
        ("art", [.art]),
        ("painting", [.art]),
        ("drawing", [.art]),
        ("sculpture", [.art]),
    ]

    /// Pure mapping: raw VN identifier/confidence pairs → OR'd `SceneCategory`
    /// bitmask. No Vision call here — this is the thoroughly-tested unit.
    public static func categories(forIdentifiers identifiers: [(String, Double)], threshold: Double) -> Int {
        var mask = 0
        for (identifier, confidence) in identifiers {
            guard confidence >= threshold else { continue }
            let lower = identifier.lowercased()
            for entry in substringTable where lower.contains(entry.substring) {
                for category in entry.categories {
                    mask |= category.rawValue
                }
            }
        }
        return mask
    }

    /// Opens the file, downsamples to ~512px (Vision is scale-tolerant and
    /// this keeps a ~10k-image backfill pass cheap), runs
    /// `VNClassifyImageRequest`, and maps the results via
    /// `categories(forIdentifiers:threshold:)`. Returns 0 on any failure
    /// (unreadable file, no observations, etc.) — never throws, mirroring
    /// `KindDetector.flags(forImageAt:)`'s "best effort" shape.
    public static func classify(imageAt url: URL, threshold: Double = 0.35) -> Int {
        guard let cgImage = downsampledCGImage(at: url, maxPixel: 512) else { return 0 }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNClassifyImageRequest()
        do {
            try handler.perform([request])
        } catch {
            return 0
        }
        guard let observations = request.results else { return 0 }
        let identifiers = observations.map { ($0.identifier, Double($0.confidence)) }
        return categories(forIdentifiers: identifiers, threshold: threshold)
    }

    /// Decode at a bounded pixel size so classification stays cheap over a
    /// large library — mirrors `ViewerView.downsampledImage(at:maxPixel:)`.
    private static func downsampledCGImage(at url: URL, maxPixel: CGFloat) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
