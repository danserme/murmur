import Foundation

nonisolated enum SummaryProvider: String, CaseIterable, Identifiable, Sendable {
    case onThisMac
    case chatGPT
    case claude
    case deepseek
    case cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onThisMac: "On this Mac"
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .deepseek: "DeepSeek"
        case .cursor: "Cursor"
        }
    }

    var detail: String {
        switch self {
        case .onThisMac:
            "Uses Apple Intelligence on this Mac. The transcript does not leave the device."
        case .chatGPT:
            "Sends the transcript to OpenAI’s ChatGPT API."
        case .claude:
            "Sends the transcript to Anthropic’s Claude API."
        case .deepseek:
            "Sends the transcript to DeepSeek’s API."
        case .cursor:
            "Sends the transcript to Cursor’s API."
        }
    }

    var apiAccount: APIKeyStore.Account? {
        switch self {
        case .onThisMac: nil
        case .chatGPT: .openAI
        case .claude: .anthropic
        case .deepseek: .deepseek
        case .cursor: .cursor
        }
    }

    var hasAPIKey: Bool {
        guard let apiAccount else { return false }
        return APIKeyStore.hasKey(apiAccount)
    }
}

nonisolated enum SummaryPreferences {
    private static let providerKey = "summaryProvider"
    private static let noteStructureKey = "noteStructure"

    static let defaultNoteStructure = """
    Title
    A short headline.

    Overview
    1–3 sentences.

    Key points
    Bullet list.

    Action items
    Bullet list of things that were actually requested or promised. If none, write “None.”
    """

    static var noteStructure: String {
        get {
            let stored = UserDefaults.standard.string(forKey: noteStructureKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty {
                return stored
            }
            return defaultNoteStructure
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: noteStructureKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: noteStructureKey)
            }
        }
    }

    static var systemPrompt: String {
        """
        You summarize voice memo transcripts for the person who recorded them.
        Stay faithful to the recording. Do not invent names, dates, or tasks.
        Write the notes in the same language as the transcript.
        Write the notes in this structure:

        \(noteStructure)
        """
    }

    static var provider: SummaryProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: providerKey),
                  let value = SummaryProvider(rawValue: raw)
            else {
                return .onThisMac
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: providerKey)
        }
    }
}
