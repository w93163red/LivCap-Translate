//
//  TranslationService.swift
//  Livcap
//

import Foundation
import os.log

// MARK: - Translation Error Types

enum OpenAITranslationError: Error, LocalizedError {
    case notEnabled
    case invalidConfiguration
    case networkError(Error)
    case apiError(String)
    case decodingError
    case timeout

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "Translation is not enabled"
        case .invalidConfiguration:
            return "Invalid API configuration"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let message):
            return "API error: \(message)"
        case .decodingError:
            return "Failed to decode API response"
        case .timeout:
            return "Translation request timed out"
        }
    }
}

// MARK: - OpenAI API Models

struct OpenAIChatRequest: Codable {
    let model: String
    let messages: [OpenAIChatMessage]
    let temperature: Double
    let max_tokens: Int
}

struct OpenAIChatMessage: Codable {
    let role: String
    let content: String
}

struct OpenAIChatResponse: Codable {
    let choices: [OpenAIChatChoice]
}

struct OpenAIChatChoice: Codable {
    let message: OpenAIChatMessage
}

// MARK: - TranslationService

final class TranslationService: ObservableObject {

    // MARK: - Singleton
    static let shared = TranslationService()

    // MARK: - Configuration
    private var settings: TranslationSettings { TranslationSettings.shared }

    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.livcap.translation", category: "TranslationService")
    private let urlSession: URLSession
    private let timeout: TimeInterval = 30.0

    // MARK: - Initialization

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.urlSession = URLSession(configuration: config)
        logger.info("TranslationService initialized")
    }

    // MARK: - Public Translation Methods

    /// Test translation directly, returns the translated text or throws an error
    func testTranslation(_ text: String) async throws -> String {
        guard !settings.apiKey.isEmpty, !settings.apiEndpoint.isEmpty else {
            throw OpenAITranslationError.invalidConfiguration
        }
        return try await performTranslation(text)
    }

    /// Translate text with optional context. Returns nil if translation is disabled or fails.
    func translateText(_ text: String, context: String = "") async -> String? {
        guard settings.isTranslationEnabled else {
            logger.info("Translation disabled, skipping")
            return nil
        }

        guard !settings.apiKey.isEmpty, !settings.apiEndpoint.isEmpty else {
            logger.warning("Invalid translation configuration")
            return nil
        }

        do {
            let translatedText = try await performTranslation(text, context: context)
            logger.info("Translation successful")
            return translatedText
        } catch {
            logger.error("Translation failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private Methods

    private func performTranslation(_ text: String, context: String = "") async throws -> String {
        let url = try buildURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build system prompt (mac-transcriber style)
        let systemPrompt = """
        Translate from English to \(settings.targetLanguage). Output translation only, no explanation.
        """

        // Build messages
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: systemPrompt)
        ]

        // Add context if available (format: "原文 -> 翻译")
        if !context.isEmpty {
            messages.append(OpenAIChatMessage(role: "system", content: context))
        }

        // Add current text to translate
        messages.append(OpenAIChatMessage(role: "user", content: text))

        let chatRequest = OpenAIChatRequest(
            model: settings.model,
            messages: messages,
            temperature: 0.3,
            max_tokens: 1000
        )

        request.httpBody = try JSONEncoder().encode(chatRequest)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranslationError.networkError(NSError(domain: "TranslationService", code: -1))
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenAITranslationError.apiError("Status \(httpResponse.statusCode): \(errorMessage)")
        }

        let chatResponse = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)

        guard let translatedText = chatResponse.choices.first?.message.content else {
            throw OpenAITranslationError.decodingError
        }

        return translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildURL() throws -> URL {
        var endpoint = settings.apiEndpoint

        // Handle common endpoint formats
        if !endpoint.hasSuffix("/chat/completions") && !endpoint.contains("/chat/completions") {
            if endpoint.hasSuffix("/") {
                endpoint += "chat/completions"
            } else {
                endpoint += "/chat/completions"
            }
        }

        guard let url = URL(string: endpoint) else {
            throw OpenAITranslationError.invalidConfiguration
        }

        return url
    }
}
