import AppKit
let output = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: output).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(red: 0.06, green: 0.075, blue: 0.085, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 218, yRadius: 218).fill()
        NSColor(white: 1, alpha: 0.08).setStroke()
        let border = NSBezierPath(roundedRect: NSRect(x: 41, y: 41, width: 942, height: 942), xRadius: 218, yRadius: 218)
        border.lineWidth = 3; border.stroke()
        context.translateBy(x: 512, y: 512); context.rotate(by: -0.2); context.translateBy(x: -512, y: -512)
        NSColor(red: 0.65, green: 0.94, blue: 0.77, alpha: 1).setFill()
        for (x, height) in [(290.0, 235.0), (456.0, 450.0), (622.0, 330.0)] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 282, width: 112, height: height), xRadius: 56, yRadius: 56).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output + "/AppIcon.icns"]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
try FileManager.default.removeItem(at: iconset)
