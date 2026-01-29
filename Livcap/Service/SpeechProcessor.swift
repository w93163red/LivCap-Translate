import Foundation
import Combine
import os.log

final class SpeechProcessor: ObservableObject {

    // MARK: - Published Properties
    @Published private(set) var currentSpeechState: Bool = false
    @Published private(set) var currentTranslation: String = ""  // Realtime translation for current transcription

    // Forwarded from SpeechRecognitionManager
    var captionHistory: [CaptionEntry] { speechRecognitionManager.captionHistory }
    var currentTranscription: String { speechRecognitionManager.currentTranscription }

    // MARK: - Private Properties
    private let speechRecognitionManager = SpeechRecognitionManager()
    private let translationController = TranslationController()
    private var speechEventsTask: Task<Void, Never>?

    // Logging
    private let logger = Logger(subsystem: "com.livcap.audio", category: "SpeechProcessor")

    // MARK: - Initialization
    init() {
        setupTranslationController()
        startListeningToSpeechEvents()
    }

    deinit {
        speechEventsTask?.cancel()
    }

    // MARK: - Private Setup

    private func setupTranslationController() {
        // Called when finalized translation completes - update the caption entry
        translationController.onTranslationComplete = { [weak self] captionId, translatedText in
            guard let self = self else { return }
            self.speechRecognitionManager.updateTranslation(for: captionId, translation: translatedText)
            // Clear realtime translation since sentence is now finalized
            self.currentTranslation = ""
            self.objectWillChange.send()
            self.logger.info("🌐 Finalized translation received for caption \(captionId)")
        }

        // Called when realtime translation completes - update current translation display
        translationController.onRealtimeTranslationComplete = { [weak self] translatedText in
            guard let self = self else { return }
            self.currentTranslation = translatedText
            self.objectWillChange.send()
            self.logger.info("🌐 Realtime translation: \(translatedText.prefix(50))...")
        }
    }

    private func startListeningToSpeechEvents() {
        speechEventsTask = Task {
            let speechEvents = speechRecognitionManager.speechEvents()

            for await event in speechEvents {
                await handleSpeechEvent(event)
            }
        }
    }

    @MainActor
    private func handleSpeechEvent(_ event: SpeechEvent) {
        switch event {
        case .transcriptionUpdate(let text):
            // Trigger UI update for new transcription
            objectWillChange.send()

            // Track transcription for translation timing (sync/idle triggers)
            translationController.onTranscriptionUpdate(currentText: text)

        case .sentenceFinalized(let captionId, let sentence):
            // Trigger UI update for finalized sentence
            objectWillChange.send()
            logger.info("📝 FINALIZED SENTENCE: \(sentence)")

            // Trigger translation via controller (handles timing and task queue)
            translationController.onSentenceFinalized(text: sentence, captionId: captionId)

        case .statusChanged(let status):
            // Could publish status changes to UI if needed
            logger.info("📊 STATUS CHANGED: \(status)")

        case .error(let error):
            logger.error("❌ SPEECH RECOGNITION ERROR: \(error.localizedDescription)")
        }
    }

    // MARK: - Public Control

    func startProcessing() {
        Task {
            do {
                try await speechRecognitionManager.startRecording()
                logger.info("🎙️ SpeechProcessor processing started.")
            } catch {
                logger.error("❌ Failed to start speech processing: \(error.localizedDescription)")
            }
        }
    }

    func stopProcessing() {
        speechRecognitionManager.stopRecording()
        translationController.reset()
        logger.info("🛑 SpeechProcessor processing stopped.")
    }
    
    func processAudioFrame(_ audioFrame: AudioFrameWithVAD) {
        speechRecognitionManager.appendAudioBufferWithVAD(audioFrame)
        handleSpeechStateTransition(audioFrame)
    }

    // MARK: - Private Logic
    
    private func handleSpeechStateTransition(_ audioFrame: AudioFrameWithVAD) {
        let isSpeech = audioFrame.isSpeech
        
        // Detect speech state transitions
        if isSpeech != currentSpeechState {
            Task { @MainActor in
                self.currentSpeechState = isSpeech
            }
        }
    }
    
    func clearCaptions() {
        speechRecognitionManager.clearCaptions()
        logger.info("🗑️ CLEARED ALL CAPTIONS")
    }
}
