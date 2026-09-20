import Foundation

struct ImportedRecording: Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let fileURL: URL

    static let supportedExtensions: Set<String> = [
        "m4a", "mp3", "wav", "caf", "aiff", "aif", "aac", "flac", "mp4", "m4b",
    ]

    static func importing(from originalURL: URL) throws -> ImportedRecording {
        let accessed = originalURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                originalURL.stopAccessingSecurityScopedResource()
            }
        }

        let id = UUID()
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "murmur", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let ext = originalURL.pathExtension.isEmpty ? "m4a" : originalURL.pathExtension
        let destination = folder.appending(path: "recording.\(ext)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: originalURL, to: destination)

        return ImportedRecording(
            id: id,
            displayName: originalURL.deletingPathExtension().lastPathComponent,
            fileURL: destination
        )
    }

    static func captured(at fileURL: URL, recordedAt date: Date = .now) -> ImportedRecording {
        ImportedRecording(
            id: UUID(),
            displayName: "Recording \(date.formatted(date: .abbreviated, time: .shortened))",
            fileURL: fileURL
        )
    }

    static func makeCaptureURL() throws -> URL {
        let id = UUID()
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "murmur", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "recording.m4a")
    }

    static func isSupported(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
