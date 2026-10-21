import AppKit
import CoreGraphics
import Foundation

// A macOS application icon must provide its own alpha mask. The PNG in the
// iconset is not automatically clipped to the system's rounded-square shape.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift make-rounded-app-icon.swift artwork.png AppIcon-1024.png")
}

let artworkURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: artworkURL),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(
        data: nil, width: 1024, height: 1024,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
    fatalError("Cannot load artwork or create transparent icon context")
}

let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
context.clear(canvas)
context.interpolationQuality = .high
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

// Apple's Launchpad renders the whole icon canvas. Keep a transparent margin,
// so the white tile matches the apparent footprint of native third-party icons.
// 824pt tile => ~80.5% of the full canvas, with continuous-looking round corners.
let tileSize: CGFloat = 824
let tile = CGRect(x: (1024 - tileSize) / 2,
                  y: (1024 - tileSize) / 2,
                  width: tileSize, height: tileSize)
let corners: CGFloat = 188
let roundedTile = CGPath(
    roundedRect: tile,
    cornerWidth: corners,
    cornerHeight: corners,
    transform: nil
)
context.addPath(roundedTile)
context.clip()
context.draw(source, in: tile)

guard let composited = context.makeImage(),
      let output = NSBitmapImageRep(cgImage: composited)
        .representation(using: .png, properties: [:]) else {
    fatalError("Unable to export rounded icon")
}
try output.write(to: outputURL, options: .atomic)
print("Rounded alpha-masked app icon: \(outputURL.path), tile \(Int(tileSize)) / 1024")
