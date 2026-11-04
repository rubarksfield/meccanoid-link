#!/usr/bin/env swift
// Original Meccanoid Link artwork, drawn using AppKit. No vendor marks or assets.
// Run: swift script/generate_app_icon.swift [optional-output-directory]
import AppKit
import Foundation

let projectDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : projectDirectory.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func colour(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawIcon(size: Int, mac: Bool, filename: String) throws {
    let alpha = mac ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
    guard let colourSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let bitmapContext = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: colourSpace, bitmapInfo: alpha.rawValue
          ) else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create drawing surface"])
    }
    let graphics = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    graphics.shouldAntialias = true
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()

    let tile = mac ? NSRect(x: 64, y: 64, width: 896, height: 896)
                   : NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let tileRadius: CGFloat = mac ? 198 : 0
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tileRadius, yRadius: tileRadius)

    if mac {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.23)
        shadow.shadowBlurRadius = 25
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        colour(0.04, 0.12, 0.28).setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(starting: colour(0.035, 0.10, 0.25), ending: colour(0.12, 0.34, 0.65))!
        .draw(in: tile, angle: 62)

    // Soft, geometric light behind the face, entirely generated from paths.
    colour(0.31, 0.59, 0.95, alpha: 0.14).setFill()
    NSBezierPath(ovalIn: NSRect(x: 250, y: 440, width: 870, height: 870)).fill()
    colour(0.24, 0.50, 0.86, alpha: 0.12).setFill()
    NSBezierPath(ovalIn: NSRect(x: -290, y: -190, width: 820, height: 820)).fill()

    let face = NSRect(x: 176, y: 290, width: 672, height: 444)
    let facePath = NSBezierPath(roundedRect: face, xRadius: 125, yRadius: 125)
    NSGradient(starting: colour(0.07, 0.21, 0.44), ending: colour(0.21, 0.48, 0.78))!
        .draw(in: facePath, angle: 90)
    colour(0.67, 0.84, 1, alpha: 0.25).setStroke()
    facePath.lineWidth = 6
    facePath.stroke()

    for x: CGFloat in [304, 566] {
        let eye = NSRect(x: x, y: 435, width: 154, height: 170)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = colour(0.32, 0.82, 1, alpha: 0.45)
        glow.shadowBlurRadius = 30
        glow.shadowOffset = .zero
        glow.set()
        rounded(eye, radius: 38, fill: colour(0.64, 0.92, 1))
        NSGraphicsContext.restoreGraphicsState()
        let eyePath = NSBezierPath(roundedRect: eye, xRadius: 38, yRadius: 38)
        NSGradient(starting: colour(0.36, 0.76, 0.97), ending: colour(0.88, 0.99, 1))!
            .draw(in: eyePath, angle: 90)
        rounded(NSRect(x: x + 25, y: 551, width: 37, height: 27), radius: 12,
                fill: NSColor.white.withAlphaComponent(0.8))
    }

    // A quiet central notch gives the face a friendly expression at small sizes.
    rounded(NSRect(x: 470, y: 371, width: 84, height: 13), radius: 6.5,
            fill: colour(0.54, 0.76, 0.94, alpha: 0.65))
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = bitmapContext.makeImage(),
          let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    try data.write(to: outputDirectory.appendingPathComponent(filename))
}

var images: [[String: String]] = []
try drawIcon(size: 1024, mac: false, filename: "AppIcon-iOS-1024.png")
images.append(["filename": "AppIcon-iOS-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"])
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "AppIcon-mac-\(points)@\(scale)x.png"
        try drawIcon(size: points * scale, mac: true, filename: filename)
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let catalog: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Generated \(images.count) original app icon images in \(outputDirectory.path)")
