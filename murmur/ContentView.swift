import AppKit
import SwiftUI
import Translation

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
                transcriptSide
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
                    primary: PaneAction(
                        title: "Summarize",
                        systemImage: "text.alignleft",
                        help: "Write a summary of the transcript",
                        isEnabled: workspace.canSummarize,
                        shortcut: KeyboardShortcut("s", modifiers: [.command, .shift]),
                        perform: workspace.summarizeTranscript
                    ),
                    showsStop: workspace.phase == .summarizing,
                    copyAction: workspace.copySummary,
                    locatesSource: true
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LTTheme.canvas)
        .tint(LTTheme.accent)
        .frame(minWidth: 1040, minHeight: 640)
        .translationTask(workspace.translationConfiguration) { session in
            await workspace.translate(using: session)
        }
        .task {
            await workspace.loadLanguages()
        }
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

    private var isTranscribing: Bool {
        workspace.phase == .transcribing || workspace.phase == .preparing
    }

    private var transcriptTabs: Binding<Workspace.TranscriptTab>? {
        guard workspace.showsTranslationTab else { return nil }
        return Binding(
            get: { workspace.transcriptTab },
            set: { workspace.transcriptTab = $0 }
        )
    }

    private var translateAction: PaneAction {
        PaneAction(
            title: "Translate",
            systemImage: "translate",
            help: "Translate the transcript to English on this Mac",
            isEnabled: workspace.canTranslate,
            shortcut: KeyboardShortcut("t", modifiers: [.command, .shift]),
            perform: workspace.requestTranslation
        )
    }

    @ViewBuilder
    private var transcriptSide: some View {
        if workspace.showsTranslationTab && workspace.transcriptTab == .translation {
            PreviewPane(
                title: "Translation",
                tabs: transcriptTabs,
                text: translationBinding,
                placeholder: "Press Translate to get an English version of the transcript.",
                isBusy: workspace.isTranslating,
                progress: workspace.translationProgress,
                isEditable: !workspace.isTranslating,
                primary: translateAction,
                showsStop: workspace.isTranslating,
                copyAction: workspace.copyTranslation
            )
        } else {
            PreviewPane(
                title: "Transcript",
                tabs: transcriptTabs,
                text: transcriptBinding,
                placeholder: transcriptPlaceholder,
                isBusy: isTranscribing,
                progress: isTranscribing ? workspace.jobProgress : nil,
                isEditable: !isTranscribing,
                primary: PaneAction(
                    title: "Transcribe",
                    systemImage: "waveform",
                    help: "Turn this recording into text",
                    isEnabled: workspace.canTranscribe,
                    shortcut: KeyboardShortcut("t", modifiers: .command),
                    perform: workspace.transcribeCurrentFile
                ),
                secondary: workspace.needsTranslation ? translateAction : nil,
                showsStop: isTranscribing,
                copyAction: workspace.copyTranscript,
                sourceHighlight: workspace.sourceHighlight,
                sourceHighlightTick: workspace.sourceHighlightTick
            )
        }
    }

    private var translationBinding: Binding<String> {
        Binding(
            get: { workspace.translation },
            set: { workspace.replaceTranslation($0) }
        )
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
            return "Record or open a file to transcribe it here, or type or paste text."
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
                    .truncationMode(.tail)
                    .help(workspace.statusMessage)
            }
            .frame(minWidth: 120, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 8)

            if !isRecording, let recording = workspace.recording {
                AudioPreview(url: recording.fileURL)
                Rectangle()
                    .fill(LTTheme.hairline)
                    .frame(width: 1, height: 22)
            }

            LanguagePicker()
                .layoutPriority(2)

            if !isRecording {
                Button {
                    workspace.isFileImporterPresented = true
                } label: {
                    Label("Open file", systemImage: "folder")
                }
                .buttonStyle(LTActionButtonStyle())
                .fixedSize()
                .layoutPriority(2)
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

private struct LanguagePicker: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Menu {
            Picker("Spoken language", selection: selection) {
                ForEach(workspace.availableLanguages, id: \.identifier) { locale in
                    Text(TranscriptionLanguage.title(for: locale)).tag(locale.identifier)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(workspace.languageTitle, systemImage: "globe")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(LTActionButtonStyle())
        .fixedSize()
        .disabled(!workspace.canChangeLanguage || workspace.availableLanguages.isEmpty)
        .help("Language spoken in the recording")
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                workspace.availableLanguages
                    .first { TranscriptionLanguage.matches($0, workspace.transcriptionLocale) }?
                    .identifier ?? workspace.transcriptionLocale.identifier
            },
            set: { identifier in
                if let locale = workspace.availableLanguages.first(where: { $0.identifier == identifier }) {
                    workspace.setLanguage(locale)
                }
            }
        )
    }
}

private struct PaneAction {
    let title: String
    let systemImage: String
    let help: String
    let isEnabled: Bool
    let shortcut: KeyboardShortcut
    let perform: () -> Void
}

private struct PreviewPane: View {
    @Environment(Workspace.self) private var workspace

    let title: String
    var tabs: Binding<Workspace.TranscriptTab>? = nil
    let text: Binding<String>
    let placeholder: String
    let isBusy: Bool
    var progress: Double? = nil
    let isEditable: Bool
    let primary: PaneAction
    var secondary: PaneAction? = nil
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
                if let tabs {
                    PaneTabs(selection: tabs)
                } else {
                    PaneLabel(title: title, isSelected: false)
                }
                if isBusy && tabs == nil {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(LTTheme.muted)
                }
                Spacer(minLength: 8)
                if !text.wrappedValue.isEmpty {
                    CopyButton(subject: title.lowercased(), action: copyAction)
                }
                if showsStop {
                    Button(action: workspace.stop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(LTActionButtonStyle())
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop \(title.lowercased())")
                } else {
                    if let secondary {
                        Button(action: secondary.perform) {
                            Label(secondary.title, systemImage: secondary.systemImage)
                        }
                        .buttonStyle(LTIconButtonStyle())
                        .disabled(!secondary.isEnabled)
                        .help(secondary.help)
                        .keyboardShortcut(secondary.shortcut)
                    }
                    actionButton(primary, emphasized: true)
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

    private func actionButton(_ action: PaneAction, emphasized: Bool) -> some View {
        Button(action: action.perform) {
            Label(action.title, systemImage: action.systemImage)
        }
        .buttonStyle(LTActionButtonStyle(emphasized: emphasized))
        .disabled(!action.isEnabled)
        .help(action.help)
        .keyboardShortcut(action.shortcut)
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

/// Icon-only copy control that briefly turns into a "Copied" confirmation.
private struct CopyButton: View {
    let subject: String
    let action: () -> Void

    @State private var showsConfirmation = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            if showsConfirmation {
                Text("Copied")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LTTheme.accent)
                    .transition(.opacity.combined(with: .offset(x: 6)))
            }
            Button {
                action()
                confirm()
            } label: {
                Label(
                    showsConfirmation ? "Copied" : "Copy",
                    systemImage: showsConfirmation ? "checkmark" : "doc.on.doc"
                )
                .foregroundStyle(showsConfirmation ? LTTheme.accent : LTTheme.ink.opacity(0.78))
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(LTIconButtonStyle())
            .help("Copy \(subject) to the clipboard")
        }
        .animation(.easeOut(duration: 0.18), value: showsConfirmation)
        .onDisappear { resetTask?.cancel() }
    }

    private func confirm() {
        showsConfirmation = true
        AccessibilityNotification.Announcement("Copied \(subject)").post()
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            showsConfirmation = false
        }
    }
}

private struct PaneLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(LTTheme.labelFont)
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(isSelected ? LTTheme.ink : LTTheme.muted)
    }
}

private struct PaneTabs: View {
    @Binding var selection: Workspace.TranscriptTab

    var body: some View {
        HStack(spacing: 14) {
            tab("Transcript", .transcript)
            tab("Translation", .translation)
        }
    }

    private func tab(_ title: String, _ value: Workspace.TranscriptTab) -> some View {
        Button {
            selection = value
        } label: {
            PaneLabel(title: title, isSelected: selection == value)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(LTTheme.accent)
                        .frame(height: 1.5)
                        .opacity(selection == value ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Show the \(title.lowercased())")
        .animation(.easeOut(duration: 0.15), value: selection)
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
