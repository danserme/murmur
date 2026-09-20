import AVFoundation
import Foundation
import Speech
import Synchronization

nonisolated enum TranscriptionService {
    struct TranscriptionFailed: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    enum ProgressUpdate: Sendable {
        case downloadingModel(Double?)
        case transcribing(text: String?, fraction: Double?)
    }

    @concurrent
    static func transcribe(
        fileURL: URL,
        onProgress: @escaping @MainActor @Sendable (ProgressUpdate) -> Void
    ) async throws -> String {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionFailed(message: "On-device speech transcription is not available on this Mac.")
        }

        let preferred = Locale(identifier: "en_US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) else {
            throw TranscriptionFailed(message: "English speech models are not supported on this Mac.")
        }

        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        try await ensureModel(for: transcriber, onProgress: onProgress)
        try Task.checkCancellation()
        try await AssetInventory.reserve(locale: locale)
        defer {
            Task {
                await AssetInventory.release(reservedLocale: locale)
            }
        }

        let audioFile = try AVAudioFile(forReading: fileURL)
        let durationSeconds = Double(audioFile.length) / Double(audioFile.processingFormat.sampleRate)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let latest = Mutex("")
        let progressBridge = ProgressBridge()

        try await analyzer.prepareToAnalyze(in: audioFile.processingFormat) { progress in
            progressBridge.attach(progress) { fraction in
                Task { @MainActor in
                    onProgress(.transcribing(text: nil, fraction: fraction))
                }
            }
        }

        let resultsTask = Task { () -> String in
            var finalized = ""
            for try await result in transcriber.results {
                try Task.checkCancellation()
                let piece = String(result.text.characters)
                let snapshot = finalized + piece
                if result.isFinal {
                    finalized += piece
                }
                latest.withLock { $0 = snapshot }
                let endSeconds = result.range.end.seconds
                let fraction = durationSeconds > 0 ? min(1, max(0, endSeconds / durationSeconds)) : nil
                await onProgress(
                    .transcribing(
                        text: snapshot.trimmingCharacters(in: .whitespacesAndNewlines),
                        fraction: fraction
                    )
                )
            }
            return latest.withLock { $0 }.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    try Task.checkCancellation()
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
            } catch is CancellationError {
                await analyzer.cancelAndFinishNow()
                resultsTask.cancel()
                throw CancellationError()
            } catch {
                await analyzer.cancelAndFinishNow()
                resultsTask.cancel()
                if Task.isCancelled { throw CancellationError() }
                throw TranscriptionFailed(message: "Could not read this recording. Voice Memos usually export as M4A.")
            }
        } onCancel: {
            resultsTask.cancel()
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }

        do {
            let transcript = try await resultsTask.value
            guard !transcript.isEmpty else {
                throw TranscriptionFailed(message: "No speech was recognized. Try a clearer English recording.")
            }
            return transcript
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    private static func ensureModel(
        for transcriber: SpeechTranscriber,
        onProgress: @escaping @MainActor @Sendable (ProgressUpdate) -> Void
    ) async throws {
        try Task.checkCancellation()
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            break
        case .supported, .downloading:
            await onProgress(.downloadingModel(nil))
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let bridge = ProgressBridge()
                bridge.attach(request.progress) { fraction in
                    Task { @MainActor in
                        onProgress(.downloadingModel(request.progress.isIndeterminate ? nil : fraction))
                    }
                }
                try await request.downloadAndInstall()
                bridge.invalidate()
            }
        case .unsupported:
            throw TranscriptionFailed(message: "The English speech model is not supported on this Mac.")
        @unknown default:
            throw TranscriptionFailed(message: "Could not prepare the speech model.")
        }
    }
}

nonisolated private final class ProgressBridge: @unchecked Sendable {
    private var observation: NSKeyValueObservation?
    private let lock = NSLock()

    func attach(_ progress: Progress, handler: @escaping @Sendable (Double) -> Void) {
        let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            handler(progress.fractionCompleted)
        }
        lock.withLock {
            self.observation?.invalidate()
            self.observation = observation
        }
    }

    func invalidate() {
        lock.withLock {
            observation?.invalidate()
            observation = nil
        }
    }

    deinit {
        invalidate()
    }
}
