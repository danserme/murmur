import SwiftUI

@main
struct MurmurApp: App {
    @State private var workspace = Workspace()
    @State private var installerPrompt: InstallerCleanup.Prompt?
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.light.rawValue

    private var appearance: AppAppearance {
        AppAppearance.resolved(from: appearanceRaw)
    }

    var body: some Scene {
        Window("murmur", id: "main") {
            ContentView()
                .environment(workspace)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    installerPrompt = InstallerCleanup.promptIfNeeded()
                }
                .alert(
                    "Delete the installer?",
                    isPresented: Binding(
                        get: { installerPrompt != nil },
                        set: { if !$0 { installerPrompt = nil; InstallerCleanup.markHandled() } }
                    )
                ) {
                    Button("Move to Trash") {
                        let prompt = installerPrompt
                        installerPrompt = nil
                        Task { await InstallerCleanup.cleanup(prompt) }
                    }
                    Button("Keep File", role: .cancel) {
                        installerPrompt = nil
                        InstallerCleanup.markHandled()
                    }
                } message: {
                    Text("murmur is in Applications. Move the disk image to the Trash so it doesn’t stay in Downloads.")
                }
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Recording…") {
                    workspace.isFileImporterPresented = true
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(workspace.capture.isRecording || workspace.phase.isBusy)

                Button(workspace.capture.isRecording ? "Stop Recording" : "Record") {
                    workspace.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!workspace.canRecord && !workspace.capture.isRecording)
            }

            CommandGroup(after: .newItem) {
                Button("Transcribe") {
                    workspace.transcribeCurrentFile()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!workspace.canTranscribe)

                Button("Summarize") {
                    workspace.summarizeTranscript()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!workspace.canSummarize)

                Button("Translate to English") {
                    workspace.requestTranslation()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!workspace.canTranslate)

                Button("Stop") {
                    workspace.stop()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!workspace.canStop)
            }
        }

        Settings {
            SettingsView()
                .environment(workspace)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
