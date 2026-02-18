//
//  SettingsView.swift
//  Livcap
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = TranslationSettings.shared
    @State private var showAPIKey = false
    @State private var testingConnection = false
    @State private var connectionTestResult: String?

    var body: some View {
        Form {
            // Translation Toggle Section
            Section {
                Toggle("Enable Translation", isOn: $settings.isTranslationEnabled)
                    .toggleStyle(.switch)
            } header: {
                Label("Translation", systemImage: "globe")
            } footer: {
                Text("Translate finalized captions in real time")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Provider Selection
            Section {
                Picker("Provider", selection: $settings.providerRawValue) {
                    ForEach(TranslationProvider.allCases, id: \.rawValue) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.isTranslationEnabled)
            } header: {
                Label("Provider", systemImage: "arrow.triangle.swap")
            } footer: {
                if settings.translationProvider == .apple {
                    Text("On-device translation using Apple's Translation framework. No API key or network required.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Cloud translation using an OpenAI-compatible API. Requires an API key.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // API Configuration Section (OpenAI only)
            if settings.translationProvider == .openai {
                Section {
                    TextField("API Endpoint", text: $settings.apiEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!settings.isTranslationEnabled)

                    HStack {
                        if showAPIKey {
                            TextField("API Key", text: $settings.apiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key", text: $settings.apiKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button(action: { showAPIKey.toggle() }) {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .disabled(!settings.isTranslationEnabled)

                    TextField("Model", text: $settings.model)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!settings.isTranslationEnabled)

                } header: {
                    Label("API Configuration", systemImage: "server.rack")
                } footer: {
                    Text("Supports OpenAI-compatible APIs. Enter any model name (e.g., gpt-4o, claude-3-5-sonnet, deepseek-chat)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Language Selection Section
            Section {
                if settings.translationProvider == .apple {
                    Picker("Source Language", selection: $settings.appleSourceLanguageCode) {
                        ForEach(AppleLanguage.supported) { lang in
                            Text(lang.displayName).tag(lang.id)
                        }
                    }
                    .disabled(!settings.isTranslationEnabled)

                    Picker("Target Language", selection: $settings.appleTargetLanguageCode) {
                        ForEach(AppleLanguage.supported) { lang in
                            Text(lang.displayName).tag(lang.id)
                        }
                    }
                    .disabled(!settings.isTranslationEnabled)
                } else {
                    Picker("Target Language", selection: $settings.targetLanguage) {
                        ForEach(TranslationSettings.availableLanguages, id: \.self) { language in
                            Text(language).tag(language)
                        }
                    }
                    .disabled(!settings.isTranslationEnabled)
                }
            } header: {
                Label("Language", systemImage: "character.bubble")
            }

            // Caption Display Settings
            Section {
                Stepper("Visible Sentences: \(settings.maxVisibleSentences)", value: $settings.maxVisibleSentences, in: 1...10)

                if settings.translationProvider == .openai {
                    Stepper("Context Size: \(settings.maxContextSize)", value: $settings.maxContextSize, in: 1...30)
                        .disabled(!settings.isTranslationEnabled)
                }
            } header: {
                Label("Display & Context", systemImage: "text.alignleft")
            } footer: {
                if settings.translationProvider == .openai {
                    Text("Visible sentences: number of recent sentences shown on screen. Context size: number of translated pairs sent to the LLM for better accuracy.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Number of recent sentences shown on the overlay.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Test Connection Section (OpenAI only)
            if settings.translationProvider == .openai {
                Section {
                    Button(action: testConnection) {
                        HStack {
                            if testingConnection {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text(testingConnection ? "Testing..." : "Test Connection")
                        }
                    }
                    .disabled(!settings.isTranslationEnabled || !settings.isConfigured || testingConnection)

                    if let result = connectionTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.contains("Success") ? .green : .red)
                    }
                } header: {
                    Label("Connection Test", systemImage: "network")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 620)
    }

    private func testConnection() {
        testingConnection = true
        connectionTestResult = nil

        Task {
            do {
                let result = try await TranslationService.shared.testTranslation("Hello")
                await MainActor.run {
                    connectionTestResult = "Success! Response: \(result.prefix(50))..."
                    testingConnection = false
                }
            } catch {
                await MainActor.run {
                    connectionTestResult = "Failed: \(error.localizedDescription)"
                    testingConnection = false
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
