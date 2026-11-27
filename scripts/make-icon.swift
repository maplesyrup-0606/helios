// Renders the Helios app icon to a 1024px PNG: a solar eclipse — a dark disk ringed by a glowing
// corona — with a terminal prompt inside.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> NSGradient {
    NSGradient(colors: colors, atLocations: locations, colorSpace: .sRGB)!
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
func circle(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    // macOS icon grid: ~824px body centered in the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = rounded(body, 185)
    let center = CGPoint(x: 512, y: 512)
    let diskRadius: CGFloat = 252

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 44, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    color(0x111111).setFill()
    squircle.fill()
    ctx.restoreGState()

    ctx.saveGState()
    squircle.addClip()

    // Warm charcoal (the Ghostty theme's background, lit by the corona).
    gradient([color(0x2a2522), color(0x0e0e0e)], [0, 1]).draw(in: body, angle: -90)

    // Corona: a wide soft halo peaking just outside the disk.
    gradient([color(0xff8700, 0), color(0xff8700, 0.58), color(0xffaf5f, 0.24), color(0xff8700, 0.06), color(0xff8700, 0)],
             [0, 0.6, 0.7, 0.86, 1])
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 430, options: [])

    // Bright rim: the sun's edge peeking around the moon.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 42, color: color(0xffd787).cgColor)
    gradient([color(0xfff1c7), color(0xffd787), color(0xffaf5f)], [0, 0.5, 1])
        .draw(in: circle(center, diskRadius + 10), angle: 90)
    ctx.restoreGState()

    // The disk, nudged down so the rim is thickest on top (lit from above), with a faint sheen.
    let disk = circle(CGPoint(x: center.x, y: center.y - 4), diskRadius)
    gradient([color(0x1d1c1b), color(0x0b0b0b)], [0, 1]).draw(in: disk, angle: -90)
    ctx.saveGState()
    disk.addClip()
    gradient([color(0xffffff, 0.06), color(0xffffff, 0)], [0, 1])
        .draw(fromCenter: CGPoint(x: center.x - 70, y: center.y + 120), radius: 0,
              toCenter: CGPoint(x: center.x - 70, y: center.y + 120), radius: 260, options: [])
    ctx.restoreGState()

    // `>_` prompt, glowing, optically centered in the disk.
    let s: CGFloat = 1.3
    let origin = CGPoint(x: center.x - 96 * s + 2, y: center.y - 22 * s)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22, color: color(0xff8700, 0.9).cgColor)
    let chevron = NSBezierPath()
    chevron.lineWidth = 26 * s
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: CGPoint(x: origin.x, y: origin.y + 60 * s))
    chevron.line(to: CGPoint(x: origin.x + 52 * s, y: origin.y + 24 * s))
    chevron.line(to: CGPoint(x: origin.x, y: origin.y - 12 * s))
    color(0xffd787).setStroke()
    chevron.stroke()
    color(0xffd787).setFill()
    rounded(CGRect(x: origin.x + 80 * s, y: origin.y - 25 * s, width: 72 * s, height: 26 * s), 13 * s).fill()
    ctx.restoreGState()

    ctx.restoreGState()

    // Hairline edge highlight.
    color(0xffffff, 0.09).setStroke()
    squircle.lineWidth = 3
    squircle.stroke()
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
