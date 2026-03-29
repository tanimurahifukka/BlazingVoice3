import Foundation

/// Wraps a local InferenceEngine and distributes requests across cluster nodes
/// using Uzu bandwidth-first routing.
final class ClusterEngine: InferenceEngine, @unchecked Sendable {
    private let localEngine: any InferenceEngine
    private let clusterManager: ClusterManager

    var modelDescription: String { localEngine.modelDescription }
    var slotCount: Int { localEngine.slotCount }

    init(localEngine: any InferenceEngine, clusterManager: ClusterManager) {
        self.localEngine = localEngine
        self.clusterManager = clusterManager
    }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Float,
        priority: SlotPriority
    ) async throws -> GenerationResult {
        guard let node = clusterManager.nextNode() else {
            return try await localEngine.generate(
                messages: messages, maxTokens: maxTokens,
                temperature: temperature, priority: priority
            )
        }

        clusterManager.router.recordStart(nodeId: node.id)
        let t0 = CFAbsoluteTimeGetCurrent()

        if node.isLocal {
            do {
                let result = try await localEngine.generate(
                    messages: messages, maxTokens: maxTokens,
                    temperature: temperature, priority: priority
                )
                let elapsed = CFAbsoluteTimeGetCurrent() - t0
                clusterManager.router.recordCompletion(
                    nodeId: node.id, tokens: result.completionTokens, durationSec: elapsed
                )
                return result
            } catch {
                clusterManager.router.recordFailure(nodeId: node.id)
                throw error
            }
        }

        do {
            let result = try await forwardToRemote(
                node: node, messages: messages,
                maxTokens: maxTokens, temperature: temperature
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            clusterManager.router.recordCompletion(
                nodeId: node.id, tokens: result.completionTokens, durationSec: elapsed
            )
            clusterManager.markHealthy(nodeId: node.id)
            return result
        } catch {
            print("[Uzu] Remote node \(node.id) failed: \(error)")
            clusterManager.markFailed(nodeId: node.id)

            if let fallback = clusterManager.nextNode(excluding: [node.id]) {
                clusterManager.router.recordStart(nodeId: fallback.id)
                let t1 = CFAbsoluteTimeGetCurrent()
                do {
                    let result: GenerationResult
                    if fallback.isLocal {
                        result = try await localEngine.generate(
                            messages: messages, maxTokens: maxTokens,
                            temperature: temperature, priority: priority
                        )
                    } else {
                        result = try await forwardToRemote(
                            node: fallback, messages: messages,
                            maxTokens: maxTokens, temperature: temperature
                        )
                        clusterManager.markHealthy(nodeId: fallback.id)
                    }
                    let elapsed1 = CFAbsoluteTimeGetCurrent() - t1
                    clusterManager.router.recordCompletion(
                        nodeId: fallback.id, tokens: result.completionTokens, durationSec: elapsed1
                    )
                    return result
                } catch {
                    clusterManager.router.recordFailure(nodeId: fallback.id)
                    throw error
                }
            }

            return try await localEngine.generate(
                messages: messages, maxTokens: maxTokens,
                temperature: temperature, priority: priority
            )
        }
    }

    func slotSummary() -> [(index: Int, state: String, priority: String, pos: Int32)] {
        localEngine.slotSummary()
    }

    func memoryInfo() -> EngineMemoryInfo? {
        localEngine.memoryInfo()
    }

    // MARK: - Remote Forwarding

    private func forwardToRemote(
        node: ClusterNode,
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Float
    ) async throws -> GenerationResult {
        let url = URL(string: "\(node.baseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "temperature": temperature,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw BlazingError.remoteNodeFailed
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw BlazingError.remoteNodeFailed
        }

        let usage = json["usage"] as? [String: Any]
        return GenerationResult(
            text: content,
            promptTokens: usage?["prompt_tokens"] as? Int ?? 0,
            completionTokens: usage?["completion_tokens"] as? Int ?? 0
        )
    }
}
