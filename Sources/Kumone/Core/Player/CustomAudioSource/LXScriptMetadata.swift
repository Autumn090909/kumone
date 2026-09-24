import Foundation

/// The JSDoc-style header LX requires at the top of a custom-source script:
///
/// ```js
/// /**
///  * @name 测试音乐源
///  * @description 我只是一个测试音乐源哦
///  * @version 1.0.0
///  * @author xxx
///  * @homepage http://xxx
///  */
/// ```
///
/// Parsed without running the script, so Settings can list an imported source
/// by the name its author chose before (or without) ever executing it.
struct LXScriptMetadata: Hashable, Sendable {
    var name: String?
    var summary: String?
    var version: String?
    var author: String?
    var homepage: String?

    /// Only the leading block comment is consulted, and only the first 4 KB of
    /// the file, so an `@name` appearing later in the script body (a comment
    /// above a function, say) cannot rename the source.
    static func parse(from script: String) -> LXScriptMetadata {
        guard let block = leadingBlockComment(in: String(script.prefix(4_096))) else {
            return LXScriptMetadata()
        }
        return LXScriptMetadata(
            name: field("name", in: block),
            summary: field("description", in: block),
            version: field("version", in: block),
            author: field("author", in: block),
            homepage: field("homepage", in: block)
        )
    }

    private static func leadingBlockComment(in text: String) -> String? {
        guard let open = text.range(of: "/*"),
              let close = text.range(of: "*/", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    private static func field(_ key: String, in block: String) -> String? {
        // `[ \t]+` rather than `\s+`: a bare "@name" with no value on the line
        // must not swallow the next line as its value.
        let pattern = "@\(key)[ \\t]+([^\\r\\n]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: block,
                range: NSRange(block.startIndex..<block.endIndex, in: block)
              ),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: block)
        else { return nil }

        let value = block[captured].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
