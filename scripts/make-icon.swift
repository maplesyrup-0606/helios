// Renders the Helios app icon — a total solar eclipse with a terminal prompt in the moon —
// to a 1024px PNG.  Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Deterministic pseudo-random numbers so the icon renders identically every build.
var seed: UInt64 = 0x5EED_4E11_05
func rand() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((seed >> 33) % 10_000) / 10_000
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    // macOS icon grid: ~824px body centered in the 1024 canvas.
    let inset: CGFloat = 100
    let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 44, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    color(0x0c0c0c).setFill()
    squircle.fill()
    ctx.restoreGState()

    ctx.saveGState()
    squircle.addClip()

    // Deep space: near-black with a faint warm lift toward the center.
    NSGradient(colors: [color(0x1e1a17), color(0x0d0d0d), color(0x060606)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(fromCenter: CGPoint(x: size / 2, y: size / 2), radius: 0,
              toCenter: CGPoint(x: size / 2, y: size / 2), radius: 520, options: [.drawsAfterEndingLocation])

    // Starfield.
    for _ in 0..<70 {
        let p = CGPoint(x: inset + rand() * body.width, y: inset + rand() * body.height)
        let dist = hypot(p.x - size / 2, p.y - size / 2)
        guard dist > 300 else { continue }
        let r = 0.8 + rand() * 2.2
        color(0xffffff, 0.15 + rand() * 0.45).setFill()
        NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
    }

    let center = CGPoint(x: size / 2, y: size / 2)
    let moonR: CGFloat = 196

    // Wide outer glow.
    NSGradient(colors: [color(0xff8700, 0.0), color(0xff8700, 0.35), color(0xff5f00, 0.12), color(0xff5f00, 0)],
               atLocations: [0, 0.42, 0.7, 1], colorSpace: .sRGB)!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 470, options: [])

    // Corona streamers: tapered wedges of varying length, additive-looking.
    ctx.setBlendMode(.screen)
    for i in 0..<36 {
        let base = CGFloat(i) / 36 * 2 * .pi + (rand() - 0.5) * 0.12
        let length = moonR + 60 + rand() * (i % 3 == 0 ? 230 : 120)
        let width = 0.035 + rand() * 0.05
        let wedge = NSBezierPath()
        wedge.move(to: CGPoint(x: center.x + cos(base - width) * moonR, y: center.y + sin(base - width) * moonR))
        wedge.line(to: CGPoint(x: center.x + cos(base) * length, y: center.y + sin(base) * length))
        wedge.line(to: CGPoint(x: center.x + cos(base + width) * moonR, y: center.y + sin(base + width) * moonR))
        wedge.close()
        ctx.saveGState()
        wedge.addClip()
        NSGradient(colors: [color(0xffe0b0, 0.55), color(0xffaf5f, 0.25), color(0xff8700, 0)],
                   atLocations: [0, 0.35, 1], colorSpace: .sRGB)!
            .draw(fromCenter: center, radius: moonR, toCenter: center, radius: length, options: [])
        ctx.restoreGState()
    }

    // Inner corona ring hugging the moon's edge.
    NSGradient(colors: [color(0xffffff, 0.95), color(0xffd787, 0.85), color(0xffaf5f, 0.45), color(0xff8700, 0)],
               atLocations: [0, 0.18, 0.45, 1], colorSpace: .sRGB)!
        .draw(fromCenter: center, radius: moonR - 2, toCenter: center, radius: moonR + 95, options: [])
    ctx.setBlendMode(.normal)

    // The moon.
    let moon = NSBezierPath(ovalIn: CGRect(x: center.x - moonR, y: center.y - moonR, width: 2 * moonR, height: 2 * moonR))
    NSGradient(colors: [color(0x1c1c1c), color(0x0a0a0a)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: moon, angle: -55)
    color(0xffd787, 0.35).setStroke()
    moon.lineWidth = 2
    moon.stroke()

    // ">_" glowing faintly inside the moon.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22, color: color(0xff8700, 0.9).cgColor)
    let prompt = NSBezierPath()
    prompt.lineWidth = 24
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    prompt.move(to: CGPoint(x: center.x - 78, y: center.y + 48))
    prompt.line(to: CGPoint(x: center.x - 16, y: center.y))
    prompt.line(to: CGPoint(x: center.x - 78, y: center.y - 48))
    prompt.move(to: CGPoint(x: center.x + 14, y: center.y - 54))
    prompt.line(to: CGPoint(x: center.x + 86, y: center.y - 54))
    color(0xffaf5f).setStroke()
    prompt.stroke()
    ctx.restoreGState()

    // Diamond ring: a bright bead of sunlight on the upper-right rim, with a star glare.
    ctx.setBlendMode(.screen)
    let angle: CGFloat = .pi / 4
    let bead = CGPoint(x: center.x + cos(angle) * (moonR + 4), y: center.y + sin(angle) * (moonR + 4))
    NSGradient(colors: [color(0xffffff, 1), color(0xfff1d6, 0.8), color(0xffaf5f, 0.25), color(0xffaf5f, 0)],
               atLocations: [0, 0.12, 0.4, 1], colorSpace: .sRGB)!
        .draw(fromCenter: bead, radius: 0, toCenter: bead, radius: 120, options: [])
    for (len, thick, rot) in [(150.0, 4.0, 0.0), (150.0, 4.0, CGFloat.pi / 2), (80.0, 2.5, CGFloat.pi / 4), (80.0, 2.5, -CGFloat.pi / 4)] {
        let spike = NSBezierPath()
        let dx = cos(rot) * CGFloat(len), dy = sin(rot) * CGFloat(len)
        spike.move(to: CGPoint(x: bead.x - dx, y: bead.y - dy))
        spike.line(to: CGPoint(x: bead.x, y: bead.y + CGFloat(thick)))
        spike.line(to: CGPoint(x: bead.x + dx, y: bead.y + dy))
        spike.line(to: CGPoint(x: bead.x, y: bead.y - CGFloat(thick)))
        spike.close()
        color(0xffffff, 0.75).setFill()
        spike.fill()
    }
    let core = CGRect(x: bead.x - 14, y: bead.y - 14, width: 28, height: 28)
    color(0xffffff).setFill()
    NSBezierPath(ovalIn: core).fill()
    ctx.setBlendMode(.normal)

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
