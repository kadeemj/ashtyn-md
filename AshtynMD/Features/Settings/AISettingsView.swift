import SwiftUI

struct AISettingsView: View {
    private var settings = AISettings.shared

    @State private var apiKeyDraft = ""
    @State private var customModelDraft = ""
    @State private var discoveredModels: [AIModel] = []
    @State private var isDiscovering = false
    @State private var connectionStatus: String?
    @State private var pendingConsentProvider: AIProviderID?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Provider", selection: providerBinding) {
                    Text("None").tag(AIProviderID?.none)
                    Divider()
                    ForEach(AIProviderID.allCases) { provider in
                        Text(provider.displayName).tag(AIProviderID?.some(provider))
                    }
                }
                Toggle("Automatic Inline Completion", isOn: $settings.automaticCompletionEnabled)
                    .disabled(settings.selectedProvider == nil)
                    .help("Suggest completions after 800 ms of typing inactivity. Manual completion is always available with ⌃⌥Space.")
            } footer: {
                Text("Suggestions appear as ghost text. Tab accepts, Escape dismisses. Nothing is inserted automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let provider = settings.selectedProvider {
                providerSection(provider)
                modelSection(provider)

                Section {
                    HStack {
                        Button("Test Connection") { testConnection(provider) }
                        if let connectionStatus {
                            Text(connectionStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadDrafts() }
        .onChange(of: settings.selectedProvider) { loadDrafts() }
        .alert(
            "Send file contents to \(pendingConsentProvider?.displayName ?? "")?",
            isPresented: consentAlertBinding
        ) {
            Button("Allow") {
                if let provider = pendingConsentProvider {
                    settings.grantConsent(for: provider)
                    settings.selectedProvider = provider
                }
                pendingConsentProvider = nil
            }
            Button("Cancel", role: .cancel) { pendingConsentProvider = nil }
        } message: {
            Text("When you request a completion, the text around your cursor in the current file (up to about 28,000 characters) is sent to \(pendingConsentProvider?.displayName ?? "the provider"). No other files, folder names, or search data are ever included.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func providerSection(_ provider: AIProviderID) -> some View {
        Section("\(provider.displayName) Configuration") {
            if provider.isCloud {
                SecureField("API Key", text: $apiKeyDraft)
                    .textContentType(.password)
                HStack {
                    Button("Save Key") {
                        try? CredentialStore.setSecret(apiKeyDraft, for: provider)
                        connectionStatus = "Key saved to Keychain."
                    }
                    .disabled(apiKeyDraft.isEmpty)
                    Button("Remove Key") {
                        try? CredentialStore.setSecret(nil, for: provider)
                        apiKeyDraft = ""
                        connectionStatus = "Key removed."
                    }
                    Spacer()
                    if CredentialStore.hasSecret(for: provider) {
                        Label("Stored in Keychain", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                TextField("Server URL", text: Bindable(settings).ollamaBaseURLString, prompt: Text("http://127.0.0.1:11434"))
            }
        }
    }

    @ViewBuilder
    private func modelSection(_ provider: AIProviderID) -> some View {
        Section("Model") {
            HStack {
                Picker("Discovered Models", selection: modelBinding(provider)) {
                    Text("None").tag("")
                    ForEach(discoveredModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                    let current = settings.model(for: provider)
                    if !current.isEmpty && !discoveredModels.contains(where: { $0.id == current }) {
                        Text(current).tag(current)
                    }
                }
                Button {
                    discoverModels(provider)
                } label: {
                    if isDiscovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .help("Fetch the provider’s model list")
            }
            HStack {
                TextField("Custom Model ID", text: $customModelDraft, prompt: Text("e.g. a fine-tuned or unlisted model"))
                Button("Use") {
                    settings.setModel(customModelDraft.trimmingCharacters(in: .whitespaces), for: provider)
                }
                .disabled(customModelDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Bindings and actions

    /// Selecting a cloud provider routes through the one-time disclosure.
    private var providerBinding: Binding<AIProviderID?> {
        Binding(
            get: { settings.selectedProvider },
            set: { newValue in
                if let provider = newValue, provider.isCloud, !settings.hasConsent(for: provider) {
                    pendingConsentProvider = provider
                } else {
                    settings.selectedProvider = newValue
                }
            }
        )
    }

    private var consentAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingConsentProvider != nil },
            set: { if !$0 { pendingConsentProvider = nil } }
        )
    }

    private func modelBinding(_ provider: AIProviderID) -> Binding<String> {
        Binding(
            get: { settings.model(for: provider) },
            set: { settings.setModel($0, for: provider) }
        )
    }

    private func loadDrafts() {
        guard let provider = settings.selectedProvider else { return }
        apiKeyDraft = (try? CredentialStore.secret(for: provider)).flatMap { $0 } ?? ""
        customModelDraft = ""
        discoveredModels = []
        connectionStatus = nil
    }

    private func discoverModels(_ providerID: AIProviderID) {
        guard let provider = settings.makeProvider(providerID) else {
            connectionStatus = "Configure the provider first."
            return
        }
        isDiscovering = true
        Task {
            defer { isDiscovering = false }
            do {
                discoveredModels = try await provider.availableModels()
                connectionStatus = "Found \(discoveredModels.count) models."
            } catch {
                connectionStatus = error.localizedDescription
            }
        }
    }

    private func testConnection(_ providerID: AIProviderID) {
        guard let provider = settings.makeProvider(providerID) else {
            connectionStatus = "Configure the provider first."
            return
        }
        connectionStatus = "Testing…"
        Task {
            do {
                try await provider.validateConfiguration()
                connectionStatus = "Connection OK."
            } catch {
                connectionStatus = error.localizedDescription
            }
        }
    }
}
