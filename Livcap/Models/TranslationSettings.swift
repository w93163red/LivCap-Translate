//
//  TranslationSettings.swift
//  Livcap
//

import Foundation
import SwiftUI

final class TranslationSettings: ObservableObject {

    // MARK: - Singleton
    static let shared = TranslationSettings()

    // MARK: - AppStorage Keys
    private enum Keys {
        static let isEnabled = "translation_enabled"
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
    }

    // MARK: - Published Properties with AppStorage
    @AppStorage(Keys.isEnabled) var isTranslationEnabled: Bool = false
    @AppStorage(Keys.apiEndpoint) var apiEndpoint: String = "https://api.openai.com/v1"
    @AppStorage(Keys.apiKey) var apiKey: String = ""
    @AppStorage(Keys.targetLanguage) var targetLanguage: String = "Chinese"
    @AppStorage(Keys.model) var model: String = "gpt-4o-mini"

    // MARK: - Translation Timing Settings (based on LiveCaptions-Translator)
    // MaxIdleInterval: frames of no caption change before triggering translation (default 50 * 25ms = 1.25s)
    @AppStorage(Keys.maxIdleInterval) var maxIdleInterval: Int = 50
    // MaxSyncInterval: caption changes before triggering translation even without sentence end (default 3)
    @AppStorage(Keys.maxSyncInterval) var maxSyncInterval: Int = 3

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
        return !apiKey.isEmpty && !apiEndpoint.isEmpty
    }
}
