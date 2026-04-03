import AVFoundation
import Cocoa
import Metal
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let settings: AppSettings
    let modelManager: ModelManager
    let dictionary: UserDictionary
    let sessionHistory: SessionHistory
    let evolutionLog: EvolutionLog
    let permissions: any PermissionManaging

    private var statusBarController: (any StatusBarControlling)?
    private var overlay: (any OverlayPresenting)?
    private var hotkeyManager: (any HotkeyManaging)?
    private let audioRecorder: any AudioRecording
    private let statusBarControllerFactory: @MainActor () -> any StatusBarControlling
    private let overlayFactory: @MainActor () -> any OverlayPresenting
    private let hotkeyManagerFactory: @MainActor () -> any HotkeyManaging
    private let launchOptions: AppLaunchOptions

    /// Per-mode engines. Key = modelId, shared if same model.
    private var engines: [String: any InferenceEngine] = [:]
    private var clusterEngine: ClusterEngine?
    private var lastPartialText = ""
    private var lastChunkEndIndex = 0
    private var chunkTimer: Timer?
    private var processedChunks: [String] = []
    private var realtimeChunkTask: Task<Void, Never>?
    private var clusterManager: ClusterManager?
    private var orchestrator: AgentOrchestrator?

    @Published var pipelineState: PipelineState = .idle
    @Published var currentMode: VoiceMode = .dictation

    override init() {
        settings = AppSettings()
        modelManager = ModelManager()
        dictionary = UserDictionary()
        sessionHistory = SessionHistory()
        evolutionLog = EvolutionLog()
        permissions = PermissionHelper()
        audioRecorder = AudioRecorder()
        statusBarControllerFactory = { StatusBarController() }
        overlayFactory = { OverlayPanel() }
        hotkeyManagerFactory = { HotkeyManager() }
        launchOptions = .live
        super.init()
    }

    init(
        settings: AppSettings,
        modelManager: ModelManager,
        dictionary: UserDictionary = UserDictionary(),
        sessionHistory: SessionHistory,
        evolutionLog: EvolutionLog,
        permissions: any PermissionManaging,
        audioRecorder: any AudioRecording,
        statusBarControllerFactory: @escaping @MainActor () -> any StatusBarControlling,
        overlayFactory: @escaping @MainActor () -> any OverlayPresenting,
        hotkeyManagerFactory: @escaping @MainActor () -> any HotkeyManaging,
        launchOptions: AppLaunchOptions = .live
    ) {
        self.settings = settings
        self.modelManager = modelManager
        self.dictionary = dictionary
        self.sessionHistory = sessionHistory
        self.evolutionLog = evolutionLog
        self.permissions = permissions
        self.audioRecorder = audioRecorder
        self.statusBarControllerFactory = statusBarControllerFactory
        self.overlayFactory = overlayFactory
        self.hotkeyManagerFactory = hotkeyManagerFactory
        self.launchOptions = launchOptions
        super.init()
    }

    var engineDescription: String {
        let descs = engines.values.map { $0.modelDescription }
        return descs.isEmpty ? "Not loaded" : descs.joined(separator: " / ")
    }

    var mainEngine: (any InferenceEngine)? {
        let id = settings.dictationModelId
        return engines[id]
    }

    enum PipelineState: Equatable {
        case idle
        case loading
        case recording
        case processing
        case done
        case error(String)
    }

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching")
        guard !CLITest.shouldRun() else { return }
        bootstrapForTesting()
    }

    func bootstrapForTesting() {
        _ = NSApplication.shared
        debugLog("bootstrapForTesting start, defaultMode=\(settings.defaultVoiceModeRaw)")

        currentMode = settings.defaultVoiceMode
        NSApplication.shared.setActivationPolicy(.accessory)

        // UI setup
        let sbc = statusBarControllerFactory()
        sbc.setup()
        statusBarController = sbc

        overlay = overlayFactory()

        updateStatusMenu()

        // Hotkey setup
        let hk = hotkeyManagerFactory()
        hk.configure(with: settings)
        // Primary: double-tap Left Shift → start/stop with current mode
        hk.onDoubleTap = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleHotkeyPress(mode: self.currentMode)
            }
        }
        // Advanced: per-mode hotkeys (⌥+key)
        hk.onHotkeyPress = { [weak self] mode in
            Task { @MainActor [weak self] in
                self?.handleHotkeyPress(mode: mode)
            }
        }
        if launchOptions.startHotkeyMonitoring {
            hk.startMonitoring()
        }
        hotkeyManager = hk
        permissions.onAccessibilityGranted = { [weak self] in
            Task { @MainActor [weak self] in
                self?.hotkeyManager?.restartMonitoring()
                self?.overlay?.show(message: "ホットキー監視を再開しました", duration: 1.5)
            }
        }

        audioRecorder.onAutoStop = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let rawText):
                    self.processTranscription(rawText)
                case .failure(let error):
                    self.handlePipelineFailure(error)
                }
            }
        }

        NSLog("[BlazingVoice3] v%@ started", AppVersion.full)

        guard launchOptions.loadEnginesOnLaunch else { return }
        Task { [weak self] in
            await self?.loadEngine()
            // Request permissions AFTER engine load (avoids TCC crash on first launch)
            if self?.launchOptions.requestPermissionsOnLaunch == true {
                self?.debugLog("Requesting permissions after engine load")
                self?.permissions.requestMicrophone()
                // Delay speech permission request to avoid TCC race
                try? await Task.sleep(for: .seconds(1))
                self?.permissions.requestSpeech()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.stopMonitoring()
        clusterManager?.stop()
        realtimeChunkTask?.cancel()
        engines.removeAll()
        clusterEngine = nil
        orchestrator = nil
    }

    // MARK: - Engine Loading

    /// Load engines for all modes that have distinct models.
    /// Same modelId = shared engine instance (no duplicate loading).
    private func loadEngine() async {
        pipelineState = .loading
        statusBarController?.updateState(.processing)
        updateStatusMenu()

        debugLog("loadEngine start")

        // Collect unique model IDs needed across all modes
        var neededModels: Set<String> = []
        for mode in VoiceMode.allCases {
            neededModels.insert(settings.modelId(for: mode))
        }

        debugLog("Loading \(neededModels.count) unique model(s): \(neededModels.joined(separator: ", "))")
        debugLog("Available models: \(modelManager.availableModels.map { "\($0.id) downloaded=\($0.isDownloaded)" }.joined(separator: ", "))")

        // Auto-download recommended model if no GGUF files are available
        let hasAnyDownloaded = modelManager.availableModels.contains { $0.isDownloaded && $0.backend == .llama }
        debugLog("hasAnyDownloaded=\(hasAnyDownloaded)")
        if !hasAnyDownloaded {
            if let recommended = modelManager.availableModels.first(where: { $0.recommended && $0.backend == .llama }) {
                NSLog("[BlazingVoice3] No models found, auto-downloading: %@", recommended.name)
                overlay?.showProgress(
                    message: "初回セットアップ: AIモデルをダウンロード中",
                    detail: "\(recommended.name) (約\(String(format: "%.1f", recommended.sizeGB)) GB)"
                )

                // Wire up progress updates to overlay
                modelManager.onDownloadProgress = { [weak self] progress, downloaded, total in
                    Task { @MainActor [weak self] in
                        let detail = String(
                            format: "%@ / %@ (%d%%)",
                            ModelManager.formatBytes(downloaded),
                            total > 0 ? ModelManager.formatBytes(total) : "\(String(format: "%.1f", recommended.sizeGB)) GB",
                            Int(progress * 100)
                        )
                        self?.overlay?.showProgress(
                            message: "AIモデルをダウンロード中...",
                            detail: detail,
                            progress: progress
                        )
                    }
                }

                do {
                    try await modelManager.downloadModel(recommended)
                    modelManager.onDownloadProgress = nil
                    NSLog("[BlazingVoice3] Auto-download complete: %@", recommended.name)
                    overlay?.show(message: "ダウンロード完了: \(recommended.name)", duration: 2)
                } catch {
                    modelManager.onDownloadProgress = nil
                    NSLog("[BlazingVoice3] Auto-download failed: %@", "\(error)")
                    overlay?.show(message: "モデルダウンロード失敗: \(error.localizedDescription)", duration: 10)
                }
            }
        }

        var failedModels: [String] = []

        for modelId in neededModels {
            guard let model = modelManager.availableModels.first(where: { $0.id == modelId })
                    ?? modelManager.availableModels.first(where: { $0.recommended })
                    ?? modelManager.availableModels.first(where: { $0.isDownloaded }) else {
                NSLog("[BlazingVoice3] ERROR: Model '%@' not found in available models", modelId)
                failedModels.append(modelId)
                continue
            }

            // Skip MLX (crashes without metallib in SPM builds)
            if model.backend == .mlx {
                if let fallback = modelManager.availableModels.first(where: { $0.backend == .llama && $0.isDownloaded }) {
                    NSLog("[BlazingVoice3] MLX skipped, using llama fallback: %@", fallback.name)
                    await loadSingleEngine(model: fallback, forModelId: modelId)
                } else {
                    NSLog("[BlazingVoice3] ERROR: MLX skipped and no llama fallback for '%@'", modelId)
                    failedModels.append(modelId)
                }
                continue
            }

            await loadSingleEngine(model: model, forModelId: modelId)

            // Check if engine was actually loaded
            if engines[modelId] == nil {
                failedModels.append(modelId)
            }
        }

        // Setup orchestrator with dictation engine
        setupOrchestrator()
        if settings.clusterEnabled { setupCluster() }

        pipelineState = .idle

        if engines.isEmpty {
            statusBarController?.updateState(.error)
            let msg = "モデル未検出: ~/models/ にGGUFを配置してください"
            overlay?.show(message: msg, duration: 10)
            NSLog("[BlazingVoice3] FATAL: No engines loaded. Failed: %@", failedModels.joined(separator: ", "))
        } else if !failedModels.isEmpty {
            statusBarController?.updateState(.idle)
            let names = engines.values.map { $0.modelDescription }
            overlay?.show(message: "一部モデル未検出 (\(names.count)エンジン読込済)", duration: 5)
            NSLog("[BlazingVoice3] Partial load: %@, failed: %@",
                  names.joined(separator: ", "), failedModels.joined(separator: ", "))
        } else {
            statusBarController?.updateState(.idle)
            let names = engines.values.map { $0.modelDescription }
            overlay?.show(message: "準備完了 (\(names.count)エンジン)", duration: 2)
            NSLog("[BlazingVoice3] All engines loaded: %@", names.joined(separator: ", "))
        }
        updateStatusMenu()
    }

    private func loadSingleEngine(model: ModelManager.ModelInfo, forModelId: String) async {
        // Skip if already loaded
        if engines[forModelId] != nil { return }
        // Check if same model already loaded under different key
        if let existing = engines.values.first(where: { $0.modelDescription.contains(model.name.replacingOccurrences(of: ".gguf", with: "")) }) {
            engines[forModelId] = existing
            NSLog("[BlazingVoice3] Reusing engine for '%@'", forModelId)
            return
        }

        overlay?.showProgress(
            message: "AIモデルを読込中...",
            detail: model.name
        )
        NSLog("[BlazingVoice3] Loading: %@ (for '%@')", model.name, forModelId)

        do {
            if !model.isDownloaded && model.backend == .llama {
                overlay?.showProgress(
                    message: "モデルをダウンロード中...",
                    detail: "\(model.name) (約\(String(format: "%.1f", model.sizeGB)) GB)"
                )
                modelManager.onDownloadProgress = { [weak self] progress, downloaded, total in
                    Task { @MainActor [weak self] in
                        let detail = String(
                            format: "%@ / %@ (%d%%)",
                            ModelManager.formatBytes(downloaded),
                            total > 0 ? ModelManager.formatBytes(total) : "\(String(format: "%.1f", model.sizeGB)) GB",
                            Int(progress * 100)
                        )
                        self?.overlay?.showProgress(
                            message: "モデルをダウンロード中...",
                            detail: detail,
                            progress: progress
                        )
                    }
                }
                try await modelManager.downloadModel(model)
                modelManager.onDownloadProgress = nil
            }

            let eng = try await modelManager.createEngine(
                for: model,
                slotCount: settings.slotCount,
                kvQuantize: settings.kvQuantizeMode,
                maxMemoryGB: settings.effectiveMaxMemoryGB
            )
            engines[forModelId] = eng
            NSLog("[BlazingVoice3] Loaded: %@", eng.modelDescription)
        } catch {
            NSLog("[BlazingVoice3] ERROR: Failed to load '%@': %@", model.name, "\(error)")
            overlay?.show(message: "モデル読込失敗: \(model.name)", duration: 5)
        }
    }

    /// Get the engine for a given mode
    func engineForMode(_ mode: VoiceMode) -> (any InferenceEngine)? {
        let modelId = settings.modelId(for: mode)
        return engines[modelId] ?? engines.values.first
    }

    private func setupOrchestrator() {
        guard let eng = engineForMode(.dictation) else { return }
        orchestrator = AgentOrchestrator(
            engine: eng,
            clusterEngine: clusterEngine,
            dictionary: dictionary
        )
    }

    // MARK: - Cluster

    private func setupCluster() {
        guard let engine = engineForMode(.cluster) else { return }
        guard clusterManager == nil else {
            setupOrchestrator()
            return
        }

        let cm = ClusterManager(
            httpPort: settings.clusterPort,
            backend: settings.engineBackendRaw,
            model: settings.selectedModelId,
            slots: settings.slotCount,
            spilloverThreshold: settings.spilloverThreshold
        )
        clusterManager = cm
        clusterEngine = ClusterEngine(localEngine: engine, clusterManager: cm)
        cm.start()

        if !settings.explicitPeers.isEmpty {
            for peer in settings.explicitPeers.split(separator: ",") {
                cm.addExplicitPeer(String(peer).trimmingCharacters(in: .whitespaces))
            }
        }

        setupOrchestrator()
    }

    // MARK: - Hotkey

    private func handleHotkeyPress(mode: VoiceMode) {
        NSLog("[BlazingVoice3] Hotkey pressed: %@ (state: %@)", mode.rawValue, "\(pipelineState)")
        switch pipelineState {
        case .recording:
            if currentMode == .normal {
                // Normal mode: stop real-time streaming, do final LLM polish
                stopRealtimeAndFinalize()
            } else {
                stopRecordingAndProcess()
            }
        case .idle, .loading, .done:
            currentMode = mode
            if mode == .normal {
                startRealtimeRecording()
            } else {
                startRecording()
            }
        case .processing, .error:
            break
        }
    }

    private func startRecording() {
        // Refresh permissions every time
        permissions.refresh()
        NSLog("[BlazingVoice3] startRecording: mic=%d speech=%d accessibility=%d",
              permissions.micGranted ? 1 : 0,
              permissions.speechGranted ? 1 : 0,
              permissions.accessibilityGranted ? 1 : 0)

        // Auto-request permissions (safe: PermissionHelper checks for Info.plist)
        if !permissions.micGranted {
            NSLog("[BlazingVoice3] Mic not granted, requesting...")
            permissions.requestMicrophone()
            overlay?.show(message: "マイクを許可してください")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.permissions.refresh()
                if self?.permissions.micGranted == true {
                    self?.startRecording()
                } else {
                    self?.overlay?.show(message: "マイク権限がありません。.appバンドルから起動してください。")
                }
            }
            return
        }

        if !permissions.speechGranted {
            NSLog("[BlazingVoice3] Speech not granted, requesting...")
            permissions.requestSpeech()
            overlay?.show(message: "音声認識を許可してください")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.permissions.refresh()
                if self?.permissions.speechGranted == true {
                    self?.startRecording()
                }
            }
            return
        }

        do {
            NSLog("[BlazingVoice3] Starting audio recording")
            try audioRecorder.startRecording(maxDuration: settings.maxRecordingDuration)
            pipelineState = .recording
            statusBarController?.updateState(.recording)
            overlay?.show(message: "\(currentMode.displayName) 録音中", duration: 60)
            updateStatusMenu()
            NSLog("[BlazingVoice3] Recording started OK")
        } catch {
            pipelineState = .idle
            statusBarController?.updateState(.error)
            overlay?.show(message: "録音エラー: \(error.localizedDescription)")
            updateStatusMenu()
            NSLog("[BlazingVoice3] Recording error: %@", "\(error)")
        }
    }

    private func stopRecordingAndProcess() {
        NSLog("[BlazingVoice3] stopRecordingAndProcess")
        pipelineState = .processing
        statusBarController?.updateState(.processing)
        overlay?.showProgress(message: "音声を文字起こし中...")
        updateStatusMenu()

        Task { [weak self] in
            guard let self else { return }
            do {
                let rawText = try await audioRecorder.stopRecordingAndTranscribe()
                NSLog("[BlazingVoice3] STT complete: %d chars", rawText.count)
                self.processTranscription(rawText)
            } catch BlazingError.noSpeechResult {
                // Empty recording — just go back to idle silently
                NSLog("[BlazingVoice3] No speech detected, returning to idle")
                self.pipelineState = .idle
                self.statusBarController?.updateState(.idle)
                self.overlay?.show(message: "音声が検出されませんでした", duration: 1.5)
                self.updateStatusMenu()
            } catch {
                NSLog("[BlazingVoice3] STT failed: %@", "\(error)")
                self.handlePipelineFailure(error)
            }
        }
    }

    private func processTranscription(_ rawText: String) {
        NSLog("[BlazingVoice3] processTranscription: %d chars, orchestrator=%d",
              rawText.count, orchestrator != nil ? 1 : 0)
        pipelineState = .processing
        statusBarController?.updateState(.processing)
        overlay?.showProgress(message: "\(currentMode.displayName) 変換中...")
        updateStatusMenu()

        let mode = currentMode
        let customPrompt: String? = switch mode {
        case .dictation, .cluster: settings.customSOAPPrompt.isEmpty ? nil : settings.customSOAPPrompt
        case .conversation: settings.customBulletPrompt.isEmpty ? nil : settings.customBulletPrompt
        case .normal: settings.normalPrompt.isEmpty ? nil : settings.normalPrompt
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                // Use the engine for the current mode, not just the dictation engine
                guard let modeEngine = self.engineForMode(mode) else {
                    NSLog("[BlazingVoice3] ERROR: No engine loaded for mode '%@'", mode.rawValue)
                    self.handlePipelineFailure(
                        BlazingError.agentPipelineFailed("エンジン未読込: モデルをダウンロードして再起動してください")
                    )
                    return
                }

                // Build a per-mode orchestrator so each mode uses its own engine
                let modeOrchestrator = AgentOrchestrator(
                    engine: modeEngine,
                    clusterEngine: self.clusterEngine,
                    dictionary: self.dictionary
                )

                NSLog("[BlazingVoice3] Calling orchestrator.process (mode=%@)", mode.rawValue)
                let result = try await modeOrchestrator.process(
                    rawText: rawText,
                    mode: mode,
                    customPrompt: customPrompt
                )
                NSLog("[BlazingVoice3] Orchestrator done: %d chars, Q=%.0f%%",
                      result.generatedText.count, result.qualityScore * 100)

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.generatedText, forType: .string)

                sessionHistory.addSession(result)
                evolutionLog.log(
                    result: result,
                    promptUsed: PromptTemplate.systemPrompt(for: mode, customPrompt: customPrompt) ?? ""
                )

                pipelineState = .done
                statusBarController?.updateState(.done)
                overlay?.show(message: "Cmd+V でペースト (Q:\(Int(result.qualityScore * 100))%)")
                updateStatusMenu()
                resetAfterDelay()
            } catch {
                handlePipelineFailure(error)
            }
        }
    }

    private func handlePipelineFailure(_ error: Error) {
        let message: String
        if let blazingError = error as? BlazingError {
            message = blazingError.userMessage
        } else {
            message = "処理エラー: \(error.localizedDescription)"
        }
        pipelineState = .error(message)
        statusBarController?.updateState(.error)
        overlay?.show(message: message, duration: 5)
        updateStatusMenu()
        NSLog("[BlazingVoice3] Pipeline error: %@", "\(error)")
        resetAfterDelay()
    }

    private func resetAfterDelay() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            if self.pipelineState == .done || self.pipelineState != .idle {
                self.pipelineState = .idle
                self.statusBarController?.updateState(.idle)
                self.updateStatusMenu()
            }
        }
    }

    // MARK: - Realtime Mode (Normal)

    /// Realtime mode: breath-pause chunked LLM processing.
    ///
    /// Flow:
    /// 1. STT streams partial results (regex-cleaned)
    /// 2. When text stops changing for ~1.2s (breath pause), extract new chunk
    /// 3. Send chunk to LLM for filler removal + cleanup
    /// 4. Append cleaned result to panel
    /// 5. On stop: copy final text to clipboard
    private func startRealtimeRecording() {
        permissions.refresh()
        if !permissions.micGranted {
            permissions.requestMicrophone()
            overlay?.show(message: "マイクを許可してください")
            return
        }

        if !permissions.speechGranted {
            NSLog("[BlazingVoice3] Speech not granted, requesting for realtime...")
            permissions.requestSpeech()
            overlay?.show(message: "音声認識を許可してください")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.permissions.refresh()
                if self?.permissions.speechGranted == true {
                    self?.startRealtimeRecording()
                }
            }
            return
        }

        if !permissions.accessibilityGranted {
            NSLog("[BlazingVoice3] Accessibility not granted for realtime input")
            permissions.requestAccessibility()
            overlay?.show(message: "アクセシビリティを許可してください")
            return
        }

        lastPartialText = ""
        lastChunkEndIndex = 0
        processedChunks = []
        realtimeChunkTask?.cancel()
        realtimeChunkTask = nil

        // On each partial STT result: detect breath pause
        // NOTE: onPartialResult is called from SFSpeechRecognizer's background thread,
        // so we dispatch everything to MainActor
        audioRecorder.onPartialResult = { [weak self] rawText in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cleaned = FillerRemover.clean(rawText)
                guard cleaned != self.lastPartialText else { return }
                self.lastPartialText = cleaned
                NSLog("[Realtime] Partial: %@", String(cleaned.suffix(40)))

                // Reset breath-pause timer
                self.chunkTimer?.invalidate()
                self.chunkTimer = Timer.scheduledTimer(withTimeInterval: self.settings.breathPauseInterval, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.processCurrentChunk()
                    }
                }
            }
        }

        do {
            try audioRecorder.startRecording(maxDuration: settings.maxRecordingDuration)
            pipelineState = .recording
            statusBarController?.updateState(.recording)
            overlay?.show(message: "リアルタイム入力中 ⌥N で停止", duration: 3)
            updateStatusMenu()
            NSLog("[BlazingVoice3] Realtime chunked recording started")
        } catch {
            pipelineState = .idle
            statusBarController?.updateState(.error)
            overlay?.show(message: "録音エラー")
            updateStatusMenu()
            NSLog("[BlazingVoice3] Realtime error: %@", "\(error)")
        }
    }

    /// Extract the unprocessed portion of the current STT text
    private func extractCurrentChunk(from fullText: String) -> String {
        guard lastChunkEndIndex < fullText.count else { return "" }
        let start = fullText.index(fullText.startIndex, offsetBy: lastChunkEndIndex)
        return String(fullText[start...])
    }

    /// Process a breath-pause chunk through LLM
    private func processCurrentChunk() {
        let fullText = lastPartialText
        let chunk = extractCurrentChunk(from: fullText)
        guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSLog("[Realtime] Chunk empty, skipping")
            return
        }

        lastChunkEndIndex = fullText.count
        NSLog("[Realtime] Chunk #%d (%d chars): %@",
              processedChunks.count + 1, chunk.count, String(chunk.prefix(50)))
        enqueueRealtimeChunk(chunk)
    }

    private func enqueueRealtimeChunk(_ chunk: String) {
        let previousTask = realtimeChunkTask
        realtimeChunkTask = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            let output = await self.generateRealtimeOutput(for: chunk)
            guard !Task.isCancelled else { return }
            self.processedChunks.append(output)
            await TextInjector.paste(output)
        }
    }

    private func generateRealtimeOutput(for chunk: String) async -> String {
        guard let activeEngine = engineForMode(.normal) else {
            // No engine: paste regex-cleaned text directly
            return chunk
        }

        do {
            let prompt = settings.normalPrompt.isEmpty
                ? PromptTemplate.defaultNormalPrompt
                : settings.normalPrompt
            let messages = PromptTemplate.buildMessages(systemPrompt: prompt, userInput: chunk)
            let result = try await activeEngine.generate(
                messages: messages,
                maxTokens: 512,
                temperature: 0.1,
                priority: .high
            )
            let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[BlazingVoice3] Chunk → LLM: %@", String(cleaned.prefix(60)))
            return cleaned.isEmpty ? chunk : cleaned
        } catch {
            NSLog("[BlazingVoice3] Chunk LLM failed, regex fallback: %@", "\(error)")
            return chunk
        }
    }

    private func stopRealtimeAndFinalize() {
        NSLog("[BlazingVoice3] Stopping realtime")
        chunkTimer?.invalidate()
        chunkTimer = nil
        audioRecorder.onPartialResult = nil

        pipelineState = .processing
        statusBarController?.updateState(.processing)
        updateStatusMenu()

        Task { [weak self] in
            guard let self else { return }
            let finalTranscript: String
            do {
                finalTranscript = try await self.audioRecorder.stopRecordingAndTranscribe()
            } catch BlazingError.noSpeechResult {
                finalTranscript = self.lastPartialText
            } catch {
                NSLog("[BlazingVoice3] Realtime final STT failed, using last partial: %@", "\(error)")
                finalTranscript = self.lastPartialText
            }

            let cleanedFinalTranscript = FillerRemover.clean(finalTranscript)
            if !cleanedFinalTranscript.isEmpty {
                self.lastPartialText = cleanedFinalTranscript
            }
            self.processCurrentChunk()
            await self.realtimeChunkTask?.value

            // Also copy final text to clipboard
            let finalText = self.processedChunks.joined()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finalText, forType: .string)
            NSLog("[BlazingVoice3] Realtime done: %d chars → clipboard", finalText.count)

            self.pipelineState = .done
            self.statusBarController?.updateState(.done)
            self.overlay?.show(message: "入力完了 (\(finalText.count)文字)")
            self.updateStatusMenu()
            self.resetAfterDelay()
        }
    }

    // MARK: - Menu

    private func updateStatusMenu() {
        let menuBuilder = StatusBarMenu(appDelegate: self)
        statusBarController?.setMenu(menuBuilder.buildMenu())
    }

    private func performMenuAction(_ action: @MainActor () -> Void) {
        action()
    }

    @objc func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc func menuSelectMode(_ sender: NSMenuItem) {
        let allModes = VoiceMode.allCases
        guard sender.tag >= 0, sender.tag < allModes.count else { return }
        currentMode = allModes[sender.tag]
        settings.defaultVoiceModeRaw = currentMode.rawValue
        updateStatusMenu()
        overlay?.show(message: "\(currentMode.displayName) に切替", duration: 1.5)
        NSLog("[BlazingVoice3] Mode changed: %@", currentMode.rawValue)
    }

    @objc func menuStartRecording() {
        NSLog("[BlazingVoice3] Menu start recording tapped")
        performMenuAction { [weak self] in
            guard let self else { return }
            self.handleHotkeyPress(mode: self.currentMode)
        }
    }

    @objc func menuStopRecording() {
        NSLog("[BlazingVoice3] Menu stop recording tapped")
        performMenuAction { [weak self] in
            guard let self else { return }
            if self.pipelineState == .recording {
                self.handleHotkeyPress(mode: self.currentMode) // Same as pressing hotkey again
            }
        }
    }

    @objc func menuCopyHistory(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index >= 0, index < sessionHistory.sessions.count else { return }
        let session = sessionHistory.sessions[index]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.generatedText, forType: .string)
        overlay?.show(message: "履歴をコピーしました (Cmd+V)", duration: 1.5)
        NSLog("[BlazingVoice3] Copied history item %d to clipboard", index)
    }

    // MARK: - Debug Log

    private static let debugLogURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("BlazingVoice3.log")
    }()

    private func debugLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        NSLog("[BlazingVoice3] %@", message)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.debugLogURL.path) {
                if let handle = try? FileHandle(forWritingTo: Self.debugLogURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: Self.debugLogURL)
            }
        }
    }
}
