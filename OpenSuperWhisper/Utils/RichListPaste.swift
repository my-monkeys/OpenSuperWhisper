import AppKit

/// A dictation's lists in the two rich forms editors read, offered next to the plain text on the
/// same pasteboard item (#166).
struct RichPasteText: Equatable {
    /// For browsers and Electron apps (Gmail, Notion, Slack), which take `public.html`.
    let html: Data
    /// For the Cocoa text system (TextEdit, Pages, Notes), which prefers RTF and lays out an
    /// HTML paste in Times, whatever the field's own font.
    let rtf: Data
}

/// Turns the "- item" and "1. item" lines a dictation can come out with into real bullets, for
/// the apps known to make lists of them.
///
/// Everything here is decided from the text alone: no structure, no rich text, and the paste is
/// exactly what it was before. The plain string stays on the item with its "- " and "1. "
/// prefixes, so an app that only reads text gets the same lines as always.
enum RichListPaste {

    /// Apps whose fields turn a pasted HTML or RTF list into a list of their own. An allowlist
    /// rather than an opt-out: a terminal or a code editor reads the plain string anyway, but an
    /// app we have not looked at could keep the markup's spacing or fonts, and the plain lines
    /// are never wrong. Browsers are on it for Gmail, Google Docs and the web editors; their
    /// plain text fields read the string like any other app.
    static let richTextApps: Set<String> = [
        "com.apple.notes",
        "com.apple.mail",
        "com.apple.textedit",
        "com.apple.iwork.pages",
        "com.microsoft.word",
        "com.microsoft.outlook",
        "notion.id",
        "com.tinyspeck.slackmacgap",
        "com.apple.safari",
        "com.google.chrome",
        "org.mozilla.firefox",
        "company.thebrowser.browser",
        "com.microsoft.edgemac",
        "com.brave.browser",
    ]

    /// Fewer items than this and a leading dash is more likely punctuation than a list.
    static let minimumItems = 2

    /// Whether AI cleanup should write a dictation's enumerations as "- " lines: only when the
    /// paste will turn them into bullets, so nowhere else gets a new line break it did not ask for.
    static func cleanupWritesLists(into bundleID: String?) -> Bool {
        AppPreferences.shared.pasteListsAsRichText && acceptsRichText(bundleID)
    }

    static func acceptsRichText(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return richTextApps.contains(bundleID.lowercased())
    }

    /// The rich forms of `text` for the app it is pasted into, nil when that app is not one that
    /// takes them or the text holds no list worth formatting.
    static func richText(for text: String, into bundleID: String?) -> RichPasteText? {
        guard acceptsRichText(bundleID), !hasTaskItems(text), let blocks = blocks(of: text) else { return nil }
        guard let rtf = rtf(blocks) else { return nil }
        return RichPasteText(html: Data(html(blocks).utf8), rtf: rtf)
    }

    // MARK: - Structure

    enum Block: Equatable {
        case line(String)
        case list(ordered: Bool, start: Int, items: [String])
    }

    struct Item: Equatable {
        let ordered: Bool
        let number: Int
        let text: String
    }

    /// "- [ ] " lines, which the Notion and Obsidian profiles write for a spoken to-do list (#271).
    /// As plain text Notion makes them to-do blocks; the rich forms would make them bullets that
    /// read "[ ] buy bread", so such a text is pasted plain.
    static func hasTaskItems(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            return trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]")
        }
    }

    /// The text as lines and lists, or nil when it holds no list of at least `minimumItems`.
    ///
    /// Indented items are a nested list, which this does not build: flattened, the rich paste
    /// would lose the levels the plain lines still show, so such a text stays plain.
    static func blocks(of text: String) -> [Block]? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let first = item(in: line) else {
                if isIndentedItem(line) { return nil }
                blocks.append(.line(line))
                index += 1
                continue
            }
            var items = [first.text]
            index += 1
            while let next = nextItem(in: lines, after: &index, like: first) { items.append(next.text) }
            blocks.append(items.count >= minimumItems
                ? .list(ordered: first.ordered, start: first.number, items: items)
                : .line(line))
        }
        return blocks.contains { if case .list = $0 { true } else { false } } ? blocks : nil
    }

    /// The item that continues a list of `first`'s kind, stepping over blank lines between
    /// items, which Markdown reads as one loose list. Leaves `index` on the first line that is
    /// not part of the list.
    private static func nextItem(in lines: [String], after index: inout Int, like first: Item) -> Item? {
        var probe = index
        while probe < lines.count, lines[probe].allSatisfy(\.isWhitespace) { probe += 1 }
        guard probe < lines.count, let next = item(in: lines[probe]), next.ordered == first.ordered
        else { return nil }
        index = probe + 1
        return next
    }

    /// One list item: "- ", "* " or "• ", or a number followed by "." or ")". A single space
    /// before it is allowed, the one fitting the dictation to the caret can put there.
    static func item(in line: String) -> Item? {
        var rest = Substring(line)
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        if let mark = rest.first, bulletMarks.contains(mark) {
            return itemText(rest.dropFirst()).map { Item(ordered: false, number: 1, text: $0) }
        }
        let digits = rest.prefix(while: \.isASCII).prefix(while: \.isNumber)
        guard (1...3).contains(digits.count), let number = Int(digits) else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let close = afterDigits.first, close == "." || close == ")" else { return nil }
        return itemText(afterDigits.dropFirst()).map { Item(ordered: true, number: number, text: $0) }
    }

    static let bulletMarks: Set<Character> = ["-", "*", "•"]

    private static func itemText(_ afterMark: Substring) -> String? {
        guard afterMark.first == " " else { return nil }
        let text = afterMark.drop(while: { $0 == " " })
        return text.allSatisfy(\.isWhitespace) ? nil : String(text)
    }

    private static func isIndentedItem(_ line: String) -> Bool {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        return (indent.contains("\t") || indent.count > 1) && item(in: String(line.dropFirst(indent.count))) != nil
    }

    // MARK: - HTML

    /// A small subset (lists, lines, line breaks) in a div that takes the font of the field it
    /// lands in. The charset is declared because without it an editor may read the bytes as
    /// Latin-1 and mangle every accent.
    static func html(_ blocks: [Block]) -> String {
        var body = ""
        for (index, block) in blocks.enumerated() {
            switch block {
            case .line(let line) where line.allSatisfy(\.isWhitespace):
                body += "<div><br></div>"
            case .line(let line):
                body += "<div>\(escapedLine(line, first: index == 0))</div>"
            case let .list(ordered, start, items):
                let open = ordered ? (start == 1 ? "<ol>" : "<ol start=\"\(start)\">") : "<ul>"
                body += open + items.map { "<li>\(escaped($0))</li>" }.joined() + (ordered ? "</ol>" : "</ul>")
            }
        }
        return "<meta charset=\"utf-8\"><div style=\"font: inherit;\">\(body)</div>"
    }

    /// HTML collapses a leading space, and at the very start of the text that is the space
    /// fitting the dictation to the caret put between its words and the ones before.
    private static func escapedLine(_ line: String, first: Bool) -> String {
        guard first, line.hasPrefix(" ") else { return escaped(line) }
        return "&nbsp;" + escaped(String(line.dropFirst()))
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - RTF

    /// Indents as TextEdit's own lists do, so a pasted list lines up with one made there.
    private static let markerTab: CGFloat = 11
    private static let itemIndent: CGFloat = 36
    /// "1.", the numbering the plain lines use, rather than the bare number of `.decimal`.
    static let orderedMarker = NSTextList.MarkerFormat(rawValue: "{decimal}.")

    /// The lists as the text system stores them: each item a paragraph carrying its `NSTextList`,
    /// with the marker written out between tabs, which is what the RTF writer turns into a list.
    /// No font is set, but the writer still names its default, Helvetica 12 pt, for the whole
    /// text: an app that keeps the source formatting shows the paste in it rather than in the
    /// field's font. That is why `pasteListsAsRichText` starts off.
    static func rtf(_ blocks: [Block]) -> Data? {
        let paragraphs = blocks.flatMap { block -> [(String, NSParagraphStyle?)] in
            switch block {
            case .line(let line): return [(line, nil)]
            case let .list(ordered, start, items): return listParagraphs(ordered: ordered, start: start, items: items)
            }
        }
        let text = NSMutableAttributedString()
        for (index, (line, style)) in paragraphs.enumerated() {
            // The newline ends its paragraph and takes the paragraph's style with it.
            let ending = index < paragraphs.count - 1 ? "\n" : ""
            text.append(NSAttributedString(string: line + ending,
                                           attributes: style.map { [.paragraphStyle: $0] } ?? [:]))
        }
        return try? text.data(from: NSRange(location: 0, length: text.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private static func listParagraphs(ordered: Bool, start: Int,
                                       items: [String]) -> [(String, NSParagraphStyle?)] {
        let list = NSTextList(markerFormat: ordered ? orderedMarker : .disc, options: 0)
        list.startingItemNumber = start
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        style.headIndent = itemIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: markerTab),
                          NSTextTab(textAlignment: .left, location: itemIndent)]
        return items.enumerated().map { offset, item in
            ("\t\(list.marker(forItemNumber: start + offset))\t\(item)", style)
        }
    }
}
