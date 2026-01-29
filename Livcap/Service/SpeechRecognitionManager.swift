//
//  SpeechRecognitionManager.swift
//  Livcap
//
//  Created by Rongwei Ji on 6/24/25.
//

import Foundation
import Speech
import AVFoundation
import Combine
import os.log

// MARK: - Speech Events

enum SpeechEvent: Sendable {
    case transcriptionUpdate(String)
    case sentenceFinalized(captionId: UUID, sentence: String)
    case statusChanged(String)
    case error(Error)
}

// MARK: - SpeechRecognitionManager

final class SpeechRecognitionManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var isRecording = false
    @Published var currentTranscription: String = ""
    @Published var captionHistory: [CaptionEntry] = []
    @Published var statusText: String = "Ready to record"
    
    // MARK: - Private Properties
    
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    
    // Text processing state
    private var processedTextLength: Int = 0
    private var fullTranscriptionText: String = ""

    // Frame-based silence detection
    private var consecutiveSilenceFrames: Int = 0
    private let silenceFrameThreshold: Int = 10  // ~2 seconds (20 frames × 100ms)
    private var currentSpeechState: Bool = false

    // Sentence boundary detection
    private let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？"]

    // AsyncStream for events
    private var speechEventsContinuation: AsyncStream<SpeechEvent>.Continuation?
    private var speechEventsStream: AsyncStream<SpeechEvent>?
    
    // Logging
    private var isLoggerOn: Bool = false // change to true for debugging
    private let logger = Logger(subsystem: "com.livcap.speech", category: "SpeechRecognitionManager")

    // Session rotation
    private var sessionStartTime: Date?
    private var sessionRotationTask: Task<Void, Never>?
    private let maxTaskDuration: TimeInterval = 300 // seconds (5 minutes)
    
    // MARK: - Initialization
    
    init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        setupSpeechRecognition()
    }
    
    deinit {
        stopRecording()
        speechEventsContinuation?.finish()
    }
    
    // MARK: - AsyncStream Interface
    
    func speechEvents() -> AsyncStream<SpeechEvent> {
        if let stream = speechEventsStream {
            return stream
        }
        
        speechEventsStream = AsyncStream { continuation in
            self.speechEventsContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.logger.info("🛑 Speech events stream terminated")
            }
        }
        
        return speechEventsStream!
    }
    
    // MARK: - Setup
    
    private func setupSpeechRecognition() {
        // Request authorization
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            guard let self = self else { return }
            
            Task { @MainActor in
                let status: String
                switch authStatus {
                case .authorized:
                    status = "Ready to record"
                case .denied:
                    status = "Speech recognition permission denied"
                case .restricted:
                    status = "Speech recognition restricted"
                case .notDetermined:
                    status = "Speech recognition not determined"
                @unknown default:
                    status = "Speech recognition authorization unknown"
                }
                
                self.statusText = status
                self.speechEventsContinuation?.yield(.statusChanged(status))
            }
        }
    }
    
    // MARK: - Public Interface
    
    func startRecording() async throws {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            let error = SpeechRecognitionError.recognizerNotAvailable
            await updateStatus("Speech recognizer not available")
            speechEventsContinuation?.yield(.error(error))
            throw error
        }
        
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            let error = SpeechRecognitionError.notAuthorized
            await updateStatus("Speech recognition not authorized")
            speechEventsContinuation?.yield(.error(error))
            throw error
        }
        
        logger.info("🔴 STARTING SPEECH RECOGNITION ENGINE")
        
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Create initial recognition session
        try await MainActor.run {
            self.startNewSession()
        }
        
        await MainActor.run {
            self.isRecording = true
            self.currentTranscription = ""
        }
        
        // Reset state
        processedTextLength = 0
        fullTranscriptionText = ""
        currentSpeechState = false
        consecutiveSilenceFrames = 0

        // Start session rotation watchdog
        startRotationWatchdog()
        
        logger.info("✅ SPEECH RECOGNITION ENGINE STARTED")
    }
    
    func stopRecording() {
        logger.info("⏹️ STOPPING SPEECH RECOGNITION ENGINE")
        
        guard isRecording else { return }
        
        // Cancel recognition task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // End recognition request
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        // Stop rotation timer
        sessionRotationTask?.cancel()
        sessionRotationTask = nil
        sessionStartTime = nil
        Task { @MainActor in
            self.isRecording = false

            // Add final transcription to history if not empty
            if !self.currentTranscription.isEmpty {
                let entryId = self.addToHistory(self.currentTranscription)
                self.speechEventsContinuation?.yield(.sentenceFinalized(captionId: entryId, sentence: self.currentTranscription))
                self.currentTranscription = ""
            }
        }
        
        // Reset state
        processedTextLength = 0
        fullTranscriptionText = ""
        consecutiveSilenceFrames = 0

        logger.info("✅ SPEECH RECOGNITION ENGINE STOPPED")
    }
    
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.append(buffer)
    }

    func appendAudioBufferWithVAD(_ audioFrame: AudioFrameWithVAD) {
        guard isRecording, let recognitionRequest = recognitionRequest else { return }

        // Log frame info before appending buffer
        if isLoggerOn {
            
            let sourceString = audioFrame.source.rawValue.uppercased()
            let vadValue = audioFrame.vadResult.rmsEnergy
            let isSpeechString = audioFrame.isSpeech ? "SPEECH" : "SILENCE"
            logger.info("(\(sourceString) Frame \(audioFrame.frameIndex) - VAD RMS: \(vadValue), State: \(isSpeechString)")
        }
        recognitionRequest.append(audioFrame.buffer)
        
        // Frame-based silence detection
        if audioFrame.isSpeech {
            consecutiveSilenceFrames = 0
            onSpeechStart()
        } else {
            consecutiveSilenceFrames += 1
            
            if consecutiveSilenceFrames == 1 {
                onSpeechEnd()
            } else if consecutiveSilenceFrames == silenceFrameThreshold {
                // 2 seconds of silence - finalize current sentence
                if !currentTranscription.isEmpty {
                    logger.info("⏰ 2s SILENCE - Creating new caption line")
                    Task { @MainActor in
                        self.finalizeSentence()
                    }
                }
                consecutiveSilenceFrames = 0  // Reset counter
            }
        }
    }
    
    func onSpeechStart() {
        currentSpeechState = true
    }

    func onSpeechEnd() {
        currentSpeechState = false
    }

    // MARK: - Private Methods
    
    @MainActor
    private func updateStatus(_ status: String) {
        statusText = status
        speechEventsContinuation?.yield(.statusChanged(status))
    }
    
    @MainActor
    private func processTranscriptionResult(_ transcription: String) {
        // Store the full transcription from SFSpeechRecognizer
        let previousFullLength = fullTranscriptionText.count
        fullTranscriptionText = transcription

        // Extract only the NEW part that hasn't been processed yet
        let newPart = extractNewTranscriptionPart(from: transcription)
        currentTranscription = newPart

        // DEBUG: Log every Apple callback to trace punctuation and offset issues
        logger.info("🔍 [DEBUG] fullText(\(transcription.count))=\"\(transcription)\" | offset=\(self.processedTextLength) | newPart=\"\(newPart)\" | prevLen=\(previousFullLength)")

        // Notify via AsyncStream
        speechEventsContinuation?.yield(.transcriptionUpdate(newPart))

        // Reset silence counter if new text was added during silence
        if transcription.count > previousFullLength && !currentSpeechState {
            consecutiveSilenceFrames = 0
        }

        // Finalize complete sentences: split at the last stable sentence boundary
        // A boundary is "stable" when sentence-ending punctuation is followed by more text,
        // meaning SFSpeechRecognizer has moved past it and won't revise it
        finalizeCompleteSentences()
    }
    
    // MARK: - Session Management (Concise)
    
    @MainActor
    private func startNewSession() {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            logger.error("❌ Cannot start session: recognizer unavailable")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        recognitionRequest = request
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            Task {
                if let error = error {
                    await self.updateStatus("Recognition error: \(error.localizedDescription)")
                    self.speechEventsContinuation?.yield(.error(error))
                    return
                }
                if let result = result {
                    let transcription = result.bestTranscription.formattedString
                    await self.processTranscriptionResult(transcription)
                }
            }
        }
        sessionStartTime = Date()
        logger.info("♻️ Session started")
    }
    
    @MainActor
    private func stopCurrentSession() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        sessionStartTime = nil
    }
    
    private func rotateSession(reason: String, finalizeCurrent: Bool) {
        Task { @MainActor in
            guard self.isRecording else { return }
            self.logger.info("♻️ Rotate session (reason=\(reason))")
            if finalizeCurrent { self.finalizeSentence() }
            self.stopCurrentSession()
            self.processedTextLength = 0
            self.fullTranscriptionText = ""
            self.currentTranscription = ""
            self.startNewSession()
        }
    }
    
    private func startRotationWatchdog() {
        sessionRotationTask?.cancel()
        sessionRotationTask = Task { [weak self] in
            let checkIntervalNs: UInt64 = 5_000_000_000
            while let self = self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: checkIntervalNs)
                guard self.isRecording, let start = self.sessionStartTime else { continue }
                if Date().timeIntervalSince(start) >= self.maxTaskDuration {
                    self.rotateSession(reason: "max-duration", finalizeCurrent: true)
                }
            }
        }
    }

    private func extractNewTranscriptionPart(from fullText: String) -> String {
        // Extract only the part that hasn't been processed yet
        if fullText.count > processedTextLength {
            let startIndex = fullText.index(fullText.startIndex, offsetBy: processedTextLength)
            let newPart = String(fullText[startIndex...])
            return newPart.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
    
    /// Find the last stable sentence boundary in fullTranscriptionText after processedTextLength.
    /// A stable boundary = sentence-ending punctuation followed by more text (SF has moved past it).
    /// Finalizes everything up to that boundary, keeps the rest as currentTranscription.
    @MainActor
    private func finalizeCompleteSentences() {
        let fullText = fullTranscriptionText
        guard fullText.count > processedTextLength else { return }

        // Scan unprocessed portion for the last sentence-ender NOT at the very end
        let startIdx = fullText.index(fullText.startIndex, offsetBy: processedTextLength)
        var lastBoundary: String.Index? = nil
        var idx = startIdx

        while idx < fullText.endIndex {
            let char = fullText[idx]
            let nextIdx = fullText.index(after: idx)
            if sentenceEnders.contains(char) && nextIdx < fullText.endIndex {
                // Skip consecutive punctuation like "..." or "?!" — not a real boundary
                let nextChar = fullText[nextIdx]
                if !sentenceEnders.contains(nextChar) {
                    lastBoundary = nextIdx
                }
            }
            idx = nextIdx
        }

        guard let boundary = lastBoundary else { return }

        let completedText = String(fullText[startIdx..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainingText = String(fullText[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !completedText.isEmpty else { return }

        logger.info("📝 FINALIZING STABLE SENTENCES: \(completedText)")

        let entryId = addToHistory(completedText)
        speechEventsContinuation?.yield(.sentenceFinalized(captionId: entryId, sentence: completedText))

        processedTextLength = fullText.distance(from: fullText.startIndex, to: boundary)
        currentTranscription = remainingText
    }

    @MainActor
    private func finalizeSentence() {
        guard !currentTranscription.isEmpty else { return }

        let finalText = currentTranscription

        logger.info("📝 FINALIZING SENTENCE: \(finalText)")

        // Add the current sentence part to history and get the entry ID
        let entryId = addToHistory(finalText)

        // Notify via AsyncStream with caption ID - this triggers UI to create new line!
        speechEventsContinuation?.yield(.sentenceFinalized(captionId: entryId, sentence: finalText))

        // Update processed length to include what we just added
        processedTextLength = fullTranscriptionText.count

        // Clear current transcription for next sentence
        currentTranscription = ""

    }
    
    @MainActor
    @discardableResult
    private func addToHistory(_ text: String) -> UUID {
        let entryId = UUID()
        let entry = CaptionEntry(
            id: entryId,
            text: text,
            confidence: 1.0 // SFSpeechRecognizer doesn't provide confidence scores
        )
        captionHistory.append(entry)

        // Keep only last 50 entries to prevent memory issues
        if captionHistory.count > 50 {
            captionHistory.removeFirst()
        }

        logger.info("📝 Added to history: \(text)")
        return entryId
    }
    
    // MARK: - Public Utility Methods
    
    func clearCaptions() {
        Task { @MainActor in
            self.captionHistory.removeAll()
            self.currentTranscription = ""
            self.consecutiveSilenceFrames = 0
            self.logger.info("🗑️ CLEARED ALL CAPTIONS")
        }
    }

    @MainActor
    func updateTranslation(for captionId: UUID, translation: String) {
        if let index = captionHistory.firstIndex(where: { $0.id == captionId }) {
            captionHistory[index].translation = translation
            logger.info("🌐 Updated translation for caption \(captionId)")
        }
    }

    /// Force finalization of current transcription (for translation timing triggers)
    /// Called when sync/idle thresholds are reached without natural silence detection
    @MainActor
    func forceFinalizeSentence() {
        guard !currentTranscription.isEmpty else { return }
        logger.info("📝 FORCE FINALIZING (timing trigger): \(self.currentTranscription)")
        finalizeSentence()
    }
}

// MARK: - Error Types

enum SpeechRecognitionError: Error, LocalizedError {
    case recognizerNotAvailable
    case notAuthorized
    case requestCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .recognizerNotAvailable:
            return "Speech recognizer is not available"
        case .notAuthorized:
            return "Speech recognition is not authorized"
        case .requestCreationFailed:
            return "Failed to create speech recognition request"
        }
    }
}
