import AppKit
import Foundation

@MainActor
enum InstallerCleanup {
    private static let handledKey = "didOfferInstallerCleanup"
    private static let installerVolumeName = "murmur"

    struct Prompt: Equatable {
        var volumeURL: URL?
        var diskImages: [URL]
    }

    static func promptIfNeeded() -> Prompt? {
        if UserDefaults.standard.bool(forKey: handledKey) { return nil }
        guard isInstalledCopy else { return nil }
        let volume = mountedInstallerVolume()
        let images = installerDiskImages()
        guard volume != nil || !images.isEmpty else { return nil }
        return Prompt(volumeURL: volume, diskImages: images)
    }

    static func markHandled() {
        UserDefaults.standard.set(true, forKey: handledKey)
    }

    static func cleanup(_ prompt: Prompt?) async {
        guard let prompt else {
            markHandled()
            return
        }

        if let volume = prompt.volumeURL {
            _ = try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        }

        if !prompt.diskImages.isEmpty {
            do {
                _ = try await NSWorkspace.shared.recycle(prompt.diskImages)
            } catch {
                NSWorkspace.shared.activateFileViewerSelecting(prompt.diskImages)
            }
        }

        markHandled()
    }

    private static var isInstalledCopy: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if path.hasPrefix("/Volumes/") { return false }
        let fileManager = FileManager.default
        let folders =
            fileManager.urls(for: .applicationDirectory, in: .localDomainMask)
            + fileManager.urls(for: .applicationDirectory, in: .userDomainMask)
        return folders.contains { path.hasPrefix($0.path) }
    }

    private static func mountedInstallerVolume() -> URL? {
        let url = URL(fileURLWithPath: "/Volumes/\(installerVolumeName)")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private static func installerDiskImages() -> [URL] {
        let fileManager = FileManager.default
        let folders = [
            fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }

        return folders.flatMap { folder -> [URL] in
            guard let items = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return items.filter { url in
                let name = url.lastPathComponent.lowercased()
                return name.hasPrefix("murmur") && name.hasSuffix(".dmg")
            }
        }
    }
}
