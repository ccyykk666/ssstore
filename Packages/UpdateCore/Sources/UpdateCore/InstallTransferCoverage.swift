import Foundation

/// Count successfully written bytes once, including overlapping requests and
/// interrupted responses. HEAD and unread bytes never contribute to progress.
public struct InstallTransferCoverage {
    public let totalBytes: Int64
    private var ranges: [Range<Int64>] = []
    public var completedBytes: Int64 { ranges.reduce(0) { $0 + $1.countAsInt64 } }
    public var isComplete: Bool { totalBytes > 0 && completedBytes == totalBytes }

    public init(totalBytes: Int64) { self.totalBytes = totalBytes }

    @discardableResult
    public mutating func record(method: String, status: Int, contentLength: Int64,
                                contentRange: String?) -> Bool {
        guard let range = responseRange(method: method, status: status, contentLength: contentLength, contentRange: contentRange) else { return false }
        return recordWritten(range)
    }

    public func responseRange(method: String, status: Int, contentLength: Int64,
                              contentRange: String?) -> Range<Int64>? {
        guard method == "GET", totalBytes > 0 else { return nil }
        let next: Range<Int64>
        if status == 200, contentRange == nil, contentLength == totalBytes {
            next = 0..<totalBytes
        } else if status == 206, let header = contentRange, header.hasPrefix("bytes ") {
            let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, Int64(parts[1]) == totalBytes else { return nil }
            let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
                  start >= 0, start <= end, end < totalBytes,
                  contentLength == end - start + 1 else { return nil }
            next = start..<(end + 1)
        } else { return nil }
        return next
    }

    /// Call only after a body write succeeds, never merely after reading a file.
    /// Prefix updates are idempotent so retries cannot double count bytes.
    @discardableResult
    public mutating func recordWritten(_ next: Range<Int64>) -> Bool {
        guard !next.isEmpty, next.lowerBound >= 0, next.upperBound <= totalBytes else { return false }
        var merged: [Range<Int64>] = []
        for range in (ranges + [next]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        ranges = merged
        return true
    }
}

private extension Range where Bound == Int64 {
    var countAsInt64: Int64 { upperBound - lowerBound }
}
