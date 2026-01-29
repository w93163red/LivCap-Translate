//
//  MainWindowView.swift
//  Livcap
//
//  Full history viewer window for browsing all transcription entries.
//

import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var captionViewModel: CaptionViewModel
    @ObservedObject private var settings = TranslationSettings.shared
    @State private var autoScrollEnabled = true
    @State private var showSettings = false

    private var historyEntries: [CaptionEntry] { captionViewModel.captionHistory }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HSplitView {
            // Left: history panel
            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                Divider()

                historyList

                Divider()

                statusBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            .frame(minWidth: 400)

            // Right: settings panel (toggled)
            if showSettings {
                settingsPanel
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
        .frame(minWidth: 500, minHeight: 300)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button(action: { captionViewModel.clearCaptions() }) {
                Label("Clear History", systemImage: "trash")
            }

            Button(action: toggleOverlayWindow) {
                Label("Toggle Overlay", systemImage: "rectangle.on.rectangle")
            }

            Spacer()

            Toggle("Auto-scroll", isOn: $autoScrollEnabled)
                .toggleStyle(.checkbox)

            Button(action: { withAnimation { showSettings.toggle() } }) {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Toggle Settings Panel")
        }
    }

    // MARK: - History List

    private var historyList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(historyEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            Text("[\(Self.timeFormatter.string(from: entry.timestamp))]")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)

                            Text(entry.text)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }

                        if let translation = entry.translation, !translation.isEmpty {
                            Text(translation)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding(.leading, 76)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                    .id(entry.id)
                }

                // Current in-progress transcription
                if !captionViewModel.currentTranscription.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            Text("[\(Self.timeFormatter.string(from: Date()))]")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)

                            Text(captionViewModel.currentTranscription + "...")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary.opacity(0.7))
                        }

                        if !captionViewModel.currentTranslation.isEmpty {
                            Text(captionViewModel.currentTranslation)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary.opacity(0.7))
                                .padding(.leading, 76)
                        }
                    }
                    .padding(.vertical, 4)
                    .id("current-transcription")
                }
            }
            .listStyle(.plain)
            .onChange(of: historyEntries.count) {
                if autoScrollEnabled, let lastId = historyEntries.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: captionViewModel.currentTranscription) {
                if autoScrollEnabled && !captionViewModel.currentTranscription.isEmpty {
                    withAnimation {
                        proxy.scrollTo("current-transcription", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Text("Status: \(captionViewModel.statusText)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()

            Text("Total: \(historyEntries.count) sentences")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        Form {
            // Translation Toggle
            Section {
                Toggle("Enable Translation", isOn: $settings.isTranslationEnabled)
                    .toggleStyle(.switch)
            } header: {
                Label("Translation", systemImage: "globe")
            }

            // API Configuration
            Section {
                TextField("API Endpoint", text: $settings.apiEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.isTranslationEnabled)

                SecureField("API Key", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.isTranslationEnabled)

                TextField("Model", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.isTranslationEnabled)
            } header: {
                Label("API", systemImage: "server.rack")
            }

            // Language
            Section {
                Picker("Target Language", selection: $settings.targetLanguage) {
                    ForEach(TranslationSettings.availableLanguages, id: \.self) { language in
                        Text(language).tag(language)
                    }
                }
                .disabled(!settings.isTranslationEnabled)
            } header: {
                Label("Language", systemImage: "character.bubble")
            }

            // Display & Context
            Section {
                Stepper("Visible Sentences: \(settings.maxVisibleSentences)",
                        value: $settings.maxVisibleSentences, in: 1...10)

                Stepper("Context Size: \(settings.maxContextSize)",
                        value: $settings.maxContextSize, in: 1...30)
                    .disabled(!settings.isTranslationEnabled)
            } header: {
                Label("Display & Context", systemImage: "text.alignleft")
            } footer: {
                Text("Visible sentences shown on overlay. Context size sent to LLM.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Overlay Toggle

    private func toggleOverlayWindow() {
        for window in NSApplication.shared.windows {
            // The overlay is the WindowGroup (borderless style)
            if window.styleMask.contains(.borderless) && window.title != "Livcap - History" {
                if window.isVisible {
                    window.orderOut(nil)
                } else {
                    window.makeKeyAndOrderFront(nil)
                }
                return
            }
        }
    }
}

#Preview {
    MainWindowView()
        .environmentObject(CaptionViewModel())
        .frame(width: 700, height: 500)
}
