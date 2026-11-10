import Foundation

/// Count successfully streamed response bytes once, including overlapping Range
/// probes. A HEAD or a small range must never finish the server's background task.
public struct InstallTransferCoverage {
    public let totalBytes: Int64
    private var ranges: [Range<Int64>] = []
    public var completedBytes: Int64 { ranges.reduce(0) { $0 + $1.countAsInt64 } }
    public var isComplete: Bool { totalBytes > 0 && completedBytes == totalBytes }

    public init(totalBytes: Int64) { self.totalBytes = totalBytes }

    @discardableResult
    public mutating func record(method: String, status: Int, contentLength: Int64,
                                contentRange: String?) -> Bool {
        guard method == "GET", totalBytes > 0 else { return false }
        let next: Range<Int64>
        if status == 200, contentRange == nil, contentLength == totalBytes {
            next = 0..<totalBytes
        } else if status == 206, let header = contentRange, header.hasPrefix("bytes ") {
            let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, Int64(parts[1]) == totalBytes else { return false }
            let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
                  start >= 0, start <= end, end < totalBytes,
                  contentLength == end - start + 1 else { return false }
            next = start..<(end + 1)
        } else { return false }
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
