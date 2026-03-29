import Foundation
import CLlama

/// KV Cache quantization mode.
enum KVQuantizeMode: String, CaseIterable, Sendable {
    case off       // float16 (default)
    case int8      // Q8_0 quantization (~50% memory reduction)
    case tq1       // TQ1_0 TurboQuant 1-bit (~88% memory reduction)
    case tq2       // TQ2_0 TurboQuant 2-bit (~78% memory reduction)

    var keyType: ggml_type {
        switch self {
        case .off:  return GGML_TYPE_F16
        case .int8: return GGML_TYPE_Q8_0
        case .tq1:  return GGML_TYPE_TQ1_0
        case .tq2:  return GGML_TYPE_TQ2_0
        }
    }

    var valueType: ggml_type {
        switch self {
        case .off:  return GGML_TYPE_F16
        case .int8: return GGML_TYPE_Q8_0
        case .tq1:  return GGML_TYPE_TQ1_0
        case .tq2:  return GGML_TYPE_TQ2_0
        }
    }

    var displayName: String {
        switch self {
        case .off:  return "float16 (default)"
        case .int8: return "int8 (~50% memory savings)"
        case .tq1:  return "TQ1 1-bit (~88% memory savings)"
        case .tq2:  return "TQ2 2-bit (~78% memory savings)"
        }
    }
}

struct KVCacheQuantizer {
    let mode: KVQuantizeMode

    init(mode: KVQuantizeMode = .off) {
        self.mode = mode
    }

    func apply(to params: inout llama_context_params) {
        params.type_k = mode.keyType
        params.type_v = mode.valueType

        if mode == .tq1 || mode == .tq2 {
            print("[KVCache] TurboQuant: K=\(mode.rawValue), V=\(mode.rawValue) (Metal FA accelerated)")
        }
    }
}

/// Global configuration for KV cache quantization.
final class KVCacheQuantizerConfig {
    static let shared = KVCacheQuantizerConfig()
    var mode: KVQuantizeMode = .off
    private init() {}
}
