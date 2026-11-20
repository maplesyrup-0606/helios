// Renders the Helios app icon to a 1024px PNG: two terminal panes (local and remote) joined by
// a glowing bridge with a sun at its center, forming an "H".
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

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    // macOS icon grid: ~824px body centered in the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = rounded(body, 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 44, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    color(0x121212).setFill()
    squircle.fill()
    ctx.restoreGState()

    ctx.saveGState()
    squircle.addClip()

    // Charcoal from the Ghostty theme, lit from above, with a warm bloom behind the bridge.
    gradient([color(0x363636), color(0x1f1f1f), color(0x101010)], [0, 0.5, 1]).draw(in: body, angle: -90)
    let center = CGPoint(x: 512, y: 512)
    gradient([color(0xff8700, 0.42), color(0xff8700, 0.12), color(0xff8700, 0)], [0, 0.45, 1])
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 420, options: [])

    // The two panes: glassy pillars with a screen inset, a prompt, and a few lines of "output".
    for x in [222.0, 634.0] as [CGFloat] {
        let pillar = CGRect(x: x, y: 214, width: 168, height: 596)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        let shape = rounded(pillar, 52)
        gradient([color(0x575757), color(0x2e2e2e), color(0x232323)], [0, 0.55, 1]).draw(in: shape, angle: -90)
        ctx.restoreGState()

        // Top-edge highlight and hairline border.
        ctx.saveGState()
        rounded(pillar, 52).addClip()
        gradient([color(0xffffff, 0.16), color(0xffffff, 0)], [0, 1])
            .draw(in: CGRect(x: pillar.minX, y: pillar.maxY - 120, width: pillar.width, height: 120), angle: -90)
        ctx.restoreGState()
        color(0xffffff, 0.14).setStroke()
        let border = rounded(pillar.insetBy(dx: 1.5, dy: 1.5), 50)
        border.lineWidth = 3
        border.stroke()

        // Screen inset.
        let screen = rounded(pillar.insetBy(dx: 22, dy: 22), 34)
        color(0x161616, 0.85).setFill()
        screen.fill()

        // Prompt ">" in the theme's blue, with a soft glow.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 14, color: color(0x87afd7, 0.8).cgColor)
        let prompt = NSBezierPath()
        prompt.lineWidth = 17
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.move(to: CGPoint(x: x + 50, y: 742))
        prompt.line(to: CGPoint(x: x + 84, y: 718))
        prompt.line(to: CGPoint(x: x + 50, y: 694))
        color(0x87afd7).setStroke()
        prompt.stroke()
        ctx.restoreGState()

        // Output lines below the bridge.
        for (i, width) in [86.0, 58.0, 74.0].enumerated() {
            let line = rounded(CGRect(x: x + 48, y: 372 - CGFloat(i) * 44, width: CGFloat(width), height: 14), 7)
            color(0xbcbcbc, 0.32).setFill()
            line.fill()
        }
    }

    // The bridge between the panes (the SSH link), glowing.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46, color: color(0xff8700, 0.95).cgColor)
    let bridge = rounded(CGRect(x: 372, y: 480, width: 280, height: 64), 32)
    gradient([color(0xff8700), color(0xffaf5f), color(0xffd787), color(0xffaf5f), color(0xff8700)],
             [0, 0.25, 0.5, 0.75, 1]).draw(in: bridge, angle: 0)
    ctx.restoreGState()

    // The sun at the center of the bridge.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: color(0xffd787).cgColor)
    let sun = NSBezierPath(ovalIn: CGRect(x: center.x - 62, y: center.y - 62, width: 124, height: 124))
    gradient([color(0xffffff), color(0xfff1c7), color(0xffd787)], [0, 0.45, 1])
        .draw(in: sun, relativeCenterPosition: NSPoint(x: -0.25, y: 0.3))
    ctx.restoreGState()

    ctx.restoreGState()

    // Hairline edge highlight.
    color(0xffffff, 0.10).setStroke()
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
