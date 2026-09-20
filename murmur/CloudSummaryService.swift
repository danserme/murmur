import Foundation

nonisolated enum CloudSummaryService {
    struct CloudFailed: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    @concurrent
    static func summarize(
        _ transcript: String,
        provider: SummaryProvider,
        apiKey: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        switch provider {
        case .chatGPT, .deepseek:
            return try await openAICompatible(transcript, provider: provider, apiKey: apiKey, onPartial: onPartial)
        case .claude:
            return try await anthropic(transcript, apiKey: apiKey, onPartial: onPartial)
        case .onThisMac, .cursor:
            throw CloudFailed(message: "This provider is not handled as a chat API.")
        }
    }

    private static func openAICompatible(
        _ transcript: String,
        provider: SummaryProvider,
        apiKey: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let url = switch provider {
        case .chatGPT: URL(string: "https://api.openai.com/v1/chat/completions")!
        case .deepseek: URL(string: "https://api.deepseek.com/v1/chat/completions")!
        default: URL(string: "https://api.openai.com/v1/chat/completions")!
        }
        let model = switch provider {
        case .chatGPT: "gpt-4o-mini"
        case .deepseek: "deepseek-chat"
        default: "gpt-4o-mini"
        }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Summarize this transcript:\n\n\(transcript)"],
            ],
        ])

        let (bytes, response) = try await session.bytes(for: request)
        try throwIfHTTPError(response, provider: provider, data: nil)

        var assembled = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String
            else { continue }
            assembled += content
            await onPartial(assembled)
        }

        let text = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CloudFailed(message: "\(provider.title) finished without returning a summary.")
        }
        return text
    }

    private static func anthropic(
        _ transcript: String,
        apiKey: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4-5",
            "max_tokens": 2048,
            "stream": true,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": "Summarize this transcript:\n\n\(transcript)"],
            ],
        ])

        let (bytes, response) = try await session.bytes(for: request)
        try throwIfHTTPError(response, provider: .claude, data: nil)

        var assembled = ""
        var eventName = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if eventName == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                assembled += text
                await onPartial(assembled)
            } else if eventName == "error" {
                let message = (json["error"] as? [String: Any])?["message"] as? String
                throw CloudFailed(message: message ?? "Claude returned an error.")
            }
        }

        let text = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CloudFailed(message: "Claude finished without returning a summary.")
        }
        return text
    }

    private static func throwIfHTTPError(_ response: URLResponse, provider: SummaryProvider, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        throw CloudFailed(message: httpMessage(status: http.statusCode, provider: provider))
    }

    private static func httpMessage(status: Int, provider: SummaryProvider) -> String {
        switch status {
        case 401, 403:
            return "\(provider.title) rejected the API key. Check it in Settings."
        case 404:
            return "\(provider.title) could not find that model. Try again later."
        case 429:
            return "\(provider.title) rate-limited the request. Try again in a moment."
        default:
            return "\(provider.title) API error (\(status))."
        }
    }

    private static var systemPrompt: String {
        SummaryPreferences.systemPrompt
    }
}
