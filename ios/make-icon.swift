import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let source = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let destination = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL
guard let input = CGImageSourceCreateWithURL(source, nil),
      let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
          bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { exit(1) }
context.setFillColor(red: 0.035, green: 0.075, blue: 0.15, alpha: 1)
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.interpolationQuality = .high
let scale = 870 / CGFloat(max(image.width, image.height))
let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
context.draw(image, in: CGRect(x: (1024 - width) / 2, y: (1024 - height) / 2, width: width, height: height))
guard let icon = context.makeImage(),
      let output = CGImageDestinationCreateWithURL(destination, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(output, icon, nil)
guard CGImageDestinationFinalize(output) else { exit(1) }
