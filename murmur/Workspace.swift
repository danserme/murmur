import AppKit
import Foundation
import NaturalLanguage
import Observation
import Translation
import UniformTypeIdentifiers

@Observable
final class Workspace {
    var recording: ImportedRecording?
    var transcript = ""
    var liveTranscript = ""
    var summary = ""
    var phase: Phase = .idle
    var statusMessage = "Record here, or drop a Voice Memo to transcribe it on this Mac."
    var errorMessage: String?
    var isFileImporterPresented = false
    var summaryAvailability = SummaryService.availabilityMessage()
    var jobProgress: Double?
    var sourceHighlight: NSRange?
    var sourceHighlightTick = 0
    var transcriptionLocale = TranscriptionLanguage.selected
    var availableLanguages: [Locale] = []
    var transcriptLocale: Locale? {
        didSet { updateSourceLanguage() }
    }
    /// Language of the text in the transcript pane: the transcription language, or detected for typed text.
    private(set) var sourceLanguage: Locale.Language?
    var translation = ""
    var isTranslating = false
    var translationProgress: Double?
    var transcriptTab: TranscriptTab = .transcript
    var translationConfiguration: TranslationSession.Configuration?
    let capture = AudioCapture()

    @ObservationIgnored
    private var runningTask: Task<Void, Never>?
    @ObservationIgnored
    private var translationCancelled = false

    var displayedTranscript: String {
        liveTranscript.isEmpty ? transcript : liveTranscript
    }

    var canTranscribe: Bool {
        recording != nil && !phase.isBusy && !capture.isRecording
    }

    var canSummarize: Bool {
        !displayedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !phase.isBusy
            && !capture.isRecording
    }

    var languageTitle: String {
        TranscriptionLanguage.title(for: transcriptionLocale)
    }

    var canChangeLanguage: Bool {
        !phase.isBusy
    }

    /// The transcript is in a language other than English, so it can be translated.
    var needsTranslation: Bool {
        guard let sourceLanguage else { return false }
        return sourceLanguage.languageCode != .english
    }

    var showsTranslationTab: Bool {
        needsTranslation || !translation.isEmpty
    }

    var canTranslate: Bool {
        needsTranslation
            && !displayedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isTranslating
            && phase != .preparing
            && phase != .transcribing
            && !capture.isRecording
    }

    var canRecord: Bool {
        !phase.isBusy
    }

    var canStop: Bool {
        phase.isBusy || capture.isRecording || isTranslating
    }

    var allowedContentTypes: [UTType] {
        [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
    }

    func refreshSummaryAvailability() {
        summaryAvailability = SummaryService.availabilityMessage()
    }

    func loadLanguages() async {
        guard availableLanguages.isEmpty else { return }
        availableLanguages = await TranscriptionLanguage.supported()
    }

    func setLanguage(_ locale: Locale) {
        guard canChangeLanguage, !TranscriptionLanguage.matches(locale, transcriptionLocale) else { return }
        transcriptionLocale = locale
        TranscriptionLanguage.selected = locale
        if recording != nil && !capture.isRecording {
            statusMessage = "Language set to \(languageTitle). Press Transcribe to redo this recording."
        }
    }

    func importFile(from url: URL) {
        if capture.isRecording {
            capture.discard()
        }
        errorMessage = nil
        do {
            recording = try ImportedRecording.importing(from: url)
            transcript = ""
            liveTranscript = ""
            summary = ""
            jobProgress = nil
            clearSourceHighlight()
            phase = .ready
            statusMessage = "Ready to transcribe \(recording?.displayName ?? "recording")."
            transcribeCurrentFile()
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    func toggleRecording() {
        if capture.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard canRecord, !capture.isRecording else { return }
        errorMessage = nil
        runningTask?.cancel()
        runningTask = nil
        runningTask = Task {
            do {
                let url = try ImportedRecording.makeCaptureURL()
                try await capture.start(to: url)
                phase = .recording
                statusMessage = "Recording… Press Stop when you are done."
            } catch {
                phase = recording == nil ? .idle : .ready
                errorMessage = error.localizedDescription
                statusMessage = "Could not start recording."
            }
        }
    }

    func stopRecording() {
        guard capture.isRecording else { return }
        do {
            let url = try capture.stop()
            recording = .captured(at: url)
            transcript = ""
            liveTranscript = ""
            summary = ""
            jobProgress = nil
            clearSourceHighlight()
            phase = .ready
            statusMessage = "Ready to transcribe \(recording?.displayName ?? "recording")."
            transcribeCurrentFile()
        } catch {
            phase = recording == nil ? .idle : .ready
            errorMessage = error.localizedDescription
            statusMessage = "Recording did not save."
        }
    }

    func transcribeCurrentFile() {
        guard let recording else { return }
        guard !phase.isBusy else { return }
        errorMessage = nil
        summary = ""
        transcript = ""
        liveTranscript = ""
        jobProgress = nil
        clearSourceHighlight()
        resetTranslation()
        phase = .preparing
        statusMessage = "Preparing on-device \(languageTitle) speech model…"

        let url = recording.fileURL
        let locale = transcriptionLocale
        transcriptLocale = locale
        runningTask?.cancel()
        runningTask = Task {
            do {
                let text = try await TranscriptionService.transcribe(fileURL: url, locale: locale) { [weak self] update in
                    self?.apply(update)
                }
                guard !Task.isCancelled else { return }
                transcript = text
                liveTranscript = ""
                updateSourceLanguage()
                jobProgress = 1
                phase = .transcribed
                statusMessage = SummaryService.transcribedStatusMessage()
                await runSummary(for: text)
            } catch is CancellationError {
                keepPartialTranscript(status: "Stopped transcription.")
            } catch {
                jobProgress = nil
                phase = .ready
                errorMessage = error.localizedDescription
                statusMessage = "Could not finish transcription."
            }
        }
    }

    func summarizeTranscript() {
        let text = displayedTranscript
        guard canSummarize else { return }
        errorMessage = nil
        runningTask?.cancel()
        runningTask = Task { await runSummary(for: text) }
    }

    func stop() {
        if capture.isRecording {
            stopRecording()
            return
        }
        if isTranslating && !phase.isBusy {
            translationCancelled = true
            return
        }
        guard canStop else { return }
        runningTask?.cancel()
        runningTask = nil
        if phase == .summarizing {
            phase = transcript.isEmpty ? .ready : .transcribed
            jobProgress = nil
            statusMessage = "Stopped summary. Transcript is still here."
        } else {
            keepPartialTranscript(status: "Stopped transcription.")
        }
    }

    func replaceTranscript(_ value: String) {
        liveTranscript = ""
        transcript = value
        clearSourceHighlight()
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcriptLocale = nil
        } else {
            updateSourceLanguage()
        }
    }

    @discardableResult
    func revealSource(for summarySelection: String) -> Bool {
        transcriptTab = .transcript
        guard let range = TranscriptAnchor.utf16Range(in: displayedTranscript, matching: summarySelection) else {
            sourceHighlight = nil
            return false
        }
        sourceHighlight = range
        sourceHighlightTick += 1
        return true
    }

    func requestTranslation() {
        guard canTranslate, let sourceLanguage else { return }
        transcriptTab = .translation
        let configuration = TranslationSession.Configuration(
            source: sourceLanguage,
            target: Locale.Language(identifier: "en")
        )
        if translationConfiguration == configuration {
            translationConfiguration?.invalidate()
        } else {
            translationConfiguration = configuration
        }
    }

    /// Runs from `.translationTask`, which supplies the session and asks to download missing languages.
    func translate(using session: TranslationSession) async {
        let text = displayedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isTranslating else { return }
        isTranslating = true
        translationCancelled = false
        translation = ""
        translationProgress = 0
        errorMessage = nil
        statusMessage = "Translating to English on this Mac…"

        // TranslationSession isn't Sendable, but this task is its only user.
        nonisolated(unsafe) let session = session
        let chunks = Self.translationChunks(of: text)
        var parts: [String] = []
        do {
            for (index, chunk) in chunks.enumerated() {
                guard !translationCancelled, !Task.isCancelled else { break }
                let response = try await session.translate(chunk)
                parts.append(response.targetText)
                translation = parts.joined(separator: " ")
                translationProgress = Double(index + 1) / Double(chunks.count)
            }
            if !phase.isBusy {
                statusMessage = parts.count < chunks.count
                    ? "Stopped translation. Partial translation kept."
                    : "Translated to English."
            }
        } catch {
            if !translationCancelled {
                errorMessage = "Could not translate this transcript. \(error.localizedDescription)"
                statusMessage = parts.isEmpty ? "Translation did not finish." : "Translation stopped early. Partial translation kept."
            }
        }
        isTranslating = false
        translationProgress = nil
    }

    func replaceTranslation(_ value: String) {
        translation = value
    }

    func copyTranslation() {
        copyToPasteboard(translation)
    }

    func clearSourceHighlight() {
        sourceHighlight = nil
    }

    func replaceSummary(_ value: String) {
        summary = value
    }

    func copyTranscript() {
        copyToPasteboard(displayedTranscript)
    }

    func copySummary() {
        copyToPasteboard(summary)
    }

    private func runSummary(for text: String) async {
        refreshSummaryAvailability()
        phase = .summarizing
        statusMessage = SummaryService.summarizingStatusMessage()
        jobProgress = nil
        summary = ""

        do {
            let result = try await SummaryService.summarize(text) { [weak self] partial in
                self?.summary = partial
            }
            guard !Task.isCancelled else { return }
            summary = result
            jobProgress = nil
            phase = .done
            statusMessage = "Transcript and summary are ready."
        } catch is CancellationError {
            jobProgress = nil
            phase = transcript.isEmpty ? .ready : .transcribed
            statusMessage = "Stopped summary. Transcript is still here."
        } catch {
            jobProgress = nil
            phase = transcript.isEmpty ? .ready : .transcribed
            summary = error.localizedDescription
            statusMessage = "Transcript is ready. Press Summarize to retry."
        }
    }

    private func updateSourceLanguage() {
        if let transcriptLocale {
            sourceLanguage = Locale.Language(languageCode: transcriptLocale.language.languageCode)
            return
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(displayedTranscript.prefix(4000)))
        if let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.6 {
            sourceLanguage = Locale.Language(identifier: language.rawValue)
        } else {
            sourceLanguage = nil
        }
    }

    private func resetTranslation() {
        translationCancelled = true
        translation = ""
        transcriptTab = .transcript
        transcriptLocale = nil
    }

    /// Groups sentences into requests of a few hundred characters, so each keeps some context.
    private static func translationChunks(of text: String, target: Int = 600) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var chunks: [String] = []
        var current = ""
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            if !current.isEmpty && current.count + sentence.count > target {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? sentence : " " + sentence
            return true
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func keepPartialTranscript(status: String) {
        let partial = displayedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = partial
        liveTranscript = ""
        jobProgress = nil
        phase = partial.isEmpty ? .ready : .transcribed
        statusMessage = partial.isEmpty ? status : "\(status) Partial transcript kept."
    }

    private func apply(_ update: TranscriptionService.ProgressUpdate) {
        switch update {
        case .downloadingModel(let fraction):
            phase = .preparing
            jobProgress = fraction
            statusMessage = "Downloading the \(languageTitle) speech model. This happens once."
        case .transcribing(let text, let fraction):
            phase = .transcribing
            if let text {
                liveTranscript = text
            }
            if let fraction {
                jobProgress = fraction
            }
            statusMessage = "Transcribing locally… Press Stop to cancel."
        }
    }

    private func copyToPasteboard(_ string: String) {
        guard !string.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

extension Workspace {
    enum TranscriptTab: Hashable {
        case transcript
        case translation
    }

    enum Phase: Equatable {
        case idle
        case ready
        case recording
        case preparing
        case transcribing
        case transcribed
        case summarizing
        case done

        var isBusy: Bool {
            switch self {
            case .preparing, .transcribing, .summarizing: true
            default: false
            }
        }
    }
}
