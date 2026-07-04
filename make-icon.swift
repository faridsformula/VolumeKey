import Cocoa

let dir = ProcessInfo.processInfo.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

func render(size: Int) -> Data? {
    let s = CGFloat(size)
    let canvas = NSImage(size: NSSize(width: s, height: s))
    canvas.lockFocus()
    // Background: macOS-app-style rounded square with subtle gradient (deep blue → dark navy)
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                          xRadius: s * 0.225, yRadius: s * 0.225)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.50, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.04, green: 0.18, blue: 0.55, alpha: 1)
    ])!
    bg.addClip()
    gradient.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)

    // Speaker symbol centered, white
    let pt = s * 0.55
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold)
    let sym = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    sym.draw(at: .zero, from: NSRect(origin: .zero, size: sym.size), operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: sym.size).fill(using: .sourceIn)
    tinted.unlockFocus()
    let symRect = NSRect(x: (s - tinted.size.width)/2, y: (s - tinted.size.height)/2,
                         width: tinted.size.width, height: tinted.size.height)
    tinted.draw(in: symRect)
    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let bm = NSBitmapImageRep(data: tiff),
          let png = bm.representation(using: .png, properties: [:]) else { return nil }
    return png
}

// macOS iconset requires these sizes (1x and 2x for each base)
let sizes: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for entry in sizes {
    if let png = render(size: entry.size) {
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(entry.name)"))
        print("Wrote \(entry.name)")
    }
}
