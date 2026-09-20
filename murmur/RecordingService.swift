import AVFoundation
import Foundation

struct RecordingFailed: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@Observable
final class AudioCapture {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0

    @ObservationIgnored
    private var recorder: AVAudioRecorder?
    @ObservationIgnored
    private var meterTask: Task<Void, Never>?
    @ObservationIgnored
    private var startedAt: Date?
    @ObservationIgnored
    private var outputURL: URL?

    func start(to url: URL) async throws {
        guard !isRecording else { return }

        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else {
            throw RecordingFailed(message: "Microphone access is needed to record in murmur.")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw RecordingFailed(message: "Could not start a recording.")
        }

        self.recorder = recorder
        outputURL = url
        startedAt = Date()
        elapsed = 0
        level = 0
        isRecording = true
        startMetering()
    }

    func stop() throws -> URL {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0

        guard let outputURL else {
            throw RecordingFailed(message: "The recording file was not saved.")
        }
        self.outputURL = nil

        if elapsed < 0.4 {
            try? FileManager.default.removeItem(at: outputURL)
            elapsed = 0
            throw RecordingFailed(message: "Recording was too short. Hold a little longer, then stop.")
        }

        elapsed = 0
        return outputURL
    }

    func discard() {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        elapsed = 0
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder, recorder.isRecording else { break }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                self.level = Self.normalized(power)
                if let startedAt = self.startedAt {
                    self.elapsed = Date().timeIntervalSince(startedAt)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private static func normalized(_ decibels: Float) -> Double {
        let minDb: Float = -50
        let clamped = max(minDb, min(0, decibels))
        return Double((clamped - minDb) / -minDb)
    }
}
