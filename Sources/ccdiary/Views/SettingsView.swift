import SwiftUI

struct SettingsView: View {
    @AppStorage("aiProvider") private var aiProviderRaw = AIProvider.claudeCLI.rawValue
    @AppStorage("claudeModel") private var model = "sonnet"
    @AppStorage("diariesDirectory") private var diariesDirectory = ""

    @State private var claudeAPIKey = ""
    @State private var geminiAPIKey = ""
    @State private var showingSaveConfirmation = false
    @State private var saveConfirmationMessage = ""

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .claudeCLI
    }

    private let availableModels = [
        ("sonnet", "Claude Sonnet (Recommended)"),
        ("opus", "Claude Opus"),
        ("haiku", "Claude Haiku (Faster)")
    ]

    var body: some View {
        Form {
            Section {
                Picker("AI Provider", selection: $aiProviderRaw) {
                    ForEach(AIProvider.allCases, id: \.rawValue) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
            } header: {
                Text("AI Provider")
            } footer: {
                Text(providerDescription)
            }

            if aiProvider == .claudeCLI {
                Section {
                    Picker("Model", selection: $model) {
                        ForEach(availableModels, id: \.0) { modelId, displayName in
                            Text(displayName).tag(modelId)
                        }
                    }
                } header: {
                    Text("Claude Model")
                } footer: {
                    Text("Uses Claude Code CLI for generation (no API key needed)")
                }
            }

            if aiProvider == .claudeAPI {
                Section {
                    SecureField("Claude API Key", text: $claudeAPIKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Save to Keychain") {
                            saveAPIKey(claudeAPIKey, service: KeychainHelper.claudeAPIService)
                        }
                        .disabled(claudeAPIKey.isEmpty)

                        if KeychainHelper.load(service: KeychainHelper.claudeAPIService) != nil {
                            Text("✓ Saved")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Claude API Key")
                } footer: {
                    Text("Get your API key from console.anthropic.com")
                }
            }

            if aiProvider == .gemini {
                Section {
                    SecureField("Gemini API Key", text: $geminiAPIKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Save to Keychain") {
                            saveAPIKey(geminiAPIKey, service: KeychainHelper.geminiAPIService)
                        }
                        .disabled(geminiAPIKey.isEmpty)

                        if KeychainHelper.load(service: KeychainHelper.geminiAPIService) != nil {
                            Text("✓ Saved")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Gemini API Key")
                } footer: {
                    Text("Get your API key from aistudio.google.com")
                }
            }

            Section {
                HStack {
                    TextField("Diaries Folder", text: $diariesDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        selectDirectory()
                    }
                }

                if !diariesDirectory.isEmpty {
                    Button("Reset to Default") {
                        diariesDirectory = ""
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text(diariesDirectory.isEmpty
                     ? "Using default location (current directory/diaries)"
                     : "Diaries will be saved to: \(diariesDirectory)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 400)
        .navigationTitle("Settings")
        .alert("API Key", isPresented: $showingSaveConfirmation) {
            Button("OK") { }
        } message: {
            Text(saveConfirmationMessage)
        }
        .onAppear {
            loadAPIKeys()
        }
    }

    private var providerDescription: String {
        switch aiProvider {
        case .claudeCLI:
            return "Uses Claude Code CLI (slower but no API key needed)"
        case .claudeAPI:
            return "Uses Claude API directly (faster, requires API key)"
        case .gemini:
            return "Uses Gemini 2.5 Flash (fastest, requires API key)"
        }
    }

    private func loadAPIKeys() {
        if let key = KeychainHelper.load(service: KeychainHelper.claudeAPIService) {
            claudeAPIKey = key
        }
        if let key = KeychainHelper.load(service: KeychainHelper.geminiAPIService) {
            geminiAPIKey = key
        }
    }

    private func saveAPIKey(_ key: String, service: String) {
        do {
            try KeychainHelper.save(key: key, service: service)
            saveConfirmationMessage = "API key saved successfully"
        } catch {
            saveConfirmationMessage = "Failed to save: \(error.localizedDescription)"
        }
        showingSaveConfirmation = true
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select folder to store diary files"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            diariesDirectory = url.path
        }
    }
}

#Preview {
    SettingsView()
}
