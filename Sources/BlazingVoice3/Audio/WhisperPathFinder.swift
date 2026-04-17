import Foundation

/// Locates the `whisper-cli` binary on the user's machine.
/// Used by the launch-time auto-fill and the "自動検出" button in settings.
enum WhisperPathFinder {
    /// Common install locations on macOS, checked in order.
    private static let candidatePaths = [
        "/opt/homebrew/bin/whisper-cli",   // Apple Silicon Homebrew
        "/usr/local/bin/whisper-cli",      // Intel Homebrew / source install
        "/opt/local/bin/whisper-cli",      // MacPorts
        "/opt/homebrew/bin/whisper",       // older whisper-cpp formula
        "/usr/local/bin/whisper",
    ]

    /// Suggested install command shown to the user when detection fails.
    static let installCommand = "brew install whisper-cpp"

    /// Scans known paths and `/usr/bin/which` fallback. Returns an absolute
    /// path if an executable is found, otherwise nil.
    static func detect() -> String? {
        let fm = FileManager.default
        for path in candidatePaths {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return runWhich()
    }

    /// Invoke `/usr/bin/which whisper-cli` in a login-ish shell so that
    /// user-customized PATH (zshenv / brew shellenv) is honored.
    private static func runWhich() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v whisper-cli || command -v whisper"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
            guard !firstLine.isEmpty,
                  FileManager.default.isExecutableFile(atPath: firstLine) else {
                return nil
            }
            return firstLine
        } catch {
            return nil
        }
    }
}
