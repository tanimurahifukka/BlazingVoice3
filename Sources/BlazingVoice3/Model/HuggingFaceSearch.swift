import Foundation

/// Thin async client for HuggingFace's public model listing / tree API.
/// Scoped to GGUF model discovery — no auth, no caching.
enum HuggingFaceAPI {
    struct Repo: Identifiable, Decodable, Sendable, Hashable {
        let id: String
        let downloads: Int?
        let likes: Int?
    }

    struct File: Identifiable, Decodable, Sendable, Hashable {
        let path: String
        let size: Int64?
        let type: String
        var id: String { path }
    }

    /// Search for repositories, sorted by download count (desc).
    /// `filter` maps to the HF `filter` query param (e.g. "gguf"); nil sends none.
    static func searchRepos(query: String, filter: String? = nil, limit: Int = 30) async throws -> [Repo] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let filter {
            items.append(URLQueryItem(name: "filter", value: filter))
        }
        components.queryItems = items
        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: url)
        try verifyOK(response)
        return try JSONDecoder().decode([Repo].self, from: data)
    }

    /// List files at the repository root matching `fileExtension` (e.g. ".gguf", ".bin").
    /// Nested paths are filtered out to keep the download path + local filename symmetrical.
    static func listFiles(repoId: String, extension fileExtension: String) async throws -> [File] {
        let escaped = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        guard let url = URL(string: "https://huggingface.co/api/models/\(escaped)/tree/main") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        try verifyOK(response)
        let entries = try JSONDecoder().decode([File].self, from: data)
        let ext = fileExtension.lowercased()
        return entries
            .filter { $0.type == "file" && $0.path.lowercased().hasSuffix(ext) && !$0.path.contains("/") }
            .sorted { ($0.size ?? 0) < ($1.size ?? 0) }
    }

    private static func verifyOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.init(rawValue: http.statusCode))
        }
    }
}
