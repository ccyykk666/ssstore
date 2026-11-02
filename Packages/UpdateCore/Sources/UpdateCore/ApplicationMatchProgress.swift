import Foundation

public struct ApplicationMatch: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case current, update, pending, failed }
    public let id: String
    public let isSystem: Bool
    public let outcome: Outcome

    public init(record: AppRecord, scope: String) {
        id = record.id
        isSystem = record.installed.isSystem
        if record.error != nil { outcome = .failed }
        else {
            switch record.status(country: scope) {
            case .different, .update: outcome = .update
            case .unknown: outcome = .pending
            default: outcome = .current
            }
        }
    }
}

public struct ApplicationMatchStatistics: Equatable, Sendable {
    public private(set) var applications = 0
    public private(set) var updates = 0
    public private(set) var pending = 0
    public private(set) var failures = 0

    public init(matches: [ApplicationMatch]) {
        for match in matches {
            applications += 1
            switch match.outcome {
            case .current: break
            case .update: updates += 1
            case .pending: pending += 1
            case .failed: failures += 1
            }
        }
    }
}

/// One ordered matching stream drives every number and status badge. The cursor
/// advances only by integers, so interrupted animations cannot overshoot below zero.
public struct ApplicationMatchProgress: Sendable {
    public let id = UUID()
    public let scope: String
    public private(set) var matches: [ApplicationMatch] = []
    public private(set) var revealedCount = 0

    public init(scope: String) { self.scope = scope }
    public var hasUnrevealed: Bool { revealedCount < matches.count }
    public var revealedMatches: [ApplicationMatch] { Array(matches.prefix(revealedCount)) }

    public mutating func complete(_ record: AppRecord) {
        let match = ApplicationMatch(record: record, scope: scope)
        if let index = matches.firstIndex(where: { $0.id == match.id }) {
            matches[index] = match
        } else {
            matches.append(match)
        }
    }

    /// Hidden system entries are consumed without delaying the next visible app.
    @discardableResult
    public mutating func revealNext(hidingSystemApps: Bool) -> Bool {
        let previous = revealedCount
        while revealedCount < matches.count {
            let match = matches[revealedCount]
            revealedCount += 1
            if !hidingSystemApps || !match.isSystem { break }
        }
        return revealedCount != previous
    }

    public func statistics(visibleIDs: Set<String>) -> ApplicationMatchStatistics {
        ApplicationMatchStatistics(matches: revealedMatches.filter { visibleIDs.contains($0.id) })
    }
}
