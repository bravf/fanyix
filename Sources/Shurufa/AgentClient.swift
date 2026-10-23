import Foundation
import TranslationCore

@MainActor
final class AgentClient {
    private let agent = NativeAgent()
    func translate(_ source: String, configuration: Configuration) async throws -> TranslationResult {
        try await agent.translate(source, configuration: configuration)
    }
    func close() { agent.close() }
}
