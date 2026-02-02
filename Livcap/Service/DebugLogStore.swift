import Foundation

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: Level

    enum Level {
        case info
        case warning
        case error

        var label: String {
            switch self {
            case .info: return "INFO"
            case .warning: return "WARN"
            case .error: return "ERROR"
            }
        }
    }
}

@MainActor
final class DebugLogStore: ObservableObject {
    static let shared = DebugLogStore()

    /// Debug logging is only active when the app is launched with `--debug`.
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--debug")

    @Published private(set) var entries: [DebugLogEntry] = []

    private let maxEntries = 1000

    private init() {}

    func log(_ message: String, level: DebugLogEntry.Level = .info) {
        guard Self.isEnabled else { return }
        let entry = DebugLogEntry(timestamp: Date(), message: message, level: level)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// Log from any isolation context. Timestamp is captured at call site.
    nonisolated func send(_ message: String, level: DebugLogEntry.Level = .info) {
        guard Self.isEnabled else { return }
        let entry = DebugLogEntry(timestamp: Date(), message: message, level: level)
        Task { @MainActor in
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func clear() {
        entries.removeAll()
    }
}
