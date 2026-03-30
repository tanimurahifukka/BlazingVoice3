import SwiftUI

final class AppSettings: ObservableObject {
    // MARK: - General
    @AppStorage("setupCompleted") var setupCompleted = false
    @AppStorage("launchAtLogin") var launchAtLogin = false

    // MARK: - Voice Mode (default = dictation/SOAP)
    @AppStorage("defaultVoiceMode") var defaultVoiceModeRaw = VoiceMode.dictation.rawValue

    var defaultVoiceMode: VoiceMode {
        get { VoiceMode(rawValue: defaultVoiceModeRaw) ?? .normal }
        set { defaultVoiceModeRaw = newValue.rawValue }
    }

    // MARK: - Trigger (double-left-shift to start/stop)
    /// Double-tap interval threshold in seconds
    @AppStorage("doubleTapInterval") var doubleTapInterval: Double = 0.4
    /// Reserved for a future configurable non-modifier trigger.
    @AppStorage("triggerKeyCode") var triggerKeyCode: Int = 49

    // MARK: - Advanced Hotkeys (per-mode, hidden by default)
    @AppStorage("hotkeyModifierFlags") var hotkeyModifierFlags: Int = 0x80000
    @AppStorage("hotkeyKeyCode") var hotkeyKeyCode: Int = 49
    @AppStorage("bulletHotkeyModifierFlags") var bulletHotkeyModifierFlags: Int = 0x80000
    @AppStorage("bulletHotkeyKeyCode") var bulletHotkeyKeyCode: Int = 11
    @AppStorage("normalHotkeyModifierFlags") var normalHotkeyModifierFlags: Int = 0x80000
    @AppStorage("normalHotkeyKeyCode") var normalHotkeyKeyCode: Int = 45
    @AppStorage("clusterHotkeyModifierFlags") var clusterHotkeyModifierFlags: Int = 0x80000
    @AppStorage("clusterHotkeyKeyCode") var clusterHotkeyKeyCode: Int = 8

    // MARK: - Audio
    @AppStorage("maxRecordingDuration") var maxRecordingDuration: Double = 300
    @AppStorage("breathPauseInterval") var breathPauseInterval: Double = 1.2

    // MARK: - Model (per-mode)
    @AppStorage("engineBackend") var engineBackendRaw = "llama"
    @AppStorage("dictationModelId") var dictationModelId = "qwen3.5-4b-gguf"
    @AppStorage("conversationModelId") var conversationModelId = ""
    @AppStorage("normalModelId") var normalModelId = ""
    @AppStorage("clusterModelId") var clusterModelId = ""

    var selectedModelId: String {
        get { dictationModelId }
        set { dictationModelId = newValue }
    }

    var engineBackend: ModelManager.EngineBackend {
        get { ModelManager.EngineBackend(rawValue: engineBackendRaw) ?? .llama }
        set { engineBackendRaw = newValue.rawValue }
    }

    func modelId(for mode: VoiceMode) -> String {
        let id: String
        switch mode {
        case .normal: id = normalModelId
        case .dictation: id = dictationModelId
        case .conversation: id = conversationModelId
        case .cluster: id = clusterModelId
        }
        return id.isEmpty ? dictationModelId : id
    }

    // MARK: - Inference
    @AppStorage("llmMaxOutputTokens") var llmMaxOutputTokens: Int = 1024
    @AppStorage("llmTemperature") var llmTemperature: Double = 0.3
    @AppStorage("kvQuantizeMode") var kvQuantizeModeRaw = "off"
    @AppStorage("slotCount") var slotCount: Int = 2
    @AppStorage("maxMemoryGB") var maxMemoryGB: Double = 0

    var kvQuantizeMode: KVQuantizeMode {
        get { KVQuantizeMode(rawValue: kvQuantizeModeRaw) ?? .off }
        set { kvQuantizeModeRaw = newValue.rawValue }
    }

    // MARK: - Cluster
    @AppStorage("clusterEnabled") var clusterEnabled = false
    @AppStorage("clusterPort") var clusterPort: Int = 8080
    @AppStorage("explicitPeers") var explicitPeers = ""
    @AppStorage("spilloverThreshold") var spilloverThreshold: Double = 0.8

    // MARK: - Prompts
    @AppStorage("globalPrefixPrompt") var globalPrefixPrompt = PromptTemplate.globalPrefix
    @AppStorage("soapPrefixPrompt") var soapPrefixPrompt = PromptTemplate.soapPrefix
    @AppStorage("bulletPrefixPrompt") var bulletPrefixPrompt = PromptTemplate.bulletPrefix
    @AppStorage("normalPrompt") var normalPrompt = PromptTemplate.defaultNormalPrompt
    @AppStorage("customSOAPPrompt") var customSOAPPrompt = ""
    @AppStorage("customBulletPrompt") var customBulletPrompt = ""

    // MARK: - Computed

    var effectiveSOAPPrompt: String {
        customSOAPPrompt.isEmpty ? PromptTemplate.defaultSOAPPrompt : customSOAPPrompt
    }

    var effectiveBulletPrompt: String {
        customBulletPrompt.isEmpty ? PromptTemplate.defaultBulletPrompt : customBulletPrompt
    }

    var effectiveMaxMemoryGB: Double? {
        maxMemoryGB > 0 ? maxMemoryGB : nil
    }
}
