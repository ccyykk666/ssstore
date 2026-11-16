import Foundation
import Network

/// One private, loopback-only transport per recording. Closing it interrupts a
/// blocked DVT read without touching Rust handles from another thread.
final class PerformanceRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ssstore.performance.transport")
    private let lock = NSLock()
    private var stopped = false
    private var storedFailure: Error?
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var timeout: DispatchWorkItem?
    private var ready: CheckedContinuation<UInt16, Error>?
    private let host: String
    private let port: UInt16
    private var accepted = false

    init(host: String, port: UInt16) { self.host = host; self.port = port }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return storedFailure }
    func open() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.isStopped else { continuation.resume(throwing: CancellationError()); return }
                self.ready = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let port = listener.port, let pending = self.ready {
                                self.ready = nil; pending.resume(returning: port.rawValue)
                            }
                        case .failed(let error): self.close(error: error)
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.start(queue: self.queue)
                    self.armTimeout(seconds: 30)
                } catch { self.close(error: error) }
            }
        }
    }
    private func accept(_ incoming: NWConnection) {
        guard !isStopped, !accepted, let targetPort = NWEndpoint.Port(rawValue: port) else { incoming.cancel(); return }
        accepted = true
        let outgoing = NWConnection(host: NWEndpoint.Host(host), port: targetPort, using: .tcp)
        connections = [incoming, outgoing]
        for connection in connections {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.close(error: error) }
            }
            connection.start(queue: queue)
        }
        forward(incoming, to: outgoing)
        forward(outgoing, to: incoming)
    }
    private func forward(_ source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.isStopped else { return }
            if let error { self.close(error: error); return }
            guard let data, !data.isEmpty else {
                if complete { self.close(error: URLError(.networkConnectionLost)) }
                else { self.forward(source, to: destination) }
                return
            }
            destination.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.isStopped else { return }
                if let error { self.close(error: error) }
                else if complete { self.close(error: URLError(.networkConnectionLost)) }
                else { self.forward(source, to: destination) }
            })
        }
    }
    func receivedSample() { queue.async { if !self.isStopped { self.armTimeout(seconds: 15) } } }
    private func armTimeout(seconds: Double) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.close(error: NSError(domain: "ssstore.Performance", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "性能服务未及时返回数据，请检查回环、配对连接及开发者服务后重试。 "]))
        }
        timeout = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    func cancel() {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { self.close(error: CancellationError()) }
    }
    private func close(error: Error) {
        lock.lock()
        stopped = true
        if !(error is CancellationError), storedFailure == nil { storedFailure = error }
        lock.unlock()
        timeout?.cancel(); timeout = nil
        listener?.newConnectionHandler = nil; listener?.stateUpdateHandler = nil
        listener?.cancel(); listener = nil
        for connection in connections { connection.stateUpdateHandler = nil; connection.cancel() }
        connections = []
        if let ready { self.ready = nil; ready.resume(throwing: error) }
    }
}

