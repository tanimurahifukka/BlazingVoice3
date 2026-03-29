import SwiftUI

struct SetupWizardView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var modelManager: ModelManager
    @StateObject private var permissions = PermissionHelper()
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 20) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<3) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                }
            }

            Spacer()

            switch currentStep {
            case 0: permissionsStep
            case 1: modelStep
            case 2: completeStep
            default: EmptyView()
            }

            Spacer()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("戻る") { currentStep -= 1 }
                }
                Spacer()
                if currentStep < 2 {
                    Button("次へ") { currentStep += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("完了") { settings.setupCompleted = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .padding()
        .onAppear { permissions.refresh() }
    }

    // MARK: - Step 1: Permissions

    var permissionsStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("権限の設定")
                .font(.title2.bold())

            Text("3つの権限が必要です。ボタンを押すだけで設定できます。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "mic.fill",
                    title: "マイク",
                    granted: permissions.micGranted,
                    action: { permissions.requestMicrophone() }
                )
                permissionRow(
                    icon: "waveform",
                    title: "音声認識",
                    granted: permissions.speechGranted,
                    action: { permissions.requestSpeech() }
                )
                permissionRow(
                    icon: "hand.raised.fill",
                    title: "アクセシビリティ",
                    granted: permissions.accessibilityGranted,
                    action: { permissions.requestAccessibility() }
                )
            }
            .frame(maxWidth: 360)

            if !permissions.accessibilityGranted {
                Text("アクセシビリティ: システム設定が開きます。\nBlazingVoice3をONにしてください。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if permissions.allGranted {
                Label("すべての権限が付与されました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.bold())
            }

            // One-click setup
            if !permissions.allGranted {
                Button("まとめて設定") {
                    Task { await permissions.requestAll() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func permissionRow(icon: String, title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(granted ? .green : .secondary)
            Text(title)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("許可") { action() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(granted ? Color.green.opacity(0.05) : Color.clear)
        .cornerRadius(8)
    }

    // MARK: - Step 2: Model

    var modelStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 48))
                .foregroundStyle(.purple)

            Text("モデル選択")
                .font(.title2.bold())

            Text("推論エンジンを選択してください。\nGGUFモデルが見つかれば自動で使用します。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)

            VStack(spacing: 8) {
                ForEach(modelManager.availableModels.filter { $0.backend == .llama }) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.name).font(.headline)
                            HStack(spacing: 8) {
                                Text("\(String(format: "%.1f", model.sizeGB)) GB").font(.caption)
                                if model.isDownloaded {
                                    Text("DL済").font(.caption).foregroundStyle(.green)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.recommended {
                            Text("推奨").font(.caption).foregroundStyle(.blue)
                        }
                        if model.id == settings.selectedModelId {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .padding(8)
                    .background(model.id == settings.selectedModelId ? Color.accentColor.opacity(0.1) : Color.clear)
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        settings.selectedModelId = model.id
                        settings.engineBackendRaw = "llama"
                    }
                }
            }
            .frame(maxWidth: 400)
        }
    }

    // MARK: - Step 3: Complete

    var completeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("準備完了!")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Label("⌥ Space: 口述モード (SOAP)", systemImage: "waveform")
                Label("⌥ B: 会話モード (箇条書き)", systemImage: "list.bullet")
                Label("⌥ N: 通常モード (文字起こし)", systemImage: "text.alignleft")
                Label("⌥ C: クラスターモード", systemImage: "network")
            }
            .font(.callout)

            Text("ホットキーで録音開始 → もう一度押して停止 → クリップボードにコピー")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
