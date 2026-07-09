#!/usr/bin/env swift
// Renders the PHLOOK app icon: a rounded-square blue→indigo gradient with a
// white photo glyph. Output: a 1024×1024 PNG at argv[1].
import AppKit

let side: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/phlook-icon.png"

let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded-square (macOS icon corner ratio ≈ 0.2237) clip.
let rect = CGRect(x: 0, y: 0, width: side, height: side)
let radius = side * 0.2237
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

// Diagonal blue → indigo gradient.
let space = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.33, green: 0.56, blue: 0.96, alpha: 1),
    CGColor(red: 0.49, green: 0.36, blue: 0.98, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side),
                       end: CGPoint(x: side, y: 0), options: [])

// White photo glyph (SF Symbol), tinted solid white, centered.
let cfg = NSImage.SymbolConfiguration(pointSize: 560, weight: .regular)
if let raw = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let gs = raw.size
    let white = NSImage(size: gs, flipped: false) { r in
        raw.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let target = NSRect(x: (side - gs.width) / 2, y: (side - gs.height) / 2,
                        width: gs.width, height: gs.height)
    white.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
               respectFlipped: true, hints: nil)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("icon render failed\n".utf8)); exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
