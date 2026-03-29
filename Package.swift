// swift-tools-version: 5.10
import PackageDescription

// Absolute paths to llama.cpp
let llamaDir = "\(Context.packageDirectory)/vendor/llama.cpp"
let llamaBuildDir = "\(llamaDir)/build"

let package = Package(
    name: "BlazingVoice3",
    platforms: [.macOS(.v14)],
    dependencies: [
        // MLX for Apple Silicon native inference
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
        // Note: WhisperKit excluded due to swift-transformers version conflict with mlx-swift-lm
        // WhisperKit requires swift-transformers 1.1.x while mlx-swift-lm requires 1.2.x
        // Using Apple Speech Framework (SFSpeechRecognizer) for STT instead
        // HotKey for global keyboard shortcuts
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.1"),
    ],
    targets: [
        // C wrapper for llama.cpp
        .target(
            name: "CLlama",
            path: "Sources/CLlama",
            cSettings: [
                .unsafeFlags([
                    "-I\(llamaDir)/include",
                    "-I\(llamaDir)/ggml/include",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(llamaBuildDir)/src",
                    "-L\(llamaBuildDir)/ggml/src",
                    "-L\(llamaBuildDir)/ggml/src/ggml-metal",
                    "-L\(llamaBuildDir)/ggml/src/ggml-blas",
                ]),
                .linkedLibrary("llama"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml-metal"),
                .linkedLibrary("ggml-cpu"),
                .linkedLibrary("ggml-blas"),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        // Main application
        .executableTarget(
            name: "BlazingVoice3",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // WhisperKit removed due to dependency conflict — using Apple Speech Framework
                .product(name: "HotKey", package: "HotKey"),
                "CLlama",
            ],
            path: "Sources/BlazingVoice3",
            resources: [
                .copy("Resources/DictionaryPreset.csv"),
            ]
        ),
        .testTarget(
            name: "BlazingVoice3Tests",
            dependencies: ["BlazingVoice3"],
            path: "Tests/BlazingVoice3Tests"
        ),
    ]
)
