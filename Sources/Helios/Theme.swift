import AppKit
import SwiftTerm
import SwiftUI

/// Colors and font read from the user's Ghostty config, so Helios matches their terminal.
/// App chrome (sidebar, header, borders) is derived from the same background/foreground.
struct Theme {
    var background = NSColor(hex: "#262626")!
    var foreground = NSColor(hex: "#bcbcbc")!
    var cursor: NSColor?
    var selection = NSColor(hex: "#87afd7")!
    /// ANSI colors 0–15.
    var palette: [NSColor] = [
        "#1c1c1c", "#af5f5f", "#5f875f", "#87875f", "#5f87af", "#5f5f87", "#5f8787", "#6c6c6c",
        "#444444", "#ff8700", "#87af87", "#ffffaf", "#87afd7", "#8787af", "#5fafaf", "#ffffff",
    ].map { NSColor(hex: $0)! }
    var fontFamily = "Fira Code"
    var fontSize: CGFloat = 13

    static let current = Theme.loadGhostty()

    // MARK: Derived chrome colors

    var canvas: SwiftUI.Color { SwiftUI.Color(nsColor: background) }
    var sidebar: SwiftUI.Color { SwiftUI.Color(nsColor: background.mixed(with: .black, 0.30)) }
    var surface: SwiftUI.Color { SwiftUI.Color(nsColor: background.mixed(with: foreground, 0.08)) }
    var border: SwiftUI.Color { SwiftUI.Color(nsColor: background.mixed(with: foreground, 0.14)) }
    var text: SwiftUI.Color { SwiftUI.Color(nsColor: foreground) }
    var textMuted: SwiftUI.Color { SwiftUI.Color(nsColor: foreground.mixed(with: background, 0.45)) }
    var textFaint: SwiftUI.Color { SwiftUI.Color(nsColor: foreground.mixed(with: background, 0.65)) }
    var accent: SwiftUI.Color { SwiftUI.Color(nsColor: selection) }
    var ok: SwiftUI.Color { SwiftUI.Color(nsColor: palette[10]) }
    var warn: SwiftUI.Color { SwiftUI.Color(nsColor: palette[9]) }
    var error: SwiftUI.Color { SwiftUI.Color(nsColor: palette[1]) }

    /// Tint laid over the frosted window background.
    var glassTint: SwiftUI.Color { SwiftUI.Color(nsColor: background.mixed(with: .black, 0.45)).opacity(0.72) }
    /// Foreground-derived overlays so chrome works on any Ghostty background.
    var hairline: SwiftUI.Color { text.opacity(0.08) }
    var fill: SwiftUI.Color { text.opacity(0.05) }
    var fillStrong: SwiftUI.Color { text.opacity(0.10) }

    /// A stable per-context accent picked from the bright ANSI colors.
    func hue(for id: UUID) -> SwiftUI.Color {
        let choices = [12, 10, 13, 14, 9, 11, 4, 5]
        let byte = Int(id.uuid.0) ^ Int(id.uuid.5)
        return SwiftUI.Color(nsColor: palette[choices[byte % choices.count]])
    }

    func monoFont(size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
        let size = size ?? fontSize
        let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: weight == .regular ? 5 : 7, size: size)
        return font ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(monoFont(size: size, weight: weight))
    }

    // MARK: Applying to terminals

    @MainActor
    func apply(to view: TerminalView) {
        view.font = monoFont()
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = cursor ?? foreground
        view.selectedTextBackgroundColor = selection
        view.installColors(palette.map { $0.terminalColor })
    }

    // MARK: Loading

    private static let configPaths = [
        "~/.config/ghostty/config",
        "~/Library/Application Support/com.mitchellh.ghostty/config",
    ]

    /// User themes first, then the ones bundled with Ghostty.app.
    private static let themeDirs = [
        "~/.config/ghostty/themes",
        "~/Library/Application Support/com.mitchellh.ghostty/themes",
        "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
        "~/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
    ]

    /// `theme = light:A,dark:B` picks B; Helios is dark-only.
    private static func darkThemeName(_ value: String) -> String {
        guard value.contains(":") else { return value }
        for part in value.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == "dark" { return pair[1] }
        }
        return value
    }

    static func loadGhostty() -> Theme {
        var theme = Theme()
        for path in configPaths {
            guard let text = try? String(contentsOfFile: expandTilde(path), encoding: .utf8) else { continue }
            // A named theme is applied first; explicit keys in the config override it.
            if let name = values(in: text)["theme"]?.last.map(darkThemeName) {
                for dir in themeDirs {
                    if let themeText = try? String(contentsOfFile: expandTilde("\(dir)/\(name)"), encoding: .utf8) {
                        theme.merge(values(in: themeText))
                        break
                    }
                }
            }
            theme.merge(values(in: text))
        }
        return theme
    }

    /// Parses `key = value` lines; keys may repeat (e.g. `palette`).
    private static func values(in text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            result[key, default: []].append(value)
        }
        return result
    }

    private mutating func merge(_ values: [String: [String]]) {
        if let c = values["background"]?.last.flatMap(NSColor.init(hex:)) { background = c }
        if let c = values["foreground"]?.last.flatMap(NSColor.init(hex:)) { foreground = c }
        if let c = values["cursor-color"]?.last.flatMap(NSColor.init(hex:)) { cursor = c }
        if let c = values["selection-background"]?.last.flatMap(NSColor.init(hex:)) { selection = c }
        if let family = values["font-family"]?.first(where: { !$0.isEmpty }) { fontFamily = family }
        if let size = values["font-size"]?.last.flatMap(Double.init) { fontSize = CGFloat(size) }
        for entry in values["palette"] ?? [] {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let index = Int(parts[0]), (0..<16).contains(index),
                  let color = NSColor(hex: String(parts[1])) else { continue }
            palette[index] = color
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                  green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255,
                  alpha: 1)
    }

    func mixed(with other: NSColor, _ fraction: CGFloat) -> NSColor {
        blended(withFraction: fraction, of: other) ?? self
    }

    var terminalColor: SwiftTerm.Color {
        let c = usingColorSpace(.sRGB) ?? self
        return SwiftTerm.Color(red8: UInt16(c.redComponent * 255), green8: UInt16(c.greenComponent * 255), blue8: UInt16(c.blueComponent * 255))
    }
}
