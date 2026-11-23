// Run from the project root with the output PNG path as the argument.
import AppKit
import CoreGraphics
let art = NSImage(contentsOfFile: "Sources/Stillframe/Resources/Welcome.jpg")!
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.current = context
let box = NSBezierPath(roundedRect: NSRect(x: 74, y: 74, width: 876, height: 876), xRadius: 192, yRadius: 192)
let gradient = NSGradient(starting: NSColor(srgbRed: 0.25, green: 0.38, blue: 0.30, alpha: 1),
                          ending: NSColor(srgbRed: 0.10, green: 0.19, blue: 0.15, alpha: 1))!
gradient.draw(in: box, angle: -65)
// A translucent curved reflection and a bright rim read as glass even at Dock size.
NSGraphicsContext.saveGraphicsState()
box.addClip()
let reflection = NSBezierPath()
reflection.move(to: NSPoint(x: 40, y: 650))
reflection.curve(to: NSPoint(x: 984, y: 846), controlPoint1: NSPoint(x: 332, y: 820), controlPoint2: NSPoint(x: 695, y: 660))
reflection.line(to: NSPoint(x: 984, y: 984))
reflection.line(to: NSPoint(x: 40, y: 984))
reflection.close()
NSGradient(starting: .white.withAlphaComponent(0.23), ending: .white.withAlphaComponent(0.035))!.draw(in: reflection, angle: -65)
NSGraphicsContext.restoreGraphicsState()
let rim = NSBezierPath(roundedRect: box.bounds.insetBy(dx: 3, dy: 3), xRadius: 190, yRadius: 190)
rim.lineWidth = 6
NSColor.white.withAlphaComponent(0.38).setStroke()
rim.stroke()
func printCard(_ degrees: CGFloat, x: CGFloat, y: CGFloat, isFront: Bool) {
    NSGraphicsContext.saveGraphicsState()
    let cg = context.cgContext
    cg.translateBy(x: x, y: y)
    cg.rotate(by: degrees * .pi / 180)
    cg.setShadow(offset: CGSize(width: 1, height: -7), blur: 19, color: NSColor.black.withAlphaComponent(0.36).cgColor)
    let frame = NSBezierPath(roundedRect: NSRect(x: -268, y: -204, width: 536, height: 408), xRadius: 10, yRadius: 10)
    NSColor(srgbRed: 0.97, green: 0.96, blue: 0.91, alpha: 1).setFill()
    frame.fill()
    cg.setShadow(offset: .zero, blur: 0, color: nil)
    let pic = NSRect(x: -248, y: -164, width: 496, height: 347)
    if isFront {
        let width = art.size.height * pic.width / pic.height
        art.draw(in: pic, from: NSRect(x: (art.size.width - width) / 2, y: 0, width: width, height: art.size.height), operation: .sourceOver, fraction: 1)
        NSGradient(starting: .white.withAlphaComponent(0.12), ending: .clear)!.draw(in: pic, angle: -70)
    } else {
        NSColor(srgbRed: 0.66, green: 0.73, blue: 0.63, alpha: 1).setFill()
        pic.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}
printCard(12, x: 458, y: 551, isFront: false)
printCard(-6, x: 554, y: 486, isFront: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
