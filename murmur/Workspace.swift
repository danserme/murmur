import AppKit
import Foundation
import Observation
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
    let capture = AudioCapture()

    @ObservationIgnored
    private var runningTask: Task<Void, Never>?

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

    var canRecord: Bool {
        !phase.isBusy
    }

    var canStop: Bool {
        phase.isBusy || capture.isRecording
    }

    var allowedContentTypes: [UTType] {
        [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
    }

    func refreshSummaryAvailability() {
        summaryAvailability = SummaryService.availabilityMessage()
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
        phase = .preparing
        statusMessage = "Preparing on-device English speech model…"

        let url = recording.fileURL
        runningTask?.cancel()
        runningTask = Task {
            do {
                let text = try await TranscriptionService.transcribe(fileURL: url) { [weak self] update in
                    self?.apply(update)
                }
                guard !Task.isCancelled else { return }
                transcript = text
                liveTranscript = ""
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
    }

    @discardableResult
    func revealSource(for summarySelection: String) -> Bool {
        guard let range = TranscriptAnchor.utf16Range(in: displayedTranscript, matching: summarySelection) else {
            sourceHighlight = nil
            return false
        }
        sourceHighlight = range
        sourceHighlightTick += 1
        return true
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
            statusMessage = "Downloading the English speech model. This happens once."
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
