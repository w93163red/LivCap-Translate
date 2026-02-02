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
import NaturalLanguage
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
    
    // Segment-based text processing state
    private var processedSegmentCount: Int = 0

    // Frame-based silence detection
    private var consecutiveSilenceFrames: Int = 0
    private let silenceFrameThreshold: Int = 10  // ~2 seconds (20 frames × 100ms)
    private var currentSpeechState: Bool = false

    // NLP-based sentence boundary detection
    private let sentenceTokenizer = NLTokenizer(unit: .sentence)

    // Post-filter: abbreviations that NLTokenizer misidentifies as sentence boundaries
    private let abbreviationSuffixes: Set<String> = [
        "Mr.", "Mrs.", "Ms.", "Dr.", "Jr.", "Sr.", "Prof.",
        "St.", "Ave.", "Blvd.", "Rd.", "Ln.",
        "Inc.", "Corp.", "Ltd.", "Co.",
        "vs.", "etc.", "approx.", "dept.",
        "Jan.", "Feb.", "Mar.", "Apr.", "Jun.", "Jul.", "Aug.", "Sep.", "Oct.", "Nov.", "Dec.",
    ]

    // AsyncStream for events
    private var speechEventsContinuation: AsyncStream<SpeechEvent>.Continuation?
    private var speechEventsStream: AsyncStream<SpeechEvent>?
    
    // Persistence
    let captionStore = CaptionStore()

    // Logging
    private var isLoggerOn: Bool = false // change to true for debugging
    private let logger = Logger(subsystem: "com.livcap.speech", category: "SpeechRecognitionManager")

    // Session rotation
    private var sessionStartTime: Date?

    // Lazy session: no active session when idle (no speech)
    private var sessionActive: Bool = false

    // Session ID to discard stale callbacks from cancelled sessions
    private var currentSessionId: UUID = UUID()
    
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
        DebugLogStore.shared.send("STARTING SPEECH RECOGNITION ENGINE")
        
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Create initial recognition session
        await MainActor.run {
            self.startNewSession()
        }
        
        await MainActor.run {
            self.isRecording = true
            self.currentTranscription = ""
        }
        
        // Reset state
        processedSegmentCount = 0
        currentSpeechState = false
        consecutiveSilenceFrames = 0

        // Session rotation is handled by result.isFinal callback
        
        logger.info("✅ SPEECH RECOGNITION ENGINE STARTED")
        DebugLogStore.shared.send("SPEECH RECOGNITION ENGINE STARTED")
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
        processedSegmentCount = 0
        consecutiveSilenceFrames = 0

        logger.info("✅ SPEECH RECOGNITION ENGINE STOPPED")
        DebugLogStore.shared.send("SPEECH RECOGNITION ENGINE STOPPED")
    }
    
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.append(buffer)
    }

    func appendAudioBufferWithVAD(_ audioFrame: AudioFrameWithVAD) {
        guard isRecording else { return }

        // Log frame info before appending buffer
        if isLoggerOn {
            let sourceString = audioFrame.source.rawValue.uppercased()
            let vadValue = audioFrame.vadResult.rmsEnergy
            let isSpeechString = audioFrame.isSpeech ? "SPEECH" : "SILENCE"
            logger.info("(\(sourceString) Frame \(audioFrame.frameIndex) - VAD RMS: \(vadValue), State: \(isSpeechString)")
        }

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
                    DebugLogStore.shared.send("2s SILENCE - Creating new caption line")
                    Task { @MainActor in
                        self.finalizeSentence()
                    }
                }
                consecutiveSilenceFrames = 0  // Reset counter
            }
        }

        // Only feed audio to recognizer when session is active
        if let recognitionRequest = recognitionRequest {
            recognitionRequest.append(audioFrame.buffer)
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
    private func processTranscriptionResult(_ result: SFSpeechRecognitionResult) {
        let transcription = result.bestTranscription
        let segments = transcription.segments
        let formattedString = transcription.formattedString

        // Guard: if Apple reduced segment count below our marker (merged words), adjust
        if processedSegmentCount > segments.count {
            processedSegmentCount = segments.count
        }

        // Build currentTranscription from unprocessed segments
        let previousTranscription = currentTranscription
        currentTranscription = textFromSegments(formattedString, segments: segments,
                                                from: processedSegmentCount, to: segments.count)

        // Debug log (only when transcription changed and is non-empty)
        if !currentTranscription.isEmpty && currentTranscription != previousTranscription {
            logger.info("🔍 [DEBUG] segments=\(segments.count) processed=\(self.processedSegmentCount) current=\"\(self.currentTranscription)\"")
            DebugLogStore.shared.log("segments=\(segments.count) processed=\(self.processedSegmentCount) current=\"\(self.currentTranscription)\"")
        }

        // Notify via AsyncStream
        speechEventsContinuation?.yield(.transcriptionUpdate(currentTranscription))

        // Reset silence counter if text changed during silence
        if currentTranscription != previousTranscription && !currentSpeechState {
            consecutiveSilenceFrames = 0
        }

        // Finalize stable sentences using segment boundaries
        finalizeStableSentences(formattedString: formattedString, segments: segments)
    }
    
    // MARK: - Session Management (Concise)
    
    @MainActor
    private func startNewSession() {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            logger.error("❌ Cannot start session: recognizer unavailable")
            DebugLogStore.shared.log("Cannot start session: recognizer unavailable", level: .error)
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        recognitionRequest = request
        let sessionId = UUID()
        currentSessionId = sessionId
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            Task {
                // Discard callbacks from a stale (already-rotated) session
                guard self.currentSessionId == sessionId else { return }

                if let error = error {
                    // "No speech detected" is expected when idle — silently tear down
                    let nsError = error as NSError
                    let isNoSpeech = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110

                    if isNoSpeech {
                        // Silently rotate — keep session ready for next speech
                        if self.isRecording {
                            self.rotateSession(reason: "no-speech", finalizeCurrent: false)
                        }
                        return
                    }

                    self.updateStatus("Recognition error: \(error.localizedDescription)")
                    self.speechEventsContinuation?.yield(.error(error))
                    DebugLogStore.shared.send("Recognition error: \(error.localizedDescription)", level: .error)
                    if self.isRecording {
                        self.logger.info("♻️ Auto-recovering from recognition error")
                        DebugLogStore.shared.send("Auto-recovering from recognition error", level: .warning)
                        self.rotateSession(reason: "error-recovery", finalizeCurrent: true)
                    }
                    return
                }
                if let result = result {
                    self.processTranscriptionResult(result)

                    if result.isFinal {
                        self.logger.info("♻️ Recognition result is final, rotating session")
                        DebugLogStore.shared.send("Recognition result is final, rotating session")
                        self.rotateSession(reason: "result-final", finalizeCurrent: true)
                    }
                }
            }
        }
        sessionStartTime = Date()
        sessionActive = true
        logger.info("♻️ Session started")
        DebugLogStore.shared.log("Session started")
    }

    @MainActor
    private func stopCurrentSession() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        sessionStartTime = nil
        sessionActive = false
    }
    
    private func rotateSession(reason: String, finalizeCurrent: Bool) {
        Task { @MainActor in
            guard self.isRecording else { return }
            // Only log meaningful rotations, not idle no-speech cycles
            if reason != "no-speech" {
                self.logger.info("♻️ Rotate session (reason=\(reason))")
                DebugLogStore.shared.log("Rotate session (reason=\(reason))")
            }
            if finalizeCurrent { self.finalizeSentence() }
            self.stopCurrentSession()
            self.processedSegmentCount = 0
            self.currentTranscription = ""
            self.startNewSession()
        }
    }
    

    /// Extract text from a range of segments using their substringRange in formattedString.
    private func textFromSegments(_ formattedString: String, segments: [SFTranscriptionSegment],
                                  from startIdx: Int, to endIdx: Int) -> String {
        guard startIdx < endIdx, startIdx < segments.count, endIdx <= segments.count else { return "" }
        let nsString = formattedString as NSString
        let startRange = segments[startIdx].substringRange
        let endRange = segments[endIdx - 1].substringRange
        let location = startRange.location
        let length = (endRange.location + endRange.length) - location
        let combinedRange = NSRange(location: location, length: length)
        return nsString.substring(with: combinedRange).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if text ends with an abbreviation (NLTokenizer false positive filter).
    /// Handles both known abbreviations ("St.", "Dr.") and single uppercase letter + period ("N.", "E.").
    private func endsWithAbbreviation(_ text: String) -> Bool {
        // Check single uppercase letter + period (e.g., "N.", "S.", "E.", "W.")
        if text.count >= 2 {
            let lastTwo = String(text.suffix(2))
            if lastTwo.count == 2 && lastTwo.last == "." && lastTwo.first?.isUppercase == true {
                return true
            }
        }
        // Check known multi-character abbreviations
        let lowered = text.lowercased()
        for abbr in abbreviationSuffixes {
            if lowered.hasSuffix(abbr.lowercased()) {
                return true
            }
        }
        return false
    }

    /// Use NLTokenizer to find sentence boundaries in formattedString, then finalize
    /// complete sentences that fall within the "stable zone" (before the last segment).
    @MainActor
    private func finalizeStableSentences(formattedString: String, segments: [SFTranscriptionSegment]) {
        // Need at least 2 unprocessed segments (last one is unstable — Apple may still revise it)
        guard segments.count > processedSegmentCount + 1 else { return }

        // Run NLTokenizer on full formattedString
        sentenceTokenizer.string = formattedString

        // Collect sentence end offsets (UTF-16 positions in formattedString)
        var sentenceEndOffsets: [Int] = []
        sentenceTokenizer.enumerateTokens(in: formattedString.startIndex..<formattedString.endIndex) { range, _ in
            let nsRange = NSRange(range, in: formattedString)
            sentenceEndOffsets.append(nsRange.location + nsRange.length)
            return true
        }

        // Define the stable zone in formattedString coordinates
        let unprocessedStart = segments[processedSegmentCount].substringRange.location
        let lastStableSegment = segments[segments.count - 2]
        let stableEnd = lastStableSegment.substringRange.location + lastStableSegment.substringRange.length

        // Find the last sentence boundary within our stable zone,
        // filtering out boundaries that end with abbreviations (NLTokenizer false positives)
        let nsString = formattedString as NSString
        var lastValidBoundary: Int? = nil
        for endOffset in sentenceEndOffsets {
            if endOffset > unprocessedStart && endOffset <= stableEnd {
                // Check if this boundary ends with an abbreviation
                let sentenceText = nsString.substring(
                    with: NSRange(location: unprocessedStart, length: endOffset - unprocessedStart)
                ).trimmingCharacters(in: .whitespaces)
                if endsWithAbbreviation(sentenceText) {
                    continue  // Skip false boundary
                }
                lastValidBoundary = endOffset
            }
        }

        guard let boundary = lastValidBoundary else { return }

        // Map boundary offset back to a segment index
        var boundarySegmentIdx = processedSegmentCount
        for i in processedSegmentCount..<segments.count {
            let segEnd = segments[i].substringRange.location + segments[i].substringRange.length
            if segEnd <= boundary {
                boundarySegmentIdx = i
            } else {
                break
            }
        }

        // Safety: boundary segment must be before the last segment
        guard boundarySegmentIdx >= processedSegmentCount && boundarySegmentIdx < segments.count - 1 else { return }

        let completedText = textFromSegments(formattedString, segments: segments,
                                             from: processedSegmentCount, to: boundarySegmentIdx + 1)

        // Sanity check: skip if text has no real content (Apple revision artifact)
        guard completedText.contains(where: { $0.isLetter || $0.isNumber }) else { return }

        logger.info("📝 FINALIZING STABLE SENTENCES: \(completedText)")
        DebugLogStore.shared.log("FINALIZE STABLE: \(completedText)")

        let entryId = addToHistory(completedText)
        speechEventsContinuation?.yield(.sentenceFinalized(captionId: entryId, sentence: completedText))

        processedSegmentCount = boundarySegmentIdx + 1

        // Update currentTranscription to remaining segments
        currentTranscription = textFromSegments(formattedString, segments: segments,
                                                from: processedSegmentCount, to: segments.count)
    }

    @MainActor
    private func finalizeSentence() {
        guard !currentTranscription.isEmpty else { return }

        let finalText = currentTranscription

        logger.info("📝 FINALIZING SENTENCE: \(finalText)")
        DebugLogStore.shared.log("FINALIZE SENTENCE: \(finalText)")

        // Split long text into multiple sentences to avoid dumping one huge block
        let sentences = splitIntoSentences(finalText)
        for sentence in sentences {
            let entryId = addToHistory(sentence)
            speechEventsContinuation?.yield(.sentenceFinalized(captionId: entryId, sentence: sentence))
        }

        // Mark all current segments as processed.
        // Set to Int.max; processTranscriptionResult will clamp on next callback.
        processedSegmentCount = Int.max
        currentTranscription = ""
    }

    /// Split text into sentences using NLTokenizer.
    /// Falls back to returning the full text if no boundaries are found.
    private func splitIntoSentences(_ text: String) -> [String] {
        sentenceTokenizer.string = text
        var sentences: [String] = []
        sentenceTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        return sentences.isEmpty ? [text] : sentences
    }
    
    @MainActor
    @discardableResult
    private func addToHistory(_ text: String) -> UUID {
        let entryId = UUID()
        let entry = CaptionEntry(
            id: entryId,
            text: text,
            confidence: 1.0, // SFSpeechRecognizer doesn't provide confidence scores
            timestamp: Date()
        )
        captionHistory.append(entry)

        // Keep only last 500 entries in memory for overlay display
        if captionHistory.count > 500 {
            captionHistory.removeFirst()
        }

        // Persist to SQLite (unlimited storage)
        captionStore.insert(entry)

        logger.info("📝 Added to history: \(text)")
        return entryId
    }
    
    // MARK: - Public Utility Methods
    
    func clearCaptions() {
        Task { @MainActor in
            self.captionHistory.removeAll()
            self.currentTranscription = ""
            self.consecutiveSilenceFrames = 0
            self.captionStore.deleteAll()
            self.logger.info("🗑️ CLEARED ALL CAPTIONS")
        }
    }

    /// Clear in-memory overlay state only (does not delete persisted data)
    func clearOverlay() {
        Task { @MainActor in
            self.captionHistory.removeAll()
            self.currentTranscription = ""
            self.consecutiveSilenceFrames = 0
            self.logger.info("🗑️ CLEARED OVERLAY")
        }
    }

    @MainActor
    func updateTranslation(for captionId: UUID, translation: String) {
        if let index = captionHistory.firstIndex(where: { $0.id == captionId }) {
            captionHistory[index].translation = translation
            logger.info("🌐 Updated translation for caption \(captionId)")
        }
        // Persist translation to SQLite
        captionStore.updateTranslation(id: captionId, translation: translation)
    }

    private func loadPersistedHistory() {
        let entries = captionStore.fetchAll(limit: 500)
        Task { @MainActor in
            self.captionHistory = entries
            if !entries.isEmpty {
                self.logger.info("📂 Loaded \(entries.count) entries from database")
            }
        }
    }

    /// Force finalization of current transcription (for translation timing triggers)
    /// Called when sync/idle thresholds are reached without natural silence detection
    @MainActor
    func forceFinalizeSentence() {
        guard !currentTranscription.isEmpty else { return }
        logger.info("📝 FORCE FINALIZING (timing trigger): \(self.currentTranscription)")
        DebugLogStore.shared.log("FORCE FINALIZE (timing): \(self.currentTranscription)")
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
