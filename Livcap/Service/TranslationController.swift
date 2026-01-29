//
//  TranslationController.swift
//  Livcap
//
//  Translation timing controller based on mac-transcriber design.
//  Context includes both original text and translation for better LLM context.
//

import Foundation
import os.log

/// Manages translation timing and task queue
final class TranslationController {

    // MARK: - Types

    struct PendingTranslation {
        let captionId: UUID?
        let text: String
        let isRealtime: Bool
        let task: Task<Void, Never>
    }

    struct TranslationContext {
        let original: String
        var translation: String
        let captionId: UUID
    }

    // MARK: - Configuration (based on mac-transcriber)

    private let realtimeTextMinLength = 20
    private let realtimeUpdateThreshold = 3
    private let realtimeIdleThreshold: TimeInterval = 1.0

    // MARK: - Properties

    private let translationService = TranslationService.shared
    private let settings = TranslationSettings.shared
    private let logger = Logger(subsystem: "com.livcap.translation", category: "TranslationController")

    // Translation timing state
    private var lastText: String = ""
    private var updateCount: Int = 0
    private var lastUpdateTime: Date = Date()
    private var realtimeTranslationPending: Bool = false

    // Context: recent sentences with their translations (original -> translation pairs)
    private var translationContexts: [TranslationContext] = []

    // Task queue
    private var pendingTasks: [PendingTranslation] = []
    private let taskLock = NSLock()

    // Idle check timer
    private var idleCheckTask: Task<Void, Never>?

    // Callbacks
    var onTranslationComplete: (@MainActor (UUID, String) -> Void)?
    var onRealtimeTranslationComplete: (@MainActor (String) -> Void)?

    // MARK: - Initialization

    init() {
        startIdleChecker()
    }

    deinit {
        idleCheckTask?.cancel()
    }

    // MARK: - Public Methods

    @MainActor
    func onTranscriptionUpdate(currentText: String) {
        guard settings.isTranslationEnabled else { return }
        guard !currentText.isEmpty else {
            lastText = ""
            updateCount = 0
            return
        }

        let textChanged = currentText != lastText

        if textChanged {
            lastText = currentText
            lastUpdateTime = Date()
            updateCount += 1

            if currentText.count >= realtimeTextMinLength &&
               updateCount >= realtimeUpdateThreshold &&
               !realtimeTranslationPending {
                logger.info("🔄 Realtime translation triggered (update count: \(self.updateCount))")
                triggerRealtimeTranslation(text: currentText)
            }
        }
    }

    func onSentenceFinalized(text: String, captionId: UUID) {
        guard settings.isTranslationEnabled else { return }

        resetRealtimeState()

        // Build context string from recent translations
        let contextString = buildContextString()

        // Add to context (translation will be updated when complete)
        translationContexts.append(TranslationContext(original: text, translation: "", captionId: captionId))
        if translationContexts.count > settings.maxContextSize {
            translationContexts.removeFirst()
        }

        triggerFinalizedTranslation(text: text, context: contextString, captionId: captionId)
    }

    func reset() {
        lastText = ""
        updateCount = 0
        realtimeTranslationPending = false
        translationContexts.removeAll()
        cancelAllPendingTasks()
    }

    // MARK: - Private Methods

    /// Build context string in mac-transcriber format: "原文 -> 翻译"
    private func buildContextString() -> String {
        let contextLines = translationContexts.compactMap { ctx -> String? in
            guard !ctx.translation.isEmpty else { return nil }
            return "\(ctx.original) -> \(ctx.translation)"
        }

        if contextLines.isEmpty {
            return ""
        }

        return "Previous context:\n" + contextLines.joined(separator: "\n")
    }

    private func startIdleChecker() {
        idleCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)

                guard let self = self else { break }
                await MainActor.run {
                    self.checkIdleTrigger()
                }
            }
        }
    }

    @MainActor
    private func checkIdleTrigger() {
        guard settings.isTranslationEnabled else { return }
        guard !lastText.isEmpty else { return }
        guard !realtimeTranslationPending else { return }

        let idleTime = Date().timeIntervalSince(lastUpdateTime)

        if idleTime >= realtimeIdleThreshold && lastText.count >= realtimeTextMinLength {
            logger.info("🔄 Realtime translation triggered (idle: \(String(format: "%.2f", idleTime))s)")
            triggerRealtimeTranslation(text: lastText)
        }
    }

    private func resetRealtimeState() {
        lastText = ""
        updateCount = 0
        realtimeTranslationPending = false
    }

    private func triggerRealtimeTranslation(text: String) {
        realtimeTranslationPending = true
        updateCount = 0

        let contextString = buildContextString()
        logger.info("🔄 Realtime translation: \(text.prefix(50))...")

        let task = Task { [weak self] in
            guard let self = self else { return }

            if let translatedText = await self.translationService.translateText(text, context: contextString) {
                await MainActor.run {
                    self.onRealtimeTranslationComplete?(translatedText)
                }
            }

            await MainActor.run {
                self.realtimeTranslationPending = false
            }
        }

        taskLock.lock()
        pendingTasks.append(PendingTranslation(captionId: nil, text: text, isRealtime: true, task: task))
        taskLock.unlock()
    }

    private func triggerFinalizedTranslation(text: String, context: String, captionId: UUID) {
        logger.info("🔄 Finalized translation: \(text.prefix(50))... (context: \(context.count) chars)")

        let task = Task { [weak self] in
            guard let self = self else { return }

            if let translatedText = await self.translationService.translateText(text, context: context) {
                self.cancelOlderTasks(for: captionId)

                // Update translation in context
                self.updateContextTranslation(captionId: captionId, translation: translatedText)

                await MainActor.run {
                    self.onTranslationComplete?(captionId, translatedText)
                }
            }

            self.removeCompletedTask(for: captionId)
        }

        taskLock.lock()
        pendingTasks.append(PendingTranslation(captionId: captionId, text: text, isRealtime: false, task: task))
        taskLock.unlock()
    }

    private func updateContextTranslation(captionId: UUID, translation: String) {
        taskLock.lock()
        defer { taskLock.unlock() }

        if let index = translationContexts.firstIndex(where: { $0.captionId == captionId }) {
            translationContexts[index].translation = translation
        }
    }

    private func cancelOlderTasks(for captionId: UUID) {
        taskLock.lock()
        defer { taskLock.unlock() }

        let indices = pendingTasks.enumerated()
            .filter { $0.element.captionId == captionId }
            .map { $0.offset }

        if indices.count > 1 {
            for index in indices.dropLast().reversed() {
                pendingTasks[index].task.cancel()
                pendingTasks.remove(at: index)
            }
        }
    }

    private func removeCompletedTask(for captionId: UUID) {
        taskLock.lock()
        defer { taskLock.unlock() }

        pendingTasks.removeAll { $0.captionId == captionId }
    }

    private func cancelAllPendingTasks() {
        taskLock.lock()
        defer { taskLock.unlock() }

        for pending in pendingTasks {
            pending.task.cancel()
        }
        pendingTasks.removeAll()
    }
}
