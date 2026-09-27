// Reproducible original vector artwork. Run with the project's environment.sh.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = CGPath(roundedRect: CGRect(x: 96, y: 96, width: 832, height: 832), cornerWidth: 188, cornerHeight: 188, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 22, color: CGColor(gray: 0.05, alpha: 0.25))
    context.addPath(tile); context.setFillColor(CGColor(red: 0.08, green: 0.30, blue: 0.28, alpha: 1)); context.fillPath()
    context.restoreGState()
    context.saveGState(); context.addPath(tile); context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [CGColor(red: 0.06, green: 0.28, blue: 0.26, alpha: 1), CGColor(red: 0.13, green: 0.53, blue: 0.46, alpha: 1)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 840, y: 180), end: CGPoint(x: 230, y: 950), options: [])
    context.restoreGState()
    context.setLineWidth(48); context.setLineCap(.round)
    context.setStrokeColor(CGColor(red: 0.90, green: 0.98, blue: 0.93, alpha: 1))
    for (x, height) in [(304.0, 100.0), (408.0, 248.0), (512.0, 394.0), (616.0, 248.0), (720.0, 100.0)] {
        context.move(to: CGPoint(x: x, y: 512 - height / 2)); context.addLine(to: CGPoint(x: x, y: 512 + height / 2)); context.strokePath()
    }
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not save app icon") }
}
