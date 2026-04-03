import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gear") }
            ModelSettingsView()
                .tabItem { Label("モデル", systemImage: "cpu") }
            DictionarySettingsView()
                .tabItem { Label("辞書", systemImage: "book") }
            PromptSettingsView()
                .tabItem { Label("プロンプト", systemImage: "text.quote") }
            AdvancedSettingsView()
                .tabItem { Label("上級", systemImage: "wrench.and.screwdriver") }
            EvolutionSettingsView()
                .tabItem { Label("履歴・進化", systemImage: "brain") }
        }
        .frame(width: 700, height: 520)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("操作") {
                Text("左Shiftを素早く2回押すと録音の開始/停止")
                    .font(.callout)
                Slider(value: $settings.doubleTapInterval, in: 0.2...0.8, step: 0.05) {
                    Text("ダブルタップ間隔: \(String(format: "%.2f", settings.doubleTapInterval))秒")
                }
                Text("短い = 素早く2回押す必要あり / 長い = 誤検出しやすい")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("デフォルトモード") {
                Picker("", selection: $settings.defaultVoiceModeRaw) {
                    ForEach(VoiceMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
            }

            Section("録音") {
                Slider(value: $settings.maxRecordingDuration, in: 30...600, step: 30) {
                    Text("最大録音時間: \(Int(settings.maxRecordingDuration))秒")
                }
                Slider(value: $settings.breathPauseInterval, in: 0.5...3.0, step: 0.1) {
                    Text("息継ぎ検出間隔: \(String(format: "%.1f", settings.breathPauseInterval))秒")
                }
                Text("通常モードで音声が途切れてからLLM整文するまでの待ち時間")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - Model

struct ModelSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var modelManager: ModelManager
    @State private var modelChanged = false

    var body: some View {
        Form {
            Section("モード別モデル設定") {
                modelPicker("通常 (リアルタイム)", binding: $settings.normalModelId)
                modelPicker("口述 (SOAP)", binding: $settings.dictationModelId)
                modelPicker("会話 (箇条書き)", binding: $settings.conversationModelId)
                modelPicker("クラスター", binding: $settings.clusterModelId)
                Text("空欄 = 口述モデルを共用。通常モードは軽量モデル推奨。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if modelChanged {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("モデルを変更しました。アプリ再起動で反映されます。")
                            .font(.callout)
                    }
                }
            }

            if modelManager.isDownloading {
                Section("ダウンロード中") {
                    ProgressView(value: modelManager.downloadProgress)
                    Text(modelManager.downloadStatus).font(.caption)
                }
            }
        }
        .padding()
        .onChange(of: settings.dictationModelId) { modelChanged = true }
        .onChange(of: settings.normalModelId) { modelChanged = true }
        .onChange(of: settings.conversationModelId) { modelChanged = true }
        .onChange(of: settings.clusterModelId) { modelChanged = true }
    }

    private func modelPicker(_ label: String, binding: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 140, alignment: .leading)
            Picker("", selection: binding) {
                Text("口述モデルと共用").tag("")
                ForEach(modelManager.availableModels.filter { $0.backend == .llama }) { model in
                    Text("\(model.name) (\(String(format: "%.1f", model.sizeGB))GB)")
                        .tag(model.id)
                }
            }
            .labelsHidden()
        }
    }
}

// MARK: - Advanced (Hotkey + Inference + Cluster)

struct AdvancedSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showClusterAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                GroupBox("推論設定") {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper("スロット数: \(settings.slotCount)", value: $settings.slotCount, in: 1...20)
                        Stepper("最大出力トークン: \(settings.llmMaxOutputTokens)",
                                value: $settings.llmMaxOutputTokens, in: 256...8192, step: 256)
                        Slider(value: $settings.llmTemperature, in: 0...1, step: 0.1) {
                            Text("Temperature: \(String(format: "%.1f", settings.llmTemperature))")
                        }
                        Picker("KV Cache量子化", selection: $settings.kvQuantizeModeRaw) {
                            ForEach(KVQuantizeMode.allCases, id: \.rawValue) { mode in
                                Text(mode.displayName).tag(mode.rawValue)
                            }
                        }
                        Text("量子化変更はアプリ再起動で反映")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                GroupBox("モード別ホットキー") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("通常はSpace×2で操作。特定モードを直接起動したい場合に設定。")
                            .font(.caption).foregroundStyle(.secondary)
                        HotkeyRecorderView(label: "口述 (SOAP)", modifierFlags: $settings.hotkeyModifierFlags, keyCode: $settings.hotkeyKeyCode)
                        HotkeyRecorderView(label: "会話 (箇条書き)", modifierFlags: $settings.bulletHotkeyModifierFlags, keyCode: $settings.bulletHotkeyKeyCode)
                        HotkeyRecorderView(label: "通常 (リアルタイム)", modifierFlags: $settings.normalHotkeyModifierFlags, keyCode: $settings.normalHotkeyKeyCode)
                        HotkeyRecorderView(label: "クラスター", modifierFlags: $settings.clusterHotkeyModifierFlags, keyCode: $settings.clusterHotkeyKeyCode)
                    }
                    .padding(4)
                }

                GroupBox("クラスターモード") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("クラスターモード有効", isOn: Binding(
                            get: { settings.clusterEnabled },
                            set: { newValue in
                                if newValue { showClusterAlert = true }
                                else { settings.clusterEnabled = false }
                            }
                        ))

                        if settings.clusterEnabled {
                            Stepper("ポート: \(settings.clusterPort)", value: $settings.clusterPort, in: 1024...65535)
                            TextField("明示的ピア (host:port, ...)", text: $settings.explicitPeers)
                            Slider(value: $settings.spilloverThreshold, in: 0...1, step: 0.1) {
                                Text("スピルオーバー閾値: \(String(format: "%.1f", settings.spilloverThreshold))")
                            }
                        }

                        Text("複数のMac (Mac mini, Mac Studio等)をLANで接続し、推論処理を分散する上級者向け機能です。Bonjour自動発見+Uzu帯域幅ルーティングで最適なノードに推論をルーティングします。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                }
            }
            .padding()
        }
        .alert("上級者向け機能", isPresented: $showClusterAlert) {
            Button("有効にする") { settings.clusterEnabled = true }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("クラスターモードは複数のMacをLAN接続して推論を分散する機能です。通常使用では不要です。設定にはネットワークの知識が必要です。有効にしますか？")
        }
    }
}

// MARK: - Dictionary

struct DictionarySettingsView: View {
    @EnvironmentObject var dictionary: UserDictionary
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        VStack {
            HStack {
                TextField("変換前", text: $newFrom)
                    .textFieldStyle(.roundedBorder)
                TextField("変換後", text: $newTo)
                    .textFieldStyle(.roundedBorder)
                Button("追加") {
                    guard !newFrom.isEmpty, !newTo.isEmpty else { return }
                    dictionary.addEntry(from: newFrom, to: newTo)
                    newFrom = ""
                    newTo = ""
                }
            }
            .padding(.horizontal)

            List {
                ForEach(dictionary.entries) { entry in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { entry.isEnabled },
                            set: { _ in dictionary.toggleEntry(entry) }
                        ))
                        .labelsHidden()
                        Text(entry.from)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(entry.to).fontWeight(.medium)
                    }
                }
                .onDelete(perform: dictionary.removeEntries)
            }
        }
        .padding()
    }
}

// MARK: - Prompt

struct PromptSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                promptSection(
                    title: "グローバルプレフィックス (全モード共通)",
                    text: $settings.globalPrefixPrompt,
                    defaultValue: PromptTemplate.globalPrefix,
                    height: 80
                )

                promptSection(
                    title: "SOAP プレフィックス (口述モード)",
                    text: $settings.soapPrefixPrompt,
                    defaultValue: PromptTemplate.soapPrefix,
                    height: 70
                )

                promptSection(
                    title: "箇条書きプレフィックス (会話モード)",
                    text: $settings.bulletPrefixPrompt,
                    defaultValue: PromptTemplate.bulletPrefix,
                    height: 60
                )

                promptSection(
                    title: "通常モード (フィラー除去+整文)",
                    text: $settings.normalPrompt,
                    defaultValue: PromptTemplate.defaultNormalPrompt,
                    height: 80
                )

                Divider()

                GroupBox("カスタム上書き (設定するとプレフィックス+デフォルトを無視)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SOAP 完全上書き").font(.caption.bold())
                        TextEditor(text: $settings.customSOAPPrompt)
                            .frame(height: 50)
                            .font(.system(.caption2, design: .monospaced))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                        if settings.customSOAPPrompt.isEmpty {
                            Text("空欄 = プレフィックス+デフォルトを使用").font(.caption2).foregroundStyle(.tertiary)
                        }

                        Text("箇条書き 完全上書き").font(.caption.bold())
                        TextEditor(text: $settings.customBulletPrompt)
                            .frame(height: 50)
                            .font(.system(.caption2, design: .monospaced))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                        if settings.customBulletPrompt.isEmpty {
                            Text("空欄 = プレフィックス+デフォルトを使用").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(4)
                }
            }
            .padding()
        }
    }

    private func promptSection(title: String, text: Binding<String>, defaultValue: String, height: CGFloat) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.caption.bold())
                    Spacer()
                    if text.wrappedValue != defaultValue {
                        Button("リセット") {
                            text.wrappedValue = defaultValue
                        }
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                }
                TextEditor(text: text)
                    .frame(height: height)
                    .font(.system(.caption2, design: .monospaced))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
            }
            .padding(4)
        }
    }
}
