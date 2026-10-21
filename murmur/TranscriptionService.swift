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
        locale preferred: Locale,
        onProgress: @escaping @MainActor @Sendable (ProgressUpdate) -> Void
    ) async throws -> String {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionFailed(message: "On-device speech transcription is not available on this Mac.")
        }

        let languageName = TranscriptionLanguage.title(for: preferred)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) else {
            throw TranscriptionFailed(message: "\(languageName) speech models are not supported on this Mac.")
        }

        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        // Reserve before downloading and keep the reservation: macOS may delete models for unreserved locales.
        try await reserve(locale)
        try await ensureModel(for: transcriber, languageName: languageName, onProgress: onProgress)
        try Task.checkCancellation()

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionFailed(message: "Could not read this recording. Voice Memos usually export as M4A.")
        }
        let durationSeconds = Double(audioFile.length) / Double(audioFile.processingFormat.sampleRate)
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? audioFile.processingFormat
        let source = try FileAudioSource(file: audioFile, outputFormat: analyzerFormat)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let latest = Mutex(LiveSnapshot())
        let progressBridge = ProgressBridge()

        try await analyzer.prepareToAnalyze(in: analyzerFormat) { progress in
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
                let endSeconds = result.range.end.seconds
                let fraction = durationSeconds > 0 ? min(1, max(0, endSeconds / durationSeconds)) : nil
                latest.withLock { $0.update(text: snapshot, fraction: fraction) }
            }
            return latest.withLock { $0.text }.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Publish the live transcript on a timer instead of per result. Awaiting the UI for each of the
        // thousands of results throttles the analyzer to the speed of re-rendering the growing transcript.
        let liveUpdates = Task {
            var shownVersion = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                let current = latest.withLock { $0 }
                guard current.version != shownVersion else { continue }
                shownVersion = current.version
                await onProgress(
                    .transcribing(
                        text: current.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        fraction: current.fraction
                    )
                )
            }
        }
        defer { liveUpdates.cancel() }

        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let input = AsyncStream { source.next().map { AnalyzerInput(buffer: $0) } }
                let lastSample = try await analyzer.analyzeSequence(input)
                if let readError = source.readError {
                    throw readError
                }
                if let lastSample {
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
                throw TranscriptionFailed(message: "Could not transcribe this recording. \(error.localizedDescription)")
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
                throw TranscriptionFailed(message: "No speech was recognized. Check that \(languageName) matches the recording.")
            }
            return transcript
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    private static func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { TranscriptionLanguage.matches($0, locale) }) else { return }
        if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            await AssetInventory.release(reservedLocale: oldest)
        }
        _ = try await AssetInventory.reserve(locale: locale)
    }

    private static func ensureModel(
        for transcriber: SpeechTranscriber,
        languageName: String,
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
            throw TranscriptionFailed(message: "The \(languageName) speech model is not supported on this Mac.")
        @unknown default:
            throw TranscriptionFailed(message: "Could not prepare the speech model.")
        }
    }
}

/// Feeds a file to the analyzer in the analyzer's format. Unlike `analyzeSequence(from:)`, it ends
/// cleanly when a file is shorter than its header claims (common for M4A), instead of failing with eofErr.
nonisolated private struct LiveSnapshot: Sendable {
    private(set) var text = ""
    private(set) var fraction: Double?
    private(set) var version = 0

    mutating func update(text: String, fraction: Double?) {
        self.text = text
        if let fraction {
            self.fraction = fraction
        }
        version += 1
    }
}

nonisolated private final class FileAudioSource: @unchecked Sendable {
    private static let chunkFrames: AVAudioFrameCount = 16_384

    private let file: AVAudioFile
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let lock = NSLock()
    private var isFinished = false
    private(set) var readError: Error?

    init(file: AVAudioFile, outputFormat: AVAudioFormat) throws {
        self.file = file
        self.outputFormat = outputFormat
        if file.processingFormat == outputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
                throw TranscriptionService.TranscriptionFailed(message: "Could not convert this recording for the speech model.")
            }
            self.converter = converter
        }
    }

    func next() -> AVAudioPCMBuffer? {
        lock.withLock {
            guard !isFinished else { return nil }
            guard let chunk = readChunk() else {
                isFinished = true
                return nil
            }
            guard let converter else { return chunk }
            guard let converted = convert(chunk, with: converter) else {
                isFinished = true
                return nil
            }
            return converted
        }
    }

    private func readChunk() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.chunkFrames) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == Int(eofErr) {
            return nil
        } catch {
            readError = error
            return nil
        }
        return buffer.frameLength > 0 ? buffer : nil
    }

    private func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            readError = conversionError
            return nil
        }
        return output
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
