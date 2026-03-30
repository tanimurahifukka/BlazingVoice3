import Foundation

@MainActor
final class ModelManager: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var downloadStatus: String = ""
    @Published var isDownloading = false
    @Published var availableModels: [ModelInfo] = []

    struct ModelInfo: Identifiable, Codable {
        let id: String
        let name: String
        let sizeGB: Double
        let backend: EngineBackend
        let huggingFaceId: String
        let recommended: Bool

        var isDownloaded: Bool {
            switch backend {
            case .mlx: return true
            case .llama: return Self.findGGUF(name: name) != nil
            }
        }

        /// Search multiple paths for GGUF files
        static func findGGUF(name: String) -> String? {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let searchPaths = [
                "\(home)/models/\(name)",
                "\(home)/Desktop/hayabusa/models/\(name)",
                "\(home)/Desktop/BlazingVoice3/models/\(name)",
            ]
            // Also check HuggingFace cache
            let cacheBase = "\(home)/.cache/huggingface/hub"
            if let dirs = try? FileManager.default.contentsOfDirectory(atPath: cacheBase) {
                for dir in dirs where dir.hasPrefix("models--") {
                    let snapshotDir = "\(cacheBase)/\(dir)/snapshots"
                    if let snapshots = try? FileManager.default.contentsOfDirectory(atPath: snapshotDir),
                       let snap = snapshots.first {
                        let path = "\(snapshotDir)/\(snap)/\(name)"
                        if FileManager.default.fileExists(atPath: path) {
                            return path
                        }
                    }
                }
            }

            for path in searchPaths {
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
            return nil
        }
    }

    enum EngineBackend: String, Codable, CaseIterable, Sendable {
        case llama
        case mlx
    }

    static let defaultModels: [ModelInfo] = [
        // llama (GGUF)
        ModelInfo(
            id: "qwen3.5-9b-gguf",
            name: "Qwen3.5-9B-Q4_K_M.gguf",
            sizeGB: 5.5,
            backend: .llama,
            huggingFaceId: "unsloth/Qwen3.5-9B-GGUF",
            recommended: false
        ),
        ModelInfo(
            id: "qwen3.5-4b-gguf",
            name: "Qwen3.5-4B-Q4_K_M.gguf",
            sizeGB: 2.7,
            backend: .llama,
            huggingFaceId: "unsloth/Qwen3.5-4B-GGUF",
            recommended: true
        ),
        ModelInfo(
            id: "qwen3.5-1.5b-gguf",
            name: "Qwen3.5-1.5B-Q4_K_M.gguf",
            sizeGB: 1.1,
            backend: .llama,
            huggingFaceId: "unsloth/Qwen3.5-1.5B-GGUF",
            recommended: false
        ),
        ModelInfo(
            id: "qwen3-8b-gguf",
            name: "Qwen3-8B-Q4_K_M.gguf",
            sizeGB: 4.9,
            backend: .llama,
            huggingFaceId: "unsloth/Qwen3-8B-GGUF",
            recommended: false
        ),
        // MLX
        ModelInfo(
            id: "qwen3.5-4b-mlx",
            name: "Qwen3.5-4B-MLX-4bit",
            sizeGB: 2.5,
            backend: .mlx,
            huggingFaceId: "mlx-community/Qwen3.5-4B-MLX-4bit",
            recommended: false
        ),
        ModelInfo(
            id: "qwen3.5-9b-mlx",
            name: "Qwen3.5-9B-MLX-4bit",
            sizeGB: 5.0,
            backend: .mlx,
            huggingFaceId: "mlx-community/Qwen3.5-9B-MLX-4bit",
            recommended: false
        ),
    ]

    init() {
        self.availableModels = Self.defaultModels
        scanLocalModels()
    }

    /// Create an inference engine for the selected model.
    /// LlamaEngine init is synchronous and heavy (loads model into GPU),
    /// so we dispatch it off the main thread.
    nonisolated func createEngine(
        for model: ModelInfo,
        slotCount: Int = 2,
        kvQuantize: KVQuantizeMode = .off,
        maxMemoryGB: Double? = nil
    ) async throws -> any InferenceEngine {
        switch model.backend {
        case .llama:
            guard let path = ModelInfo.findGGUF(name: model.name) else {
                throw BlazingError.modelNotFound(model.name)
            }
            // Dispatch heavy model load off main thread
            return try await Task.detached(priority: .userInitiated) {
                try LlamaEngine.withQuantization(
                    modelPath: path,
                    slotCount: slotCount,
                    kvQuantize: kvQuantize
                )
            }.value
        case .mlx:
            return try await MLXEngine(
                modelId: model.huggingFaceId,
                slotCount: slotCount,
                maxMemoryGB: maxMemoryGB
            )
        }
    }

    /// Callback for download progress updates: (progress 0-1, downloadedBytes, totalBytes)
    var onDownloadProgress: ((Double, Int64, Int64) -> Void)?

    /// Download a GGUF model from HuggingFace with progress reporting.
    func downloadModel(_ model: ModelInfo) async throws {
        guard model.backend == .llama else { return }

        isDownloading = true
        downloadStatus = "\(model.name) ダウンロード中..."
        downloadProgress = 0
        defer { isDownloading = false }

        let modelsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("models")
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let destPath = modelsDir.appendingPathComponent(model.name)

        // Already downloaded?
        if FileManager.default.fileExists(atPath: destPath.path) {
            downloadProgress = 1.0
            downloadStatus = "既にダウンロード済: \(model.name)"
            return
        }

        // Direct HTTPS download from HuggingFace
        let urlString = "https://huggingface.co/\(model.huggingFaceId)/resolve/main/\(model.name)"
        guard let url = URL(string: urlString) else {
            throw BlazingError.downloadFailed("Invalid URL: \(urlString)")
        }

        NSLog("[BlazingVoice3] Downloading %@ (%.1f GB) from %@", model.name, model.sizeGB, urlString)

        let delegate = DownloadProgressDelegate { [weak self] progress, downloaded, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadProgress = progress
                self.downloadStatus = String(
                    format: "%@ ダウンロード中... %@/%@",
                    model.name,
                    Self.formatBytes(downloaded),
                    total > 0 ? Self.formatBytes(total) : "?"
                )
                self.onDownloadProgress?(progress, downloaded, total)
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (tempURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BlazingError.downloadFailed("HTTP \(statusCode): \(urlString)")
        }

        try FileManager.default.moveItem(at: tempURL, to: destPath)

        downloadProgress = 1.0
        downloadStatus = "ダウンロード完了: \(model.name)"
        NSLog("[BlazingVoice3] Download complete: %@", destPath.path)

        scanLocalModels()
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    /// Scan local storage for available GGUF models
    func scanLocalModels() {
        var found = Self.defaultModels

        let searchDirs = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("models"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/hayabusa/models"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/BlazingVoice3/models"),
        ]

        for dir in searchDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files where file.hasSuffix(".gguf") {
                let alreadyKnown = found.contains { $0.name == file }
                if !alreadyKnown {
                    let fullPath = dir.appendingPathComponent(file).path
                    let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath)
                    let sizeGB = Double(attrs?[.size] as? UInt64 ?? 0) / 1_073_741_824

                    found.append(ModelInfo(
                        id: "local-\(file)",
                        name: file,
                        sizeGB: sizeGB,
                        backend: .llama,
                        huggingFaceId: "",
                        recommended: false
                    ))
                }
            }
        }

        self.availableModels = found
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double, Int64, Int64) -> Void

    init(onProgress: @escaping (Double, Int64, Int64) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = -1
        }
        onProgress(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled by the async download(from:) call
    }
}
