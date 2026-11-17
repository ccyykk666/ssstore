import Foundation
import Network

/// A recording owns two independent relays: RPPairing, then the dynamically
/// negotiated TLS-PSK port. Closing both interrupts Rust reads without touching
/// an in-flight FFI handle from another thread.
final class PerformanceRelay: @unchecked Sendable {
    private final class Endpoint {
        let listener: NWListener
        var ready: ((Result<UInt16, Error>) -> Void)?
        var connections: [NWConnection] = []
        var accepted = false
        var closed = false
        init(_ listener: NWListener, ready: @escaping (Result<UInt16, Error>) -> Void) {
            self.listener = listener; self.ready = ready
        }
        func close() {
            guard !closed else { return }; closed = true
            listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil; listener.cancel()
            for connection in connections { connection.stateUpdateHandler = nil; connection.cancel() }
            connections = []
        }
    }
    private final class PortResult: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var value: Result<UInt16, Error>?
        func resolve(_ result: Result<UInt16, Error>) { value = result; semaphore.signal() }
    }
    private let queue = DispatchQueue(label: "ssstore.performance.transport")
    private let lock = NSLock()
    private var stopped = false
    private var storedFailure: Error?
    private var endpoints: [Endpoint] = []
    private var timeout: DispatchWorkItem?
    private let host: String
    private let port: UInt16

    init(host: String, port: UInt16) { self.host = host; self.port = port }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return storedFailure }
    func open() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.listen(upstreamPort: self.port) { continuation.resume(with: $0) }
                if !self.isStopped { self.armTimeout(seconds: 30) }
            }
        }
    }
    /// Called only on the FFI worker, never the main thread or transport queue.
    /// The callback finishes before Rust opens its second TCP connection.
    func openTunnelPort(_ port: UInt16) -> UInt16 {
        let result = PortResult()
        queue.async { self.listen(upstreamPort: port) { result.resolve($0) } }
        guard result.semaphore.wait(timeout: .now() + 10) == .success else {
            queue.async { self.close(error: URLError(.timedOut)) }
            return 0
        }
        return (try? result.value?.get()) ?? 0
    }
    private func listen(upstreamPort: UInt16, ready: @escaping (Result<UInt16, Error>) -> Void) {
        guard !isStopped else { ready(.failure(CancellationError())); return }
        guard upstreamPort > 0, endpoints.count < 2 else { ready(.failure(URLError(.badURL))); return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let endpoint = Endpoint(listener, ready: ready)
            endpoints.append(endpoint)
            listener.stateUpdateHandler = { [weak self, weak endpoint] state in
                guard let self, let endpoint else { return }
                switch state {
                case .ready:
                    if let port = listener.port, let pending = endpoint.ready {
                        endpoint.ready = nil; pending(.success(port.rawValue))
                    }
                case .failed(let error): self.endpointFailed(endpoint, error: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self, weak endpoint] connection in
                guard let self, let endpoint else { connection.cancel(); return }
                self.accept(connection, endpoint: endpoint, upstreamPort: upstreamPort)
            }
            listener.start(queue: queue)
        } catch { ready(.failure(error)); close(error: error) }
    }
    private func accept(_ incoming: NWConnection, endpoint: Endpoint, upstreamPort: UInt16) {
        guard !isStopped, !endpoint.accepted, let targetPort = NWEndpoint.Port(rawValue: upstreamPort) else { incoming.cancel(); return }
        endpoint.accepted = true
        let outgoing = NWConnection(host: NWEndpoint.Host(host), port: targetPort, using: .tcp)
        endpoint.connections = [incoming, outgoing]
        for connection in endpoint.connections {
            connection.stateUpdateHandler = { [weak self, weak endpoint] state in
                if case .failed(let error) = state, let endpoint { self?.endpointFailed(endpoint, error: error) }
            }
            connection.start(queue: queue)
        }
        forward(incoming, to: outgoing, endpoint: endpoint)
        forward(outgoing, to: incoming, endpoint: endpoint)
    }
    private func endpointFailed(_ endpoint: Endpoint, error: Error) {
        guard !endpoint.closed, !isStopped else { return }
        if endpoints.count == 2, endpoint === endpoints.first {
            // Once CreateTCPListener has succeeded, the pairing stream is no
            // longer used. Its FIN or RST must not kill the independent TLS stream.
            endpoint.close()
        } else { close(error: error) }
    }
    private func forward(_ source: NWConnection, to destination: NWConnection, endpoint: Endpoint) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.isStopped, !endpoint.closed else { return }
            if let error { self.endpointFailed(endpoint, error: error); return }
            guard let data, !data.isEmpty else {
                // RPPairing closes normally once the TLS tunnel is established.
                // Its EOF must never cancel that independent tunnel.
                if complete { self.finishDirection(to: destination, endpoint: endpoint) }
                else { self.forward(source, to: destination, endpoint: endpoint) }
                return
            }
            destination.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.isStopped, !endpoint.closed else { return }
                if let error { self.endpointFailed(endpoint, error: error) }
                else if complete { self.finishDirection(to: destination, endpoint: endpoint) }
                else { self.forward(source, to: destination, endpoint: endpoint) }
            })
        }
    }
    private func finishDirection(to connection: NWConnection, endpoint: Endpoint) {
        // Propagate a TCP half-close after the final bytes; the other direction
        // may still have buffered data. Keep the endpoint alive until teardown.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error { self?.endpointFailed(endpoint, error: error) }
        })
    }
    func receivedSample() { queue.async { if !self.isStopped { self.armTimeout(seconds: 15) } } }
    private func armTimeout(seconds: Double) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.close(error: NSError(domain: "ssstore.Performance", code: 1,
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
        for endpoint in endpoints {
            endpoint.close()
            if let pending = endpoint.ready { endpoint.ready = nil; pending(.failure(error)) }
        }
        endpoints = []
    }
}
