#!/usr/bin/env swift
import AppKit
import Foundation

// Original vector artwork. Run from the project root to regenerate the bundle icon.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let packaging = root.appendingPathComponent("Packaging")

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func rounded(_ rect: NSRect, _ radius: CGFloat, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func line(_ points: [NSPoint], width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    color.setStroke(); path.stroke()
}
func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let plate = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832), xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.shadowBlurRadius = 24; shadow.set()
    color(0x124467).setFill(); plate.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x246A88), ending: color(0x10334F))!.draw(in: plate, angle: -65)

    NSGraphicsContext.saveGraphicsState()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -16); shadow.shadowBlurRadius = 22; shadow.set()
    rounded(NSRect(x: 276, y: 186, width: 472, height: 652), 62, color(0xF6F8F9))
    NSGraphicsContext.restoreGraphicsState()
    rounded(NSRect(x: 300, y: 206, width: 424, height: 32), 16, color(0xD7E2E8))
    rounded(NSRect(x: 318, y: 410, width: 388, height: 326), 34, color(0xDCEDE9))
    rounded(NSRect(x: 336, y: 428, width: 352, height: 290), 22, color(0xEAF5EF))

    // LCD graph: temperature and humidity, readable even at Dock sizes.
    line([NSPoint(x: 366, y: 636), NSPoint(x: 366, y: 462), NSPoint(x: 656, y: 462)], width: 8, color: color(0xB5CBC7))
    line([NSPoint(x: 384, y: 526), NSPoint(x: 440, y: 562), NSPoint(x: 494, y: 542),
          NSPoint(x: 548, y: 620), NSPoint(x: 602, y: 590), NSPoint(x: 650, y: 638)], width: 18, color: color(0x137E80))
    line([NSPoint(x: 384, y: 502), NSPoint(x: 440, y: 490), NSPoint(x: 494, y: 508),
          NSPoint(x: 548, y: 500), NSPoint(x: 602, y: 532), NSPoint(x: 650, y: 520)], width: 12, color: color(0x4998C0))

    // Sensor marks and a wireless indicator; no vendor branding is used.
    let thermometer = NSBezierPath(roundedRect: NSRect(x: 387, y: 300, width: 30, height: 70), xRadius: 15, yRadius: 15)
    color(0x137E80).setFill(); thermometer.fill()
    NSBezierPath(ovalIn: NSRect(x: 374, y: 272, width: 56, height: 56)).fill()
    let drop = NSBezierPath()
    drop.move(to: NSPoint(x: 492, y: 374))
    drop.curve(to: NSPoint(x: 460, y: 307), controlPoint1: NSPoint(x: 482, y: 353), controlPoint2: NSPoint(x: 460, y: 328))
    drop.curve(to: NSPoint(x: 524, y: 307), controlPoint1: NSPoint(x: 460, y: 262), controlPoint2: NSPoint(x: 524, y: 262))
    drop.curve(to: NSPoint(x: 492, y: 374), controlPoint1: NSPoint(x: 524, y: 328), controlPoint2: NSPoint(x: 502, y: 353))
    color(0x4998C0).setFill(); drop.fill()
    for radius: CGFloat in [28, 49, 70] {
        let arc = NSBezierPath(); arc.lineWidth = 10; arc.lineCapStyle = .round
        arc.appendArc(withCenter: NSPoint(x: 619, y: 285), radius: radius, startAngle: 45, endAngle: 135)
        color(0x137E80).setStroke(); arc.stroke()
    }
    color(0x137E80).setFill(); NSBezierPath(ovalIn: NSRect(x: 612, y: 278, width: 14, height: 14)).fill()
    let title = "TR7" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 42, weight: .bold), .foregroundColor: color(0x24495A)]
    let titleSize = title.size(withAttributes: attributes)
    title.draw(at: NSPoint(x: 512 - titleSize.width / 2, y: 761), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

// Modern ICNS elements contain PNG data, with big-endian container lengths.
// Write the container directly so regeneration also works without iconutil services.
func bigEndian(_ value: Int) -> Data {
    var word = UInt32(value).bigEndian
    return withUnsafeBytes(of: &word) { Data($0) }
}
var elements = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                     ("ic08", 256), ("ic09", 512), ("ic10", 1024),
                     ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)] {
    let png = render(size: size)
    elements.append(Data(type.utf8)); elements.append(bigEndian(png.count + 8)); elements.append(png)
    if size == 1024 { try png.write(to: packaging.appendingPathComponent("TR7Mac.png")) }
}
var icon = Data("icns".utf8); icon.append(bigEndian(elements.count + 8)); icon.append(elements)
try icon.write(to: packaging.appendingPathComponent("TR7Mac.icns"))
guard let loaded = NSImage(contentsOf: packaging.appendingPathComponent("TR7Mac.icns")), loaded.isValid else {
    throw NSError(domain: "TR7Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "The generated icon could not be decoded."])
}
print("Generated Packaging/TR7Mac.icns and Packaging/TR7Mac.png")
