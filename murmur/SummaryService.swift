import Foundation
import FoundationModels

nonisolated enum SummaryService {
    struct SummaryFailed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isOnDeviceAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    static func availabilityMessage() -> String {
        switch SummaryPreferences.provider {
        case .onThisMac:
            if isOnDeviceAvailable {
                return "Summaries stay on this Mac with Apple Intelligence."
            }
            return onDeviceUnavailableMessage()
        case .chatGPT, .claude, .deepseek, .cursor:
            let provider = SummaryPreferences.provider
            if provider.hasAPIKey {
                return "Summaries run through \(provider.title)."
            }
            if isOnDeviceAvailable {
                return "Add a \(provider.title) API key, or switch to On this Mac in Settings."
            }
            return "Add a \(provider.title) API key in Settings to summarize in this app."
        }
    }

    static func summarizingStatusMessage() -> String {
        switch resolvedProvider() {
        case .onThisMac:
            return "Writing a summary on this Mac…"
        case .chatGPT, .claude, .deepseek, .cursor:
            return "Asking \(resolvedProvider().title) for a summary…"
        }
    }

    static func transcribedStatusMessage() -> String {
        switch resolvedProvider() {
        case .onThisMac:
            return "Transcript ready. Summarizing on this Mac…"
        case .chatGPT, .claude, .deepseek, .cursor:
            return "Transcript ready. Summarizing with \(resolvedProvider().title)…"
        }
    }

    @concurrent
    static func summarize(
        _ transcript: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        switch resolvedProvider() {
        case .onThisMac:
            return try await summarizeOnDevice(transcript, onPartial: onPartial)
        case .cursor:
            return try await summarizeWithCursor(transcript, onPartial: onPartial)
        case .chatGPT, .claude, .deepseek:
            return try await summarizeWithCloud(transcript, onPartial: onPartial)
        }
    }

    private static func resolvedProvider() -> SummaryProvider {
        let preferred = SummaryPreferences.provider
        switch preferred {
        case .onThisMac:
            return .onThisMac
        case .chatGPT, .claude, .deepseek, .cursor:
            if preferred.hasAPIKey { return preferred }
            if isOnDeviceAvailable { return .onThisMac }
            return preferred
        }
    }

    private static func summarizeWithCloud(
        _ transcript: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let provider = SummaryPreferences.provider
        guard let account = provider.apiAccount, let apiKey = APIKeyStore.load(account) else {
            if isOnDeviceAvailable {
                return try await summarizeOnDevice(transcript, onPartial: onPartial)
            }
            throw SummaryFailed(message: "Add a \(provider.title) API key in Settings to summarize.")
        }

        do {
            return try await CloudSummaryService.summarize(
                transcript,
                provider: provider,
                apiKey: apiKey,
                onPartial: onPartial
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isOnDeviceAvailable {
                await onPartial("\(provider.title) did not finish. Trying Apple Intelligence on this Mac…")
                return try await summarizeOnDevice(transcript, onPartial: onPartial)
            }
            throw error
        }
    }

    private static func summarizeWithCursor(
        _ transcript: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        guard let apiKey = APIKeyStore.load(.cursor) else {
            if isOnDeviceAvailable {
                return try await summarizeOnDevice(transcript, onPartial: onPartial)
            }
            throw SummaryFailed(message: "Add a Cursor API key in Settings to summarize without leaving the app.")
        }

        do {
            return try await CursorSummaryService.summarize(transcript, apiKey: apiKey, onPartial: onPartial)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isOnDeviceAvailable {
                await onPartial("Cursor did not finish. Trying Apple Intelligence on this Mac…")
                return try await summarizeOnDevice(transcript, onPartial: onPartial)
            }
            throw error
        }
    }

    private static func summarizeOnDevice(
        _ transcript: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        guard isOnDeviceAvailable else {
            throw SummaryFailed(message: onDeviceUnavailableMessage())
        }

        do {
            return try await summarizeOnce(transcript, onPartial: onPartial)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            return try await summarizeInChunks(transcript, onPartial: onPartial)
        }
    }

    private static func onDeviceUnavailableMessage() -> String {
        let suffix = " Or choose ChatGPT, Claude, or DeepSeek in Settings after adding an API key."
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Apple Intelligence is ready on this Mac."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to summarize on this Mac.\(suffix)"
        case .unavailable(.deviceNotEligible):
            return "This Mac cannot run Apple Intelligence summaries.\(suffix)"
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading. Try again in a moment.\(suffix)"
        case .unavailable:
            return "Apple Intelligence is not available for summaries on this Mac.\(suffix)"
        }
    }

    private static func summarizeOnce(
        _ transcript: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let session = LanguageModelSession(
            instructions: SummaryPreferences.systemPrompt
        )

        var latest = ""
        for try await snapshot in session.streamResponse(to: "Summarize this transcript:\n\n\(transcript)") {
            try Task.checkCancellation()
            latest = snapshot.content
            await onPartial(latest)
        }
        return latest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func summarizeInChunks(
        _ transcript: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let chunks = chunk(transcript, target: 6000)
        var partialSummaries: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            await onPartial("Summarizing part \(index + 1) of \(chunks.count) on this Mac…")
            let session = LanguageModelSession(
                instructions: "Summarize this section of a longer voice memo. Keep facts. Use short bullets."
            )
            let response = try await session.respond(to: chunk)
            partialSummaries.append(response.content)
        }

        let combined = partialSummaries.enumerated()
            .map { "Part \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        return try await summarizeOnce(combined, onPartial: onPartial)
    }

    private static func chunk(_ text: String, target: Int) -> [String] {
        guard text.count > target else { return [text] }
        var chunks: [String] = []
        var remaining = text[...]
        while !remaining.isEmpty {
            if remaining.count <= target {
                chunks.append(String(remaining))
                break
            }
            let end = remaining.index(remaining.startIndex, offsetBy: target)
            let window = remaining[..<end]
            let breakAt = window.lastIndex(of: "\n") ?? window.lastIndex(of: ".") ?? window.lastIndex(of: " ") ?? end
            chunks.append(String(remaining[remaining.startIndex...breakAt]))
            remaining = remaining[remaining.index(after: breakAt)...]
        }
        return chunks
    }
}
