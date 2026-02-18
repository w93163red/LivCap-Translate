//
//  TranslationSettings.swift
//  Livcap
//

import Foundation
import SwiftUI

// MARK: - Translation Provider

enum TranslationProvider: String, CaseIterable {
    case apple = "apple"
    case openai = "openai"

    var displayName: String {
        switch self {
        case .apple: return "Apple Translation"
        case .openai: return "OpenAI API"
        }
    }
}

// MARK: - Apple Translation Languages

struct AppleLanguage: Identifiable, Hashable {
    let id: String // Locale identifier (e.g. "en", "zh-Hans")
    let displayName: String

    var localeLanguage: Locale.Language {
        Locale.Language(identifier: id)
    }

    static let supported: [AppleLanguage] = [
        AppleLanguage(id: "ar", displayName: "Arabic"),
        AppleLanguage(id: "de", displayName: "German"),
        AppleLanguage(id: "en", displayName: "English"),
        AppleLanguage(id: "es", displayName: "Spanish"),
        AppleLanguage(id: "fr", displayName: "French"),
        AppleLanguage(id: "hi", displayName: "Hindi"),
        AppleLanguage(id: "id", displayName: "Indonesian"),
        AppleLanguage(id: "it", displayName: "Italian"),
        AppleLanguage(id: "ja", displayName: "Japanese"),
        AppleLanguage(id: "ko", displayName: "Korean"),
        AppleLanguage(id: "pl", displayName: "Polish"),
        AppleLanguage(id: "pt-BR", displayName: "Portuguese (Brazil)"),
        AppleLanguage(id: "ru", displayName: "Russian"),
        AppleLanguage(id: "th", displayName: "Thai"),
        AppleLanguage(id: "tr", displayName: "Turkish"),
        AppleLanguage(id: "uk", displayName: "Ukrainian"),
        AppleLanguage(id: "vi", displayName: "Vietnamese"),
        AppleLanguage(id: "zh-Hans", displayName: "Chinese (Simplified)"),
        AppleLanguage(id: "zh-Hant", displayName: "Chinese (Traditional)"),
    ]
}

final class TranslationSettings: ObservableObject {

    // MARK: - Singleton
    static let shared = TranslationSettings()

    // MARK: - AppStorage Keys
    private enum Keys {
        static let isEnabled = "translation_enabled"
        static let provider = "translation_provider"
        static let apiEndpoint = "translation_api_endpoint"
        static let apiKey = "translation_api_key"
        static let targetLanguage = "translation_target_language"
        static let model = "translation_model"
        static let maxIdleInterval = "translation_max_idle_interval"
        static let maxSyncInterval = "translation_max_sync_interval"
        static let maxVisibleSentences = "caption_max_visible_sentences"
        static let maxContextSize = "translation_max_context_size"
        static let historyOriginalFontSize = "history_original_font_size"
        static let historyTranslationFontSize = "history_translation_font_size"
        static let overlayOriginalFontSize = "overlay_original_font_size"
        static let overlayTranslationFontSize = "overlay_translation_font_size"
        static let appleSourceLanguage = "translation_apple_source_language"
        static let appleTargetLanguage = "translation_apple_target_language"
        static let minTranslationInterval = "translation_min_interval"
    }

    // MARK: - Published Properties with AppStorage
    @AppStorage(Keys.isEnabled) var isTranslationEnabled: Bool = false
    @AppStorage(Keys.apiEndpoint) var apiEndpoint: String = "https://api.openai.com/v1"
    @AppStorage(Keys.apiKey) var apiKey: String = ""
    @AppStorage(Keys.targetLanguage) var targetLanguage: String = "Chinese"
    @AppStorage(Keys.model) var model: String = "gpt-4o-mini"

    // MARK: - Provider Selection
    @AppStorage(Keys.provider) var providerRawValue: String = TranslationProvider.apple.rawValue

    var translationProvider: TranslationProvider {
        get { TranslationProvider(rawValue: providerRawValue) ?? .apple }
        set { providerRawValue = newValue.rawValue }
    }

    // MARK: - Apple Translation Settings
    @AppStorage(Keys.appleSourceLanguage) var appleSourceLanguageCode: String = "en"
    @AppStorage(Keys.appleTargetLanguage) var appleTargetLanguageCode: String = "zh-Hans"

    var appleSourceLanguage: Locale.Language {
        Locale.Language(identifier: appleSourceLanguageCode)
    }

    var appleTargetLanguage: Locale.Language {
        Locale.Language(identifier: appleTargetLanguageCode)
    }

    // MARK: - Translation Timing Settings (based on LiveCaptions-Translator)
    // MaxIdleInterval: frames of no caption change before triggering translation (default 50 * 25ms = 1.25s)
    @AppStorage(Keys.maxIdleInterval) var maxIdleInterval: Int = 50
    // MaxSyncInterval: caption changes before triggering translation even without sentence end (default 3)
    @AppStorage(Keys.maxSyncInterval) var maxSyncInterval: Int = 3

    // Minimum seconds between translation API calls (throttling for rate-limited backends like Gemini proxy)
    @AppStorage(Keys.minTranslationInterval) var minTranslationInterval: Double = 3.0

    // MARK: - Display Settings
    // Maximum number of sentences visible in caption display (paragraph mode)
    @AppStorage(Keys.maxVisibleSentences) var maxVisibleSentences: Int = 4
    // Number of recent translation pairs to include as LLM context
    @AppStorage(Keys.maxContextSize) var maxContextSize: Int = 10
    // History window font sizes
    @AppStorage(Keys.historyOriginalFontSize) var historyOriginalFontSize: Double = 14
    @AppStorage(Keys.historyTranslationFontSize) var historyTranslationFontSize: Double = 13
    // Overlay font sizes
    @AppStorage(Keys.overlayOriginalFontSize) var overlayOriginalFontSize: Double = 22
    @AppStorage(Keys.overlayTranslationFontSize) var overlayTranslationFontSize: Double = 18

    // MARK: - Predefined Languages
    static let availableLanguages: [String] = [
        "Arabic",
        "Chinese",
        "Dutch",
        "English",
        "French",
        "German",
        "Hindi",
        "Italian",
        "Japanese",
        "Korean",
        "Polish",
        "Portuguese",
        "Russian",
        "Spanish",
        "Swedish",
        "Turkish",
        "Vietnamese"
    ]

    private init() {}

    // MARK: - Validation
    var isConfigured: Bool {
        switch translationProvider {
        case .apple:
            return true // No API key needed
        case .openai:
            return !apiKey.isEmpty && !apiEndpoint.isEmpty
        }
    }
}
