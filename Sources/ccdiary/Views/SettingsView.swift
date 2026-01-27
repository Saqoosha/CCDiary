import SwiftUI

struct SettingsView: View {
    @AppStorage("aiProvider") private var aiProviderRaw = AIProvider.claudeAPI.rawValue
    @AppStorage("claudeAPIModel") private var apiModel = "claude-haiku-4-5-20251101"
    @AppStorage("geminiModel") private var geminiModel = "gemini-2.5-flash"
    @AppStorage("diariesDirectory") private var diariesDirectory = ""

    @State private var claudeAPIKey = ""
    @State private var geminiAPIKey = ""
    @State private var showingSaveConfirmation = false
    @State private var saveConfirmationMessage = ""

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .claudeAPI
    }

    private let apiModels = [
        ("claude-haiku-4-5-20251101", "Haiku 4.5"),
        ("claude-sonnet-4-5-20251101", "Sonnet 4.5"),
        ("claude-opus-4-5-20251101", "Opus 4.5")
    ]

    private let geminiModels = [
        ("gemini-2.5-flash", "2.5 Flash"),
        ("gemini-2.5-pro", "2.5 Pro"),
        ("gemini-3-flash", "3 Flash")
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
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? .white : .primary)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

#Preview {
    SettingsView()
}
