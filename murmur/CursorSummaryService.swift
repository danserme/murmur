import Foundation

nonisolated enum CursorSummaryService {
    struct CursorFailed: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private static let baseURL = URL(string: "https://api.cursor.com")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 1_200
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    @concurrent
    static func summarize(
        _ transcript: String,
        apiKey: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        await onPartial("Starting Cursor… cloud agents can take a minute to wake up.")
        let created = try await createAgent(transcript: transcript, apiKey: apiKey)
        try Task.checkCancellation()

        if let finished = try await waitForRun(
            agentID: created.agentID,
            runID: created.runID,
            apiKey: apiKey,
            onPartial: onPartial
        ) {
            await onPartial(finished)
            return finished
        }

        do {
            return try await streamRun(
                agentID: created.agentID,
                runID: created.runID,
                apiKey: apiKey,
                onPartial: onPartial
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let fallback = try await fetchRunResult(
                agentID: created.agentID,
                runID: created.runID,
                apiKey: apiKey
            ) {
                await onPartial(fallback)
                return fallback
            }
            throw mapped(error)
        }
    }

    private struct CreatedAgent {
        let agentID: String
        let runID: String
    }

    private static func createAgent(transcript: String, apiKey: String) async throws -> CreatedAgent {
        var request = authenticatedRequest(
            ["v1", "agents"],
            apiKey: apiKey
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": "Voice memo summary",
            "prompt": ["text": prompt(for: transcript)],
        ])

        let (data, response) = try await data(for: request)
        try throwIfHTTPError(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let agentID = (json?["agent"] as? [String: Any])?["id"] as? String
        let runID = (json?["run"] as? [String: Any])?["id"] as? String
        guard let agentID, let runID else {
            throw CursorFailed(message: "Cursor returned an unexpected response when starting the summary.")
        }
        return CreatedAgent(agentID: agentID, runID: runID)
    }

    /// Returns a finished summary if the run completed while we waited, otherwise nil once it is running.
    private static func waitForRun(
        agentID: String,
        runID: String,
        apiKey: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String? {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            let snapshot = try await fetchRun(agentID: agentID, runID: runID, apiKey: apiKey)
            let status = snapshot.status.uppercased()
            await onPartial("Cursor is \(status.lowercased())…")

            if ["FINISHED", "COMPLETED"].contains(status), let text = snapshot.result, !text.isEmpty {
                return text
            }
            if ["ERROR", "FAILED"].contains(status) {
                throw CursorFailed(message: "Cursor could not finish the summary.")
            }
            if status == "CANCELLED" {
                throw CancellationError()
            }
            if ["RUNNING", "STREAMING"].contains(status) {
                return nil
            }
            try await Task.sleep(for: .seconds(2))
        }
        return nil
    }

    private static func streamRun(
        agentID: String,
        runID: String,
        apiKey: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let url = baseURL
            .appending(path: "v1")
            .appending(path: "agents")
            .appending(path: agentID)
            .appending(path: "runs")
            .appending(path: runID)
            .appending(path: "stream")
        var request = URLRequest(url: url, timeoutInterval: 1_200)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuth(apiKey, to: &request)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw mapped(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CursorFailed(message: httpMessage(status: http.statusCode))
        }

        var assembled = ""
        var eventName = "message"
        var dataLines: [String] = []
        var sawResult = false

        func flush() async throws {
            guard !dataLines.isEmpty else {
                eventName = "message"
                return
            }
            let payload = dataLines.joined(separator: "\n")
            dataLines = []
            let currentEvent = eventName
            eventName = "message"
            try await handle(
                event: currentEvent,
                payload: payload,
                assembled: &assembled,
                sawResult: &sawResult,
                onPartial: onPartial
            )
        }

        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if line.isEmpty {
                    try await flush()
                    continue
                }
                if line.hasPrefix(":") { continue }
                if line.hasPrefix("event:") {
                    eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
            }
            try await flush()
        } catch is CancellationError {
            await cancelRun(agentID: agentID, runID: runID, apiKey: apiKey)
            throw CancellationError()
        }

        let text = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if let fallback = try await fetchRunResult(agentID: agentID, runID: runID, apiKey: apiKey) {
                return fallback
            }
            throw CursorFailed(message: "Cursor finished without returning a summary.")
        }
        return text
    }

    private static func handle(
        event: String,
        payload: String,
        assembled: inout String,
        sawResult: inout Bool,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]

        switch event {
        case "assistant":
            if let delta = object?["text"] as? String, !delta.isEmpty {
                assembled += delta
                await onPartial(assembled)
            }
        case "status":
            if assembled.isEmpty, let status = object?["status"] as? String {
                await onPartial("Cursor is \(status.lowercased())…")
            }
        case "result":
            sawResult = true
            if let text = object?["text"] as? String, !text.isEmpty {
                assembled = text
                await onPartial(assembled)
            }
            if let status = object?["status"] as? String, status.uppercased() == "ERROR" {
                throw CursorFailed(message: "Cursor could not finish the summary.")
            }
        case "error":
            let message = (object?["message"] as? String) ?? "Cursor stream error."
            throw CursorFailed(message: message)
        default:
            break
        }
    }

    private struct RunSnapshot {
        var status: String
        var result: String?
    }

    private static func fetchRun(agentID: String, runID: String, apiKey: String) async throws -> RunSnapshot {
        let request = authenticatedRequest(
            ["v1", "agents", agentID, "runs", runID],
            apiKey: apiKey
        )
        let (data, response) = try await data(for: request)
        try throwIfHTTPError(response, data: data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return RunSnapshot(
            status: (json?["status"] as? String) ?? "",
            result: json?["result"] as? String
        )
    }

    private static func fetchRunResult(agentID: String, runID: String, apiKey: String) async throws -> String? {
        let snapshot = try await fetchRun(agentID: agentID, runID: runID, apiKey: apiKey)
        let text = snapshot.result?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["FINISHED", "COMPLETED"].contains(snapshot.status.uppercased()), let text, !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func cancelRun(agentID: String, runID: String, apiKey: String) async {
        var request = authenticatedRequest(
            ["v1", "agents", agentID, "runs", runID, "cancel"],
            apiKey: apiKey
        )
        request.httpMethod = "POST"
        _ = try? await session.data(for: request)
    }

    private static func authenticatedRequest(_ path: [String], apiKey: String) -> URLRequest {
        var url = baseURL
        for component in path {
            url.append(path: component)
        }
        var request = URLRequest(url: url, timeoutInterval: 600)
        applyAuth(apiKey, to: &request)
        return request
    }

    private static func applyAuth(_ apiKey: String, to request: inout URLRequest) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if error is CursorFailed { return error }
        let urlError = error as? URLError
        if urlError?.code == .timedOut || urlError?.code == .networkConnectionLost {
            return CursorFailed(message: "Cursor took too long to respond. The transcript is still here — press Summarize to try again.")
        }
        return CursorFailed(message: error.localizedDescription)
    }

    private static func throwIfHTTPError(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        throw CursorFailed(message: httpMessage(status: http.statusCode))
    }

    private static func httpMessage(status: Int) -> String {
        switch status {
        case 401, 403:
            return "Cursor rejected the API key. Check it in Settings → Cursor API."
        case 429:
            return "Cursor rate-limited the summary request. Try again in a moment."
        default:
            return "Cursor API error (\(status))."
        }
    }

    private static func prompt(for transcript: String) -> String {
        """
        Stay in this conversation and return only the summary — do not use tools, edit files, or ask follow-up questions.

        \(SummaryPreferences.systemPrompt)

        Transcript:
        \(transcript)
        """
    }
}
