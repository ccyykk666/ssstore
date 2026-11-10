//
//  LogManager.swift
//  Asspp
//
//  Created on 2026/2/20.
//

import Foundation
import Logging
import UpdateCore

final nonisolated class LogManager: Sendable {
    static let shared = LogManager()

    static let maxMessages = 2000
    static let didChange = Notification.Name("ssstore.logs.changed")

    private let messageQueue = DispatchQueue(label: "wiki.qaq.log")
    // Confined to messageQueue, so a single formatter instance is safe to reuse.
    private nonisolated(unsafe) let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private nonisolated(unsafe) var messages: [String] = []
    private nonisolated(unsafe) var revision: UInt64 = 0

    func write(_ content: String) {
        let timestamp = Date()
        let safeContent = DiagnosticLog.redact(content)
        messageQueue.async {
            let logMessage = "[\(self.timestampFormatter.string(from: timestamp))]\n\(safeContent)"
            Swift.print(logMessage)
            self.messages.append(logMessage)
            self.revision &+= 1
            // Cap retained history so a long-running session cannot grow memory
            // without bound.
            if self.messages.count > Self.maxMessages {
                self.messages.removeFirst(self.messages.count - Self.maxMessages)
            }
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        }
    }

    func getMessages() -> [String] {
        messageQueue.sync { messages }
    }

    func snapshot() -> (revision: UInt64, messages: [String]) {
        messageQueue.sync { (revision, messages) }
    }
}

struct LogManagerHandler: LogHandler {
    var logLevel: Logger.Level = .debug
    var metadata: Logger.Metadata = [:]
    let label: String

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt,
    ) {
        guard DiagnosticLog.shouldInclude(level: level.rawValue, label: label, message: message.description) else { return }
        let combined = self.metadata.merging(metadata ?? [:]) { _, value in value }
        let details = combined.keys.sorted().map { key in
            "\(key)=\(Self.describe(combined[key]!, key: key))"
        }.joined(separator: ", ")
        LogManager.shared.write("[\(level)] [\(label)] \(message)" + (details.isEmpty ? "" : " | " + details))
    }

    private static func describe(_ value: Logger.MetadataValue, key: String) -> String {
        guard !DiagnosticLog.isSensitiveKey(key) else { return "<redacted>" }
        switch value {
        case .dictionary(let values):
            return "[" + values.keys.sorted().map { "\($0)=\(describe(values[$0]!, key: $0))" }.joined(separator: ", ") + "]"
        case .array(let values):
            return "[" + values.map { describe($0, key: key) }.joined(separator: ", ") + "]"
        default: return DiagnosticLog.redact(value.description)
        }
    }
}


