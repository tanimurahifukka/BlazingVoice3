import Foundation

enum AppVersion {
    static let major = 4
    static let minor = 0
    static let patch = 5

    /// ビルド日時 (自動生成)
    static let buildDate: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd.HHmm"
        return f.string(from: Date())
    }()

    /// 短いバージョン: "4.0.5"
    static var short: String {
        "\(major).\(minor).\(patch)"
    }

    /// フルバージョン: "4.0.5 (20260328.2230)"
    static var full: String {
        "\(short) (\(buildDate))"
    }

    /// バンドル用: "4.0.5.20260328"
    static var bundle: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return "\(short).\(f.string(from: Date()))"
    }
}
