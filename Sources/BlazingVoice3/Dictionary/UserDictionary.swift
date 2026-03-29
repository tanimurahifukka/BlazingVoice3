import Foundation

/// User-configurable text replacement dictionary for medical terminology correction.
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

    private let storageKey = "blazingvoice3.dictionary"

    init() {
        load()
        if entries.isEmpty {
            loadPresets()
        }
    }

    func applyReplacements(to text: String) async -> String {
        var result = text
        for entry in entries where entry.isEnabled {
            result = result.replacingOccurrences(of: entry.from, with: entry.to)
        }
        return result
    }

    func addEntry(from: String, to: String) {
        entries.append(Entry(from: from, to: to))
        save()
    }

    func removeEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    func toggleEntry(_ entry: Entry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].isEnabled.toggle()
            save()
        }
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

    // MARK: - CSV Import/Export

    func exportCSV() -> String {
        entries.map { "\($0.from),\($0.to),\($0.isEnabled)" }.joined(separator: "\n")
    }

    func importCSV(_ csv: String) {
        let lines = csv.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.components(separatedBy: ",")
            guard parts.count >= 2 else { continue }
            let enabled = parts.count > 2 ? (parts[2] == "true") : true
            entries.append(Entry(from: parts[0], to: parts[1], isEnabled: enabled))
        }
        save()
    }
}
