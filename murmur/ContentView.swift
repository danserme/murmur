import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            HeaderBar()
            CaptureBar()
                .padding(.horizontal, LTTheme.spaceLG)
                .padding(.top, 6)
                .padding(.bottom, LTTheme.spaceMD)

            HStack(alignment: .top, spacing: 0) {
                PreviewPane(
                    title: "Transcript",
                    text: transcriptBinding,
                    placeholder: transcriptPlaceholder,
                    isBusy: workspace.phase == .transcribing || workspace.phase == .preparing,
                    progress: workspace.phase == .transcribing || workspace.phase == .preparing
                        ? workspace.jobProgress
                        : nil,
                    isEditable: workspace.phase != .transcribing && workspace.phase != .preparing,
                    primaryTitle: "Transcribe",
                    primaryEnabled: workspace.canTranscribe,
                    primaryAction: workspace.transcribeCurrentFile,
                    showsStop: workspace.phase == .transcribing || workspace.phase == .preparing,
                    copyAction: workspace.copyTranscript,
                    sourceHighlight: workspace.sourceHighlight,
                    sourceHighlightTick: workspace.sourceHighlightTick
                )
                Rectangle()
                    .fill(LTTheme.hairline)
                    .frame(width: 1)
                    .padding(.vertical, 8)
                PreviewPane(
                    title: "Summary",
                    text: summaryBinding,
                    placeholder: workspace.summaryAvailability,
                    isBusy: workspace.phase == .summarizing,
                    progress: nil,
                    isEditable: workspace.phase != .summarizing,
                    primaryTitle: "Summarize",
                    primaryEnabled: workspace.canSummarize,
                    primaryAction: workspace.summarizeTranscript,
                    showsStop: workspace.phase == .summarizing,
                    copyAction: workspace.copySummary,
                    locatesSource: true
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LTTheme.canvas)
        .tint(LTTheme.accent)
        .frame(minWidth: 920, minHeight: 640)
        .fileImporter(
            isPresented: $workspace.isFileImporterPresented,
            allowedContentTypes: workspace.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    workspace.importFile(from: url)
                }
            case .failure(let error):
                workspace.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            workspace.importFile(from: url)
            return true
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { workspace.errorMessage != nil },
                set: { if !$0 { workspace.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { workspace.errorMessage = nil }
        } message: {
            Text(workspace.errorMessage ?? "")
        }
    }

    private var transcriptBinding: Binding<String> {
        Binding(
            get: { workspace.displayedTranscript },
            set: { workspace.replaceTranscript($0) }
        )
    }

    private var summaryBinding: Binding<String> {
        Binding(
            get: { workspace.summary },
            set: { workspace.replaceSummary($0) }
        )
    }

    private var transcriptPlaceholder: String {
        if workspace.recording == nil && !workspace.capture.isRecording {
            return "Record or open a file, then transcribe it here."
        }
        return "The transcript will appear as speech is recognized on this Mac."
    }
}

private struct HeaderBar: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image("AppLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 20)
                .foregroundStyle(colorScheme == .dark ? Color.white : LTTheme.brand)
                .accessibilityLabel("murmur")

            Spacer(minLength: 8)

            AppearanceToggle()
            SettingsLink {
                Label("Settings", systemImage: "slider.horizontal.3")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LTTheme.muted)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Open settings")
        }
        .padding(.leading, 52)
        .padding(.trailing, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct CaptureBar: View {
    @Environment(Workspace.self) private var workspace
    @State private var isTargeted = false

    private var isRecording: Bool { workspace.capture.isRecording }

    var body: some View {
        HStack(spacing: 14) {
            RecordButton()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LTTheme.ink)
                        .lineLimit(1)
                    if isRecording {
                        Text(Self.format(workspace.capture.elapsed))
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(LTTheme.record)
                    }
                }
                Text(workspace.statusMessage)
                    .font(LTTheme.statusFont)
                    .foregroundStyle(LTTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !isRecording, let recording = workspace.recording {
                AudioPreview(url: recording.fileURL)
            }

            if !isRecording {
                Button {
                    workspace.isFileImporterPresented = true
                } label: {
                    Label("Open file", systemImage: "folder")
                }
                .buttonStyle(LTActionButtonStyle())
                .disabled(workspace.phase.isBusy)
                .help("Choose an audio or video file to transcribe")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(LTTheme.wash)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: LTTheme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LTTheme.radius, style: .continuous)
                .strokeBorder(
                    isRecording ? LTTheme.record.opacity(0.28) : isTargeted ? LTTheme.accent.opacity(0.28) : LTTheme.hairline,
                    lineWidth: 0.5
                )
        )
        .shadow(color: Color.black.opacity(0.04), radius: 18, y: 8)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            workspace.importFile(from: url)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .animation(.easeOut(duration: 0.18), value: isTargeted)
        .animation(.easeOut(duration: 0.18), value: isRecording)
    }

    private var title: String {
        if isRecording { return "Listening" }
        return workspace.recording?.displayName ?? "New recording"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct RecordButton: View {
    @Environment(Workspace.self) private var workspace

    private var isRecording: Bool { workspace.capture.isRecording }
    private var level: CGFloat { CGFloat(workspace.capture.level) }

    var body: some View {
        Button(action: workspace.toggleRecording) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isRecording ? LTTheme.record : LTTheme.brand)
                        .frame(width: 36, height: 36)
                        .shadow(color: (isRecording ? LTTheme.record : LTTheme.brand).opacity(0.28), radius: 8, y: 3)
                    Circle()
                        .stroke(LTTheme.record.opacity(isRecording ? 0.22 + (0.4 * level) : 0), lineWidth: 2)
                        .frame(width: 44 + (6 * level), height: 44 + (6 * level))
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: isRecording ? 11 : 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)

                Text(isRecording ? "Stop" : "Record")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isRecording ? LTTheme.record : LTTheme.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .disabled(!workspace.canRecord && !isRecording)
        .help(isRecording ? "Stop recording" : "Start recording from this Mac")
        .accessibilityLabel(isRecording ? "Stop recording" : "Record")
        .animation(.easeOut(duration: 0.08), value: workspace.capture.level)
    }
}

private struct PreviewPane: View {
    @Environment(Workspace.self) private var workspace

    let title: String
    let text: Binding<String>
    let placeholder: String
    let isBusy: Bool
    var progress: Double? = nil
    let isEditable: Bool
    let primaryTitle: String
    let primaryEnabled: Bool
    let primaryAction: () -> Void
    let showsStop: Bool
    let copyAction: () -> Void
    var locatesSource = false
    var sourceHighlight: NSRange?
    var sourceHighlightTick = 0

    @State private var streamContentHeight: CGFloat = 0
    @State private var streamViewportHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(LTTheme.labelFont)
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(LTTheme.muted)
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(LTTheme.muted)
                }
                Spacer(minLength: 8)
                if !text.wrappedValue.isEmpty {
                    Button(action: copyAction) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(LTActionButtonStyle())
                    .help("Copy \(title.lowercased()) to the clipboard")
                }
                if showsStop {
                    Button(action: workspace.stop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(LTActionButtonStyle())
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop \(title.lowercased())")
                } else {
                    Button(action: primaryAction) {
                        Label(primaryTitle, systemImage: primaryTitle == "Summarize" ? "text.alignleft" : "waveform")
                    }
                    .buttonStyle(LTActionButtonStyle(emphasized: true))
                    .disabled(!primaryEnabled)
                    .help(primaryHelp)
                    .keyboardShortcut(
                        primaryTitle == "Summarize" ? KeyEquivalent("s") : KeyEquivalent("t"),
                        modifiers: primaryTitle == "Summarize" ? [.command, .shift] : [.command]
                    )
                }
            }
            .padding(.horizontal, LTTheme.spaceLG)
            .padding(.top, 4)

            if isBusy {
                Group {
                    if let progress {
                        ProgressView(value: progress, total: 1)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .tint(LTTheme.accent)
                .padding(.horizontal, LTTheme.spaceLG)
            }

            paneBody
                .font(LTTheme.bodyFont)
                .lineSpacing(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, LTTheme.spaceLG)
                .padding(.bottom, LTTheme.spaceLG)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var primaryHelp: String {
        if primaryTitle == "Summarize" {
            return "Write a summary of the transcript"
        }
        return "Turn this recording into text"
    }

    @ViewBuilder
    private var paneBody: some View {
        if isBusy {
            streamingBody
        } else {
            editorBody
        }
    }

    private var isStreamOverflowing: Bool {
        streamViewportHeight > 0 && streamContentHeight > streamViewportHeight + 1
    }

    private var streamingBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(placeholder)
                                .foregroundStyle(LTTheme.muted.opacity(0.8))
                        } else {
                            Text(text.wrappedValue)
                                .foregroundStyle(LTTheme.ink)
                                .textSelection(.enabled)
                                .tint(LTTheme.accent)
                        }
                    }
                    .font(LTTheme.bodyFont)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    Color.clear
                        .frame(height: 1)
                        .id("stream-tail")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in
                    streamContentHeight = height
                }
            }
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(isStreamOverflowing ? .bottom : .top, for: .sizeChanges)
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in
                streamViewportHeight = height
            }
            .onChange(of: text.wrappedValue) {
                followStream(proxy)
            }
            .onChange(of: isStreamOverflowing) { _, overflowing in
                if overflowing { followStream(proxy) }
            }
        }
    }

    private func followStream(_ proxy: ScrollViewProxy) {
        guard isStreamOverflowing else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo("stream-tail", anchor: .bottom)
        }
    }

    private var editorBody: some View {
        PaneTextView(
            text: text,
            placeholder: placeholder,
            isEditable: isEditable,
            highlight: sourceHighlight,
            highlightTick: sourceHighlightTick,
            locatesSource: locatesSource,
            onRevealSource: locatesSource ? { [workspace] selection in
                workspace.revealSource(for: selection)
            } : nil,
            onSelectionCleared: locatesSource ? { [workspace] in
                workspace.clearSourceHighlight()
            } : nil
        )
    }
}

private struct LTActionButtonStyle: ButtonStyle {
    var emphasized = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 13, weight: emphasized ? .semibold : .medium))
            .foregroundStyle(foreground(configuration))
            .padding(.horizontal, 12)
            .frame(height: LTTheme.controlHeight)
            .background(background(configuration))
            .overlay(
                Capsule()
                    .strokeBorder(LTTheme.hairline, lineWidth: 0.5)
            )
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.72 : 1)
            .pointerStyle(isEnabled ? .link : .default)
    }

    private func foreground(_ configuration: Configuration) -> Color {
        if !isEnabled { return LTTheme.muted.opacity(0.5) }
        return emphasized ? LTTheme.ink : LTTheme.ink.opacity(0.78)
    }

    private func background(_ configuration: Configuration) -> Color {
        if !isEnabled { return LTTheme.wash.opacity(0.5) }
        if emphasized { return LTTheme.ink.opacity(configuration.isPressed ? 0.08 : 0.05) }
        return LTTheme.wash
    }
}
