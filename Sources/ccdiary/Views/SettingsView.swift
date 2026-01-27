import SwiftUI

struct SettingsView: View {
    @AppStorage("aiProvider") private var aiProviderRaw = AIProvider.claudeCLI.rawValue
    @AppStorage("claudeModel") private var cliModel = "sonnet"
    @AppStorage("claudeAPIModel") private var apiModel = "claude-sonnet-4-20250514"
    @AppStorage("geminiModel") private var geminiModel = "gemini-2.5-flash"
    @AppStorage("diariesDirectory") private var diariesDirectory = ""

    @State private var claudeAPIKey = ""
    @State private var geminiAPIKey = ""
    @State private var showingSaveConfirmation = false
    @State private var saveConfirmationMessage = ""

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .claudeCLI
    }

    private let cliModels = [
        ("sonnet", "Claude Sonnet"),
        ("opus", "Claude Opus"),
        ("haiku", "Claude Haiku")
    ]

    private let apiModels = [
        ("claude-sonnet-4-20250514", "Claude Sonnet 4"),
        ("claude-opus-4-20250514", "Claude Opus 4"),
        ("claude-3-5-haiku-20241022", "Claude 3.5 Haiku")
    ]

    private let geminiModels = [
        ("gemini-2.5-flash", "Gemini 2.5 Flash"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro"),
        ("gemini-2.0-flash", "Gemini 2.0 Flash")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Provider Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("AI Provider")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(AIProvider.allCases, id: \.rawValue) { provider in
                        ProviderButton(
                            title: provider.displayName,
                            subtitle: providerSubtitle(provider),
                            isSelected: aiProvider == provider
                        ) {
                            aiProviderRaw = provider.rawValue
                        }
                    }
                }
            }
            .padding()

            Divider()

            // Provider-specific configuration
            VStack(alignment: .leading, spacing: 12) {
                switch aiProvider {
                case .claudeCLI:
                    claudeCLIConfig
                case .claudeAPI:
                    claudeAPIConfig
                case .gemini:
                    geminiConfig
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Storage configuration
            storageConfig
                .padding()

            Spacer(minLength: 0)
        }
        .frame(width: 480, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("API Key", isPresented: $showingSaveConfirmation) {
            Button("OK") { }
        } message: {
            Text(saveConfirmationMessage)
        }
        .onAppear {
            loadAPIKeys()
        }
    }

    // MARK: - Provider Configs

    private var claudeCLIConfig: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.headline)
                .foregroundStyle(.secondary)

            Picker("", selection: $cliModel) {
                ForEach(cliModels, id: \.0) { modelId, displayName in
                    Text(displayName).tag(modelId)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Uses Claude Code CLI for generation. No API key required.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var claudeAPIConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Picker("", selection: $apiModel) {
                    ForEach(apiModels, id: \.0) { modelId, displayName in
                        Text(displayName).tag(modelId)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("API Key")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    if KeychainHelper.load(service: KeychainHelper.claudeAPIService) != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                HStack(spacing: 8) {
                    SecureField("sk-ant-...", text: $claudeAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        saveAPIKey(claudeAPIKey, service: KeychainHelper.claudeAPIService)
                    }
                    .disabled(claudeAPIKey.isEmpty)
                }

                Link("Get API key from console.anthropic.com",
                     destination: URL(string: "https://console.anthropic.com")!)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
    }

    private var geminiConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Picker("", selection: $geminiModel) {
                    ForEach(geminiModels, id: \.0) { modelId, displayName in
                        Text(displayName).tag(modelId)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("API Key")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    if KeychainHelper.load(service: KeychainHelper.geminiAPIService) != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                HStack(spacing: 8) {
                    SecureField("AI...", text: $geminiAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        saveAPIKey(geminiAPIKey, service: KeychainHelper.geminiAPIService)
                    }
                    .disabled(geminiAPIKey.isEmpty)
                }

                Link("Get API key from aistudio.google.com",
                     destination: URL(string: "https://aistudio.google.com")!)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
    }

    private var storageConfig: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Default: ./diaries", text: $diariesDirectory)
                    .textFieldStyle(.roundedBorder)

                Button("Browse") {
                    selectDirectory()
                }

                if !diariesDirectory.isEmpty {
                    Button {
                        diariesDirectory = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !diariesDirectory.isEmpty {
                Text(diariesDirectory)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Helpers

    private func providerSubtitle(_ provider: AIProvider) -> String {
        switch provider {
        case .claudeCLI: return "No API key"
        case .claudeAPI: return "Fast"
        case .gemini: return "Fastest"
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

// MARK: - Provider Button Component

struct ProviderButton: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .white : .primary)
    }
}

#Preview {
    SettingsView()
}
