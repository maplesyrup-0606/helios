/// Undoes the hard wrapping TUIs like claude apply to long lines: each continuation row is
/// indented, and the line break either split a word at the pane edge or replaced a space.
enum WrappedText {
    /// Returns the single line `text` was wrapped from, or nil if it doesn't look wrapped.
    /// `firstColumn` is where the selection's first row starts on screen; `cols` is the pane width.
    static func unwrap(_ text: String, firstColumn: Int, cols: Int) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { trimTrailingSpaces(String($0)) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count > 1, let second = lines.dropFirst().first else { return nil }

        let indent = second.prefix { $0 == " " }.count
        guard indent > 0 else { return nil }
        let bodies = lines.dropFirst().map { line -> Substring? in
            let body = line.dropFirst(indent)
            guard line.prefix(indent).allSatisfy({ $0 == " " }), body.first.map({ $0 != " " }) == true
            else { return nil }
            return body
        }
        guard bodies.allSatisfy({ $0 != nil }) else { return nil }

        var result = String(lines[0].drop { $0 == " " })
        var rowWidth = firstColumn + lines[0].count
        for case let body? in bodies {
            let nextWord = body.prefix { $0 != " " }.count
            if rowWidth >= cols - 1 {
                result += body                  // split mid-word at the pane edge
            } else if rowWidth + 1 + nextWord > cols {
                result += " " + body            // word didn't fit, so the break replaced a space
            } else {
                return nil                      // a real line break
            }
            rowWidth = indent + body.count
        }
        return result
    }

    private static func trimTrailingSpaces(_ line: String) -> String {
        var line = line
        while line.last == " " { line.removeLast() }
        return line
    }
}
