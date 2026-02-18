//
//  MainWindowView.swift
//  Livcap
//
//  Full history viewer window for browsing all transcription entries.
//

import SwiftUI
import Translation

struct MainWindowView: View {
    @EnvironmentObject var captionViewModel: CaptionViewModel
    @ObservedObject private var settings = TranslationSettings.shared
    @ObservedObject private var debugLogStore = DebugLogStore.shared
    @ObservedObject private var appleTranslationService = AppleTranslationService.shared
    @State private var autoScrollEnabled = true
    @State private var isPinned = false
    @State private var showSettings = false
    @State private var showDebugLogs = false
    @State private var searchText = ""
    @State private var searchResults: [CaptionEntry]?
    @State private var searchTask: Task<Void, Never>?
    @State private var persistedEntries: [CaptionEntry] = []

    /// Merge persisted history with live session entries (deduped by id)
    private var historyEntries: [CaptionEntry] {
        let liveIds = Set(captionViewModel.captionHistory.map(\.id))
        let historical = persistedEntries.filter { !liveIds.contains($0.id) }
        return historical + captionViewModel.captionHistory
    }
    private var displayedEntries: [CaptionEntry] { searchResults ?? historyEntries }
    private var isSearching: Bool { !searchText.isEmpty }

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

                if showDebugLogs {
                    debugLogList
                } else {
                    historyList
                }

                Divider()

                if showDebugLogs {
                    debugStatusBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                } else {
                    statusBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
            }
            .frame(minWidth: 400)

            // Right: settings panel (toggled)
            if showSettings {
                settingsPanel
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .translationTask(appleTranslationService.configuration) { session in
            appleTranslationService.updateSession(session)
        }
        .onAppear {
            persistedEntries = captionViewModel.captionStore.fetchAll()
            if settings.translationProvider == .apple {
                appleTranslationService.reconfigure()
            }
        }
        .onChange(of: settings.appleSourceLanguageCode) {
            if settings.translationProvider == .apple {
                appleTranslationService.reconfigure()
            }
        }
        .onChange(of: settings.appleTargetLanguageCode) {
            if settings.translationProvider == .apple {
                appleTranslationService.reconfigure()
            }
        }
        .onChange(of: settings.providerRawValue) {
            if settings.translationProvider == .apple {
                appleTranslationService.reconfigure()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "Livcap - History" else { return }
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack {
                Button(action: { captionViewModel.toggleMicrophone() }) {
                    Label("Microphone", systemImage: captionViewModel.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
                }
                .help(captionViewModel.isMicrophoneEnabled ? "Disable Microphone" : "Enable Microphone")

                Button(action: { captionViewModel.toggleSystemAudio() }) {
                    Label("System Audio", systemImage: captionViewModel.isSystemAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .help(captionViewModel.isSystemAudioEnabled ? "Disable System Audio" : "Enable System Audio")

                Divider().frame(height: 16)

                Button(action: {
                    captionViewModel.clearCaptions()
                    persistedEntries = []
                }) {
                    Label("Clear History", systemImage: "trash")
                }

                Button(action: toggleOverlayWindow) {
                    Label("Toggle Overlay", systemImage: "rectangle.on.rectangle")
                }

                Spacer()

                Toggle("Auto-scroll", isOn: $autoScrollEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(isSearching)

                if DebugLogStore.isEnabled {
                    Button(action: { withAnimation { showDebugLogs.toggle() } }) {
                        Label("Logs", systemImage: "ladybug")
                    }
                    .help("Toggle Debug Logs")
                }

                Button(action: {
                    isPinned.toggle()
                    toggleMainWindowPinning()
                }) {
                    Label("Pin", systemImage: isPinned ? "pin.fill" : "pin")
                }
                .help(isPinned ? "Unpin Window" : "Pin Window on Top")

                Button(action: { withAnimation { showSettings.toggle() } }) {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Toggle Settings Panel")
            }

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search captions...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        searchResults = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(6)
            .onChange(of: searchText) {
                performSearch()
            }
        }
    }

    // MARK: - History List

    private var historyList: some View {
        ScrollViewReader { proxy in
            List {
                if isSearching && displayedEntries.isEmpty {
                    Text("No results for \"\(searchText)\"")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }

                ForEach(displayedEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            Text("[\(Self.timeFormatter.string(from: entry.timestamp))]")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)

                            Text(entry.text)
                                .font(.system(size: CGFloat(settings.historyOriginalFontSize), weight: .medium))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }

                        if let translation = entry.translation, !translation.isEmpty {
                            Text(translation)
                                .font(.system(size: CGFloat(settings.historyTranslationFontSize)))
                                .foregroundColor(.secondary)
                                .padding(.leading, 76)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                    .id(entry.id)
                }

                // Current in-progress transcription (only in live mode, not search)
                if !isSearching && !captionViewModel.currentTranscription.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            Text("[\(Self.timeFormatter.string(from: Date()))]")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)

                            Text(captionViewModel.currentTranscription + "...")
                                .font(.system(size: CGFloat(settings.historyOriginalFontSize), weight: .medium))
                                .foregroundColor(.primary.opacity(0.7))
                        }

                        if !captionViewModel.currentTranslation.isEmpty {
                            Text(captionViewModel.currentTranslation)
                                .font(.system(size: CGFloat(settings.historyTranslationFontSize)))
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
                if autoScrollEnabled && !isSearching, let lastId = historyEntries.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: captionViewModel.currentTranscription) {
                if autoScrollEnabled && !isSearching && !captionViewModel.currentTranscription.isEmpty {
                    withAnimation {
                        proxy.scrollTo("current-transcription", anchor: .bottom)
                    }
                }
            }
            .onChange(of: historyEntries.last?.translation) {
                if autoScrollEnabled && !isSearching {
                    if !captionViewModel.currentTranscription.isEmpty {
                        withAnimation {
                            proxy.scrollTo("current-transcription", anchor: .bottom)
                        }
                    } else if let lastId = historyEntries.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
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

            if isSearching {
                Text("\(displayedEntries.count) results")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                let totalStored = captionViewModel.captionStore.count()
                Text("Total: \(totalStored) sentences")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Debug Log List

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var debugLogList: some View {
        ScrollViewReader { proxy in
            List {
                if debugLogStore.entries.isEmpty {
                    Text("No logs yet. Start recording to see debug output.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }

                ForEach(debugLogStore.entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text("[\(Self.logTimeFormatter.string(from: entry.timestamp))]")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)

                        Text(entry.level.label)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(logLevelColor(entry.level))

                        Text(entry.message)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(logLevelColor(entry.level))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                    .id(entry.id)
                }
            }
            .listStyle(.plain)
            .onChange(of: debugLogStore.entries.count) {
                if autoScrollEnabled, let lastId = debugLogStore.entries.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var debugStatusBar: some View {
        HStack {
            Text("Debug Logs")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()

            Button(action: { debugLogStore.clear() }) {
                Label("Clear Logs", systemImage: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Text("\(debugLogStore.entries.count) entries")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func logLevelColor(_ level: DebugLogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
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
            }

            // API Configuration (OpenAI only)
            if settings.translationProvider == .openai {
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
            }

            // Language
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

            // Display & Context
            Section {
                Stepper("Visible Sentences: \(settings.maxVisibleSentences)",
                        value: $settings.maxVisibleSentences, in: 1...10)

                if settings.translationProvider == .openai {
                    Stepper("Context Size: \(settings.maxContextSize)",
                            value: $settings.maxContextSize, in: 1...30)
                        .disabled(!settings.isTranslationEnabled)
                }
            } header: {
                Label("Display & Context", systemImage: "text.alignleft")
            } footer: {
                if settings.translationProvider == .openai {
                    Text("Visible sentences shown on overlay. Context size sent to LLM.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Number of recent sentences shown on the overlay.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Throttling (OpenAI only)
            if settings.translationProvider == .openai {
                Section {
                    HStack {
                        Text("Min Request Interval")
                        Spacer()
                        Text("\(settings.minTranslationInterval, specifier: "%.1f")s")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $settings.minTranslationInterval, in: 0...10, step: 0.5)
                        .disabled(!settings.isTranslationEnabled)
                } header: {
                    Label("Throttling", systemImage: "gauge.with.dots.needle.33percent")
                } footer: {
                    Text("Minimum seconds between translation API calls. Increase for rate-limited backends (e.g. Gemini proxy).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Overlay Font Size
            Section {
                Stepper("Original: \(Int(settings.overlayOriginalFontSize))pt",
                        value: $settings.overlayOriginalFontSize, in: 14...36, step: 1)

                Stepper("Translation: \(Int(settings.overlayTranslationFontSize))pt",
                        value: $settings.overlayTranslationFontSize, in: 12...32, step: 1)
            } header: {
                Label("Overlay Font Size", systemImage: "textformat.size")
            }

            // History Font Size
            Section {
                Stepper("Original: \(Int(settings.historyOriginalFontSize))pt",
                        value: $settings.historyOriginalFontSize, in: 10...24, step: 1)

                Stepper("Translation: \(Int(settings.historyTranslationFontSize))pt",
                        value: $settings.historyTranslationFontSize, in: 10...24, step: 1)
            } header: {
                Label("History Font Size", systemImage: "textformat.size")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Search

    private func performSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            searchResults = nil
            return
        }
        // Debounce: 300ms delay
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let results = captionViewModel.captionStore.search(query: query)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                searchResults = results
            }
        }
    }

    // MARK: - Pin Main Window

    private func toggleMainWindowPinning() {
        guard let window = NSApp.windows.first(where: { $0.title == "Livcap - History" }) else { return }
        if isPinned {
            window.level = .floating
            window.collectionBehavior = [.fullScreenAuxiliary]
        } else {
            window.level = .normal
            window.collectionBehavior = []
        }
    }

    // MARK: - Overlay Toggle

    private func toggleOverlayWindow() {
        guard let panel = NSApp.windows.first(where: { $0 is FloatingPanel }) else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            // Position below the history window, centered horizontally
            if let historyWindow = NSApp.windows.first(where: { $0.title == "Livcap - History" }) {
                let hFrame = historyWindow.frame
                let panelWidth = max(panel.frame.width, hFrame.width * 0.8)
                let panelHeight = max(panel.frame.height, 80)
                let x = hFrame.midX - panelWidth / 2
                let y = hFrame.minY - panelHeight - 10
                panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
            }
            panel.orderFront(nil)
        }
    }
}

#Preview {
    MainWindowView()
        .environmentObject(CaptionViewModel())
        .frame(width: 700, height: 500)
}
