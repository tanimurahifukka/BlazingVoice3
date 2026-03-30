import Foundation

/// User-configurable text replacement dictionary for medical terminology correction.
/// Optimised for large dictionaries (40K+ entries) via length-bucketed lookup.
final class UserDictionary: ObservableObject, @unchecked Sendable {
    struct Entry: Identifiable, Codable {
        let id: UUID
        var from: String
        var to: String
        var isEnabled: Bool

        init(from: String, to: String, isEnabled: Bool = true) {
            self.id = UUID()
            self.from = from
            self.to = to
            self.isEnabled = isEnabled
        }
    }

    @Published var entries: [Entry] = []

    /// Fast lookup: from-string → to-string, rebuilt when entries change.
    private var replacementMap: [String: String] = [:]
    /// Unique key lengths present in replacementMap, sorted descending (longest first).
    private var keyLengths: [Int] = []

    private let storageKey = "blazingvoice3.dictionary"

    init() {
        load()
        if entries.isEmpty {
            loadPresets()
        }
        rebuildLookup()
    }

    // MARK: - Replacement (hot path)

    /// Apply dictionary replacements using longest-match-first scanning.
    /// Much faster than iterating 42K entries with `replacingOccurrences`.
    func applyReplacements(to text: String) async -> String {
        guard !replacementMap.isEmpty else { return text }

        let chars = Array(text)
        var result = ""
        result.reserveCapacity(chars.count)
        var i = 0

        while i < chars.count {
            var matched = false
            // Try longest keys first
            for len in keyLengths {
                let end = i + len
                guard end <= chars.count else { continue }
                let substr = String(chars[i..<end])
                if let replacement = replacementMap[substr] {
                    result += replacement
                    i = end
                    matched = true
                    break
                }
            }
            if !matched {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    // MARK: - Mutation

    func addEntry(from: String, to: String) {
        entries.append(Entry(from: from, to: to))
        save()
        rebuildLookup()
    }

    func removeEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
        rebuildLookup()
    }

    func toggleEntry(_ entry: Entry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].isEnabled.toggle()
            save()
            rebuildLookup()
        }
    }

    // MARK: - Lookup rebuild

    private func rebuildLookup() {
        var map: [String: String] = [:]
        map.reserveCapacity(entries.count)
        var lengths = Set<Int>()
        for entry in entries where entry.isEnabled && !entry.from.isEmpty && entry.from != entry.to {
            map[entry.from] = entry.to
            lengths.insert(entry.from.count)
        }
        replacementMap = map
        keyLengths = lengths.sorted(by: >) // longest first
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return
        }
        entries = decoded
    }

    // MARK: - Presets

    func loadPresets() {
        // Try loading from bundled CSV resource first
        if loadPresetsFromCSV() { return }

        // Fallback to hardcoded basics
        let presets: [(String, String)] = [
            ("アトピー", "アトピー性皮膚炎"),
            ("じんましん", "蕁麻疹"),
            ("しっしん", "湿疹"),
            ("ヘルペス", "単純ヘルペス"),
            ("たいじょうほうしん", "帯状疱疹"),
            ("かんせん", "乾癬"),
            ("だつもう", "脱毛症"),
            ("ステロイド", "ステロイド外用薬"),
            ("ほしつ", "保湿剤"),
            ("めんえき", "免疫抑制剤"),
            ("にきび", "尋常性痤瘡"),
            ("みずむし", "足白癬"),
            ("いぼ", "尋常性疣贅"),
            ("やけど", "熱傷"),
            ("ひやけ", "日光皮膚炎"),
            ("あざ", "色素性母斑"),
            ("ほくろ", "色素性母斑"),
            ("とびひ", "伝染性膿痂疹"),
            ("たむし", "体部白癬"),
            ("かぶれ", "接触皮膚炎"),
        ]

        for (from, to) in presets {
            entries.append(Entry(from: from, to: to))
        }
        save()
    }

    /// Load presets from bundled DictionaryPreset.csv
    private func loadPresetsFromCSV() -> Bool {
        guard let url = Bundle.main.url(forResource: "DictionaryPreset", withExtension: "csv")
                ?? Bundle.module_safe?.url(forResource: "DictionaryPreset", withExtension: "csv") else {
            NSLog("[Dictionary] DictionaryPreset.csv not found in bundle")
            return false
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("[Dictionary] Failed to read DictionaryPreset.csv")
            return false
        }

        var count = 0
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.components(separatedBy: ",")
            guard parts.count >= 2 else { continue }
            let from = parts[0]
            let to = parts[1]
            let enabled = parts.count > 2 ? (parts[2] == "true") : true

            guard !from.isEmpty, from != to else { continue }
            entries.append(Entry(from: from, to: to, isEnabled: enabled))
            count += 1
        }

        if count > 0 {
            save()
            NSLog("[Dictionary] Loaded %d preset entries from CSV", count)
            return true
        }
        return false
    }

    // MARK: - CSV Import/Export

    func exportCSV() -> String {
        entries.map { "\($0.from),\($0.to),\($0.isEnabled)" }.joined(separator: "\n")
    }

    func importCSV(_ csv: String) {
        let lines = csv.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.components(separatedBy: ",")
            guard parts.count >= 2 else { continue }
            let enabled = parts.count > 2 ? (parts[2] == "true") : true
            entries.append(Entry(from: parts[0], to: parts[1], isEnabled: enabled))
        }
        save()
        rebuildLookup()
    }
}

// MARK: - Bundle helper for SPM

private extension Bundle {
    /// Safe access to Bundle.module (only available in SPM targets with resources)
    static var module_safe: Bundle? {
        // SPM generates Bundle.module, but it may crash if no resources are bundled.
        // Find the bundle by name as fallback.
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"),
        ].compactMap { $0 }

        for base in candidates {
            let bundlePath = base.appendingPathComponent("BlazingVoice3_BlazingVoice3.bundle")
            if let bundle = Bundle(url: bundlePath) {
                return bundle
            }
        }
        return nil
    }
}
