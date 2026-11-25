import AppKit
import Foundation

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: source),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
          bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.current = context
NSColor(red: 0.035, green: 0.075, blue: 0.15, alpha: 1).setFill()
NSBezierPath.fill(NSRect(x: 0, y: 0, width: 1024, height: 1024))
context.imageInterpolation = .high
let scale = min(870 / image.size.width, 870 / image.size.height)
let width = image.size.width * scale, height = image.size.height * scale
image.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2, width: width, height: height))
context.flushGraphics()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: destination)
