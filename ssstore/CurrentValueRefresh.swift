import Foundation

/// Bounded, serial current-value reads. Stop invalidates callbacks immediately;
/// an already-running read finishes with its own buffers and its result is dropped.
@MainActor
final class CurrentValueRefresh {
    private let queue = DispatchQueue(label: "ssstore.current-value", qos: .utility)
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var value: ((Data) -> Void)?
    private var failure: ((Error) -> Void)?
    var isActive: Bool { task != nil }
    deinit { task?.cancel() }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; value = nil; failure = nil
    }
    func start(interval: UInt64 = 1_000_000_000, read: @escaping @Sendable () throws -> Data,
               onValue: @escaping (Data) -> Void, onError: @escaping (Error) -> Void) {
        guard task == nil else { return }
        let token = UUID(); generation = token; value = onValue; failure = onError
        let queue = queue
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        queue.async {
                            autoreleasepool {
                                do { continuation.resume(returning: try read()) }
                                catch { continuation.resume(throwing: error) }
                            }
                        }
                    }
                    guard !Task.isCancelled, self != nil else { return }
                    self?.deliver(data, token: token)
                } catch {
                    guard !Task.isCancelled, self != nil else { return }
                    self?.deliver(error, token: token)
                }
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
            }
        }
    }
    private func deliver(_ data: Data, token: UUID) { if generation == token { value?(data) } }
    private func deliver(_ error: Error, token: UUID) { if generation == token { failure?(error) } }
}
