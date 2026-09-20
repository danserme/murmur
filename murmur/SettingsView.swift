import SwiftUI

struct SettingsView: View {
    @Environment(Workspace.self) private var workspace
    @State private var provider = SummaryPreferences.provider
    @State private var noteStructure = SummaryPreferences.noteStructure
    @State private var drafts: [APIKeyStore.Account: String] = [:]
    @State private var saved: Set<APIKeyStore.Account> = []
    @State private var saveMessage: String?

    var body: some View {
        Form {
            Section("Appearance") {
                HStack {
                    Text("Theme")
                    Spacer()
                    AppearanceToggle()
                }
                Text("Switch between the light and dark murmur palettes.")
                    .foregroundStyle(.secondary)
            }

            Section("Summaries") {
                Picker("Write summaries", selection: $provider) {
                    ForEach(SummaryProvider.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: provider) { _, newValue in
                    SummaryPreferences.provider = newValue
                    workspace.refreshSummaryAvailability()
                }

                Text(provider.detail)
                    .foregroundStyle(.secondary)

                if provider == .onThisMac {
                    Text(onDeviceStatus)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Note structure") {
                Text("Used every time murmur writes a summary. Describe the sections, lists, and tone you want.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $noteStructure)
                    .font(.system(size: 13, weight: .regular))
                    .frame(minHeight: 150)
                    .onChange(of: noteStructure) { _, newValue in
                        SummaryPreferences.noteStructure = newValue
                    }
                Button("Restore default") {
                    noteStructure = SummaryPreferences.defaultNoteStructure
                    SummaryPreferences.noteStructure = noteStructure
                }
                .disabled(noteStructure == SummaryPreferences.defaultNoteStructure)
                .pointerStyle(.link)
            }

            Section("API keys") {
                Text("Saved on this Mac in Keychain. Used only when you select that provider.")
                    .foregroundStyle(.secondary)
                keyRow(.openAI, title: "ChatGPT", placeholder: "sk-… OpenAI key", helpURL: "https://platform.openai.com/api-keys")
                keyRow(.anthropic, title: "Claude", placeholder: "sk-ant-… Anthropic key", helpURL: "https://console.anthropic.com/settings/keys")
                keyRow(.deepseek, title: "DeepSeek", placeholder: "DeepSeek API key", helpURL: "https://platform.deepseek.com/api_keys")
                keyRow(.cursor, title: "Cursor", placeholder: "cursor_… API key", helpURL: "https://cursor.com/dashboard/api")
                if let saveMessage {
                    Text(saveMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .tint(LTTheme.accent)
        .frame(width: 560, height: 760)
        .background(LTTheme.canvas)
        .onAppear {
            provider = SummaryPreferences.provider
            noteStructure = SummaryPreferences.noteStructure
            saved = Set(APIKeyStore.Account.allCases.filter(APIKeyStore.hasKey))
            workspace.refreshSummaryAvailability()
        }
    }

    private var onDeviceStatus: String {
        if SummaryService.isOnDeviceAvailable {
            return "Apple Intelligence is available on this Mac."
        }
        return SummaryService.availabilityMessage()
    }

    @ViewBuilder
    private func keyRow(
        _ account: APIKeyStore.Account,
        title: String,
        placeholder: String,
        helpURL: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if saved.contains(account) {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
            }
            SecureField(placeholder, text: draftBinding(account))
            HStack {
                Button("Save Key") {
                    save(account)
                }
                .disabled((drafts[account] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pointerStyle(.link)
                if saved.contains(account) {
                    Button("Remove", role: .destructive) {
                        APIKeyStore.delete(account)
                        drafts[account] = ""
                        saved.remove(account)
                        workspace.refreshSummaryAvailability()
                        saveMessage = "\(title) key removed."
                    }
                    .pointerStyle(.link)
                }
                Spacer()
                Link("Get a key", destination: URL(string: helpURL)!)
                    .pointerStyle(.link)
            }
        }
        .padding(.vertical, 4)
    }

    private func draftBinding(_ account: APIKeyStore.Account) -> Binding<String> {
        Binding(
            get: { drafts[account] ?? "" },
            set: { drafts[account] = $0 }
        )
    }

    private func save(_ account: APIKeyStore.Account) {
        do {
            try APIKeyStore.save(drafts[account] ?? "", to: account)
            drafts[account] = ""
            if APIKeyStore.hasKey(account) {
                saved.insert(account)
            }
            workspace.refreshSummaryAvailability()
            saveMessage = "Saved. Choose \(title(for: account)) under Summaries to use it."
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    private func title(for account: APIKeyStore.Account) -> String {
        switch account {
        case .openAI: "ChatGPT"
        case .anthropic: "Claude"
        case .deepseek: "DeepSeek"
        case .cursor: "Cursor"
        }
    }
}
