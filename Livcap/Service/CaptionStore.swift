//
//  CaptionStore.swift
//  Livcap
//
//  SwiftData persistence for caption history with search support.
//

import Foundation
import SwiftData
import os.log

// MARK: - SwiftData Model

@Model
final class CaptionRecord {
    @Attribute(.unique) var id: UUID
    var text: String
    var confidence: Float?
    var timestamp: Date
    var translation: String?

    init(id: UUID, text: String, confidence: Float? = nil, timestamp: Date = Date(), translation: String? = nil) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.timestamp = timestamp
        self.translation = translation
    }

    func toCaptionEntry() -> CaptionEntry {
        CaptionEntry(id: id, text: text, confidence: confidence, timestamp: timestamp, translation: translation)
    }
}

// MARK: - CaptionStore

final class CaptionStore {

    private let container: ModelContainer
    private let logger = Logger(subsystem: "com.livcap.storage", category: "CaptionStore")

    init() {
        do {
            let schema = Schema([CaptionRecord.self])
            let config = ModelConfiguration("Captions", schema: schema)
            container = try ModelContainer(for: schema, configurations: [config])
            logger.info("SwiftData container initialized")
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }

    // MARK: - Write Operations

    func insert(_ entry: CaptionEntry) {
        let context = ModelContext(container)
        let record = CaptionRecord(
            id: entry.id,
            text: entry.text,
            confidence: entry.confidence,
            timestamp: entry.timestamp,
            translation: entry.translation
        )
        context.insert(record)
        do {
            try context.save()
        } catch {
            logger.error("Failed to insert caption: \(error.localizedDescription)")
        }
    }

    func updateTranslation(id: UUID, translation: String) {
        let context = ModelContext(container)
        let targetId = id
        var descriptor = FetchDescriptor<CaptionRecord>(
            predicate: #Predicate { $0.id == targetId }
        )
        descriptor.fetchLimit = 1

        do {
            guard let record = try context.fetch(descriptor).first else { return }
            record.translation = translation
            try context.save()
        } catch {
            logger.error("Failed to update translation: \(error.localizedDescription)")
        }
    }

    func deleteAll() {
        let context = ModelContext(container)
        do {
            try context.delete(model: CaptionRecord.self)
            try context.save()
            logger.info("All captions deleted")
        } catch {
            logger.error("Failed to delete captions: \(error.localizedDescription)")
        }
    }

    // MARK: - Read Operations

    func fetchAll(limit: Int? = nil) -> [CaptionEntry] {
        let context = ModelContext(container)
        // Fetch most recent N entries (descending), then reverse for chronological order
        var descriptor = FetchDescriptor<CaptionRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        if let limit {
            descriptor.fetchLimit = limit
        }
        do {
            let records = try context.fetch(descriptor)
            return records.reversed().map { $0.toCaptionEntry() }
        } catch {
            logger.error("Failed to fetch captions: \(error.localizedDescription)")
            return []
        }
    }

    func search(query: String) -> [CaptionEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let context = ModelContext(container)
        var descriptor = FetchDescriptor<CaptionRecord>(
            predicate: #Predicate<CaptionRecord> { record in
                record.text.localizedStandardContains(trimmed) ||
                (record.translation?.localizedStandardContains(trimmed) ?? false)
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 200

        do {
            let records = try context.fetch(descriptor)
            return records.map { $0.toCaptionEntry() }
        } catch {
            logger.error("Failed to search captions: \(error.localizedDescription)")
            return []
        }
    }

    func count() -> Int {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<CaptionRecord>()
        do {
            return try context.fetchCount(descriptor)
        } catch {
            return 0
        }
    }
}
