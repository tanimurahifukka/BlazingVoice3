import SwiftUI

struct HuggingFaceSearchView: View {
    enum Kind {
        case llamaGGUF
        case whisperBin

        var title: String {
            switch self {
            case .llamaGGUF: "HuggingFace から GGUF モデル追加"
            case .whisperBin: "HuggingFace から Whisper モデル取得"
            }
        }

        var initialQuery: String {
            switch self {
            case .llamaGGUF: ""
            case .whisperBin: "whisper.cpp"
            }
        }

        var placeholder: String {
            switch self {
            case .llamaGGUF: "検索キーワード (例: qwen3 gguf)"
            case .whisperBin: "検索キーワード (例: whisper.cpp)"
            }
        }

        var fileExtension: String {
            switch self {
            case .llamaGGUF: ".gguf"
            case .whisperBin: ".bin"
            }
        }

        var searchFilter: String? {
            switch self {
            case .llamaGGUF: "gguf"
            case .whisperBin: nil
            }
        }

        var actionLabel: String {
            switch self {
            case .llamaGGUF: "追加"
            case .whisperBin: "ダウンロード"
            }
        }

        var emptyFilesHint: String {
            switch self {
            case .llamaGGUF: "このリポジトリのルートには .gguf ファイルが見つかりませんでした。"
            case .whisperBin: "このリポジトリのルートには .bin ファイルが見つかりませんでした。"
            }
        }
    }

    let kind: Kind

    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var didInit = false
    @State private var isSearching = false
    @State private var repos: [HuggingFaceAPI.Repo] = []
    @State private var selectedRepo: HuggingFaceAPI.Repo?
    @State private var files: [HuggingFaceAPI.File] = []
    @State private var isLoadingFiles = false
    @State private var errorMessage: String?
    @State private var addedFileIds: Set<String> = []
    @State private var downloadingFileId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(kind.title)
                    .font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(downloadingFileId != nil)
            }

            HStack {
                TextField(kind.placeholder, text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                    .disabled(isSearching || downloadingFileId != nil)
                Button("検索") { runSearch() }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching || downloadingFileId != nil)
                    .keyboardShortcut(.defaultAction)
            }

            if let errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage).font(.caption)
                }
            }

            Divider()

            if isSearching {
                ProgressView("検索中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let repo = selectedRepo {
                fileListView(repo: repo)
            } else {
                repoListView
            }

            if downloadingFileId != nil {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: modelManager.downloadProgress)
                    Text(modelManager.downloadStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 640, height: 520)
        .onAppear {
            guard !didInit else { return }
            didInit = true
            if !kind.initialQuery.isEmpty {
                query = kind.initialQuery
                runSearch()
            }
        }
    }

    // MARK: - Repository list

    private var repoListView: some View {
        Group {
            if repos.isEmpty {
                Text("キーワードを入力して検索してください。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(repos) { repo in
                    Button {
                        selectRepo(repo)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repo.id)
                                    .font(.body)
                                HStack(spacing: 12) {
                                    if let downloads = repo.downloads {
                                        Label(formatCount(downloads), systemImage: "arrow.down.circle")
                                    }
                                    if let likes = repo.likes {
                                        Label("\(likes)", systemImage: "heart")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: - File list

    private func fileListView(repo: HuggingFaceAPI.Repo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    selectedRepo = nil
                    files = []
                } label: {
                    Label("戻る", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(downloadingFileId != nil)
                Text(repo.id)
                    .font(.subheadline)
                    .bold()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            if isLoadingFiles {
                ProgressView("ファイル一覧取得中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                Text(kind.emptyFilesHint)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(files) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path)
                                .font(.body)
                            if let size = file.size {
                                Text(ModelManager.formatBytes(size))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        actionButton(repo: repo, file: file)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
        }
    }

    @ViewBuilder
    private func actionButton(repo: HuggingFaceAPI.Repo, file: HuggingFaceAPI.File) -> some View {
        let fileId = makeFileId(repo: repo, file: file)
        if addedFileIds.contains(fileId) {
            Label("追加済み", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else if downloadingFileId == fileId {
            ProgressView().controlSize(.small)
        } else {
            Button(kind.actionLabel) {
                handleAction(repo: repo, file: file, fileId: fileId)
            }
            .disabled(downloadingFileId != nil)
        }
    }

    // MARK: - Actions

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isSearching = true
        selectedRepo = nil
        files = []
        Task {
            do {
                let result = try await HuggingFaceAPI.searchRepos(query: trimmed, filter: kind.searchFilter)
                await MainActor.run {
                    self.repos = result
                    self.isSearching = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "検索失敗: \(error.localizedDescription)"
                    self.isSearching = false
                }
            }
        }
    }

    private func selectRepo(_ repo: HuggingFaceAPI.Repo) {
        errorMessage = nil
        selectedRepo = repo
        files = []
        isLoadingFiles = true
        Task {
            do {
                let result = try await HuggingFaceAPI.listFiles(repoId: repo.id, extension: kind.fileExtension)
                await MainActor.run {
                    self.files = result
                    self.isLoadingFiles = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "ファイル一覧取得失敗: \(error.localizedDescription)"
                    self.isLoadingFiles = false
                }
            }
        }
    }

    private func handleAction(repo: HuggingFaceAPI.Repo, file: HuggingFaceAPI.File, fileId: String) {
        switch kind {
        case .llamaGGUF:
            addLlamaModel(repo: repo, file: file, fileId: fileId)
        case .whisperBin:
            downloadWhisperModel(repo: repo, file: file, fileId: fileId)
        }
    }

    private func addLlamaModel(repo: HuggingFaceAPI.Repo, file: HuggingFaceAPI.File, fileId: String) {
        let sizeGB = Double(file.size ?? 0) / 1_073_741_824
        let info = ModelManager.ModelInfo(
            id: fileId,
            name: file.path,
            sizeGB: sizeGB,
            backend: .llama,
            huggingFaceId: repo.id,
            recommended: false
        )
        modelManager.addUserAddedModel(info)
        addedFileIds.insert(fileId)
    }

    private func downloadWhisperModel(repo: HuggingFaceAPI.Repo, file: HuggingFaceAPI.File, fileId: String) {
        errorMessage = nil
        downloadingFileId = fileId
        Task {
            do {
                let destURL = try await modelManager.downloadWhisperModel(
                    repoId: repo.id,
                    fileName: file.path
                )
                await MainActor.run {
                    self.settings.whisperModelPath = destURL.path
                    self.downloadingFileId = nil
                    self.dismiss()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "ダウンロード失敗: \(error.localizedDescription)"
                    self.downloadingFileId = nil
                }
            }
        }
    }

    private func makeFileId(repo: HuggingFaceAPI.Repo, file: HuggingFaceAPI.File) -> String {
        let sanitized = repo.id.replacingOccurrences(of: "/", with: "_")
        return "hf-\(sanitized)-\(file.path)"
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return String(count)
    }
}
