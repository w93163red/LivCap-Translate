//
//  AppleTranslationService.swift
//  Livcap
//
//  On-device translation using Apple's Translation framework (macOS 15.0+).
//  The TranslationSession is obtained via SwiftUI's .translationTask modifier
//  and injected into this service.
//

import Foundation
import Translation
import os.log

@MainActor
final class AppleTranslationService: ObservableObject {

    // MARK: - Singleton
    static let shared = AppleTranslationService()

    // MARK: - Properties

    /// Published configuration that drives the `.translationTask` modifier in SwiftUI.
    /// When this changes, SwiftUI creates a new TranslationSession and passes it back via `updateSession`.
    @Published var configuration: TranslationSession.Configuration?

    private var session: TranslationSession?
    private let settings = TranslationSettings.shared
    private let logger = Logger(subsystem: "com.livcap.translation", category: "AppleTranslation")

    // MARK: - Initialization

    private init() {}

    // MARK: - Session Management

    /// Called from the SwiftUI `.translationTask` action closure to inject the session.
    func updateSession(_ session: TranslationSession) {
        self.session = session
        logger.info("Translation session updated")
    }

    /// Rebuild the configuration to trigger a new session.
    /// Call this when source/target language settings change.
    func reconfigure() {
        let source = settings.appleSourceLanguage
        let target = settings.appleTargetLanguage
        logger.info("Reconfiguring: \(source.minimalIdentifier) → \(target.minimalIdentifier)")

        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: source,
                target: target
            )
        } else {
            configuration?.invalidate()
        }
    }

    // MARK: - Translation

    /// Translate text using the injected TranslationSession.
    /// Returns nil if no session is available or translation fails.
    func translate(_ text: String) async -> String? {
        guard let session = session else {
            logger.warning("No translation session available")
            return nil
        }

        do {
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            logger.error("Translation failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Language Availability

    /// Check whether the configured language pair is installed on device.
    func checkLanguageAvailability() async -> LanguageAvailability.Status? {
        let availability = LanguageAvailability()
        let source = settings.appleSourceLanguage
        let target = settings.appleTargetLanguage

        do {
            let status = try await availability.status(from: source, to: target)
            logger.info("Language availability: \(String(describing: status))")
            return status
        } catch {
            logger.error("Failed to check language availability: \(error.localizedDescription)")
            return nil
        }
    }
}
