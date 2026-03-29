import Foundation

/// High-speed regex-based filler removal for real-time streaming.
/// No LLM needed — runs in microseconds.
enum FillerRemover {
    /// Japanese fillers and verbal tics to remove
    private static let fillerPatterns: [(pattern: String, replacement: String)] = [
        // Standalone fillers (with optional particles)
        (#"(?:^|(?<=。|、|\s))えーっと[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))えーと[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))えっと[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))あのー?[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))そのー?[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))なんか[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))まあ[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))うーん[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))うん[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))ちょっと[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))えー[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))あー[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))まぁ[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))ねえ?[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))ほら[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))やっぱり?[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))なんていうか[、。]?\s*"#, ""),
        (#"(?:^|(?<=。|、|\s))いわゆる[、。]?\s*"#, ""),
        // Repeated punctuation cleanup
        (#"、、+"#, "、"),
        (#"。。+"#, "。"),
        (#"\s{2,}"#, " "),
    ]

    private static let compiledPatterns: [(regex: NSRegularExpression, replacement: String)] = {
        fillerPatterns.compactMap { item in
            guard let regex = try? NSRegularExpression(pattern: item.pattern, options: []) else { return nil }
            return (regex, item.replacement)
        }
    }()

    /// Remove fillers from text. Fast enough for real-time use.
    static func clean(_ text: String) -> String {
        var result = text
        for (regex, replacement) in compiledPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compute the diff between previous and new cleaned text for incremental input.
    /// Returns only the new characters to type.
    static func incrementalDiff(previous: String, current: String) -> String {
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        // Text was revised — return full replacement
        return current
    }
}
