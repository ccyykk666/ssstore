import Foundation
import Network

@main
struct PerformanceRelayChecks {
    enum Failure: Error { case noPort, mismatch, deadline, notCancelled }
    static func main() async throws {
        // Independent echo server proves real transport forwarding, including
        // backpressure across multiple 64 KiB receives, without an iPhone.
        let queue = DispatchQueue(label: "performance-relay-test")
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            echo(connection)
        }
        let upstreamPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resolved = false
            listener.stateUpdateHandler = { state in
                guard !resolved else { return }
                if case .ready = state {
                    resolved = true
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: Failure.noPort) }
                } else if case .failed(let error) = state { resolved = true; continuation.resume(throwing: error) }
            }
            listener.start(queue: queue)
        }
        defer { listener.cancel() }
        let relay = PerformanceRelay(host: "127.0.0.1", port: upstreamPort)
        let port = try await relay.open()
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { client.cancel(); relay.cancel() }
        client.start(queue: queue)
        let payload = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
        let returned: Data = try await withCheckedThrowingContinuation { continuation in
            client.send(content: payload, completion: .contentProcessed { _ in })
            receive(client, expected: payload.count, accumulated: Data(), continuation: continuation)
        }
        guard returned == payload else { throw Failure.mismatch }
        // RPPairing advertises another port. The TLS client must reach that
        // port rather than the same-numbered port on localhost (the old bug).
        let tunnelServer = try NWListener(using: .tcp, on: .any)
        tunnelServer.newConnectionHandler = { connection in connection.start(queue: queue); echo(connection) }
        let upstreamTunnelPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resolved = false
            tunnelServer.stateUpdateHandler = { state in
                guard !resolved else { return }
                if case .ready = state, let port = tunnelServer.port { resolved = true; continuation.resume(returning: port.rawValue) }
                else if case .failed(let error) = state { resolved = true; continuation.resume(throwing: error) }
            }
            tunnelServer.start(queue: queue)
        }
        defer { tunnelServer.cancel() }
        let tunnelPort = await Task.detached { relay.openTunnelPort(upstreamTunnelPort) }.value
        guard tunnelPort > 0, tunnelPort != port else { throw Failure.noPort }
        let tunnelClient = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: tunnelPort)!, using: .tcp)
        tunnelClient.start(queue: queue)
        defer { tunnelClient.cancel() }
        // The short-lived pairing connection ends normally. The independent
        // TLS connection must keep working after that EOF, including final bytes.
        let pairingClosed: Bool = await withCheckedContinuation { continuation in
            client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            client.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                continuation.resume(returning: complete || error != nil)
            }
        }
        guard pairingClosed, !relay.isStopped else { throw Failure.mismatch }
        let tunnelReturned: Data = try await withCheckedThrowingContinuation { continuation in
            tunnelClient.send(content: payload, completion: .contentProcessed { _ in })
            receive(tunnelClient, expected: payload.count, accumulated: Data(), continuation: continuation)
        }
        guard tunnelReturned == payload else { throw Failure.mismatch }
        // Cancelling a recording must interrupt the second blocked reader too.
        let closed: Bool = await withCheckedContinuation { continuation in
            tunnelClient.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                continuation.resume(returning: complete || error != nil)
            }
            relay.cancel(); relay.cancel()
        }
        guard closed, relay.isStopped else { throw Failure.notCancelled }
        guard relay.openTunnelPort(upstreamTunnelPort) == 0 else { throw Failure.notCancelled }
        let cancelled = PerformanceRelay(host: "127.0.0.1", port: upstreamPort)
        cancelled.cancel()
        do { _ = try await cancelled.open(); throw Failure.notCancelled }
        catch is CancellationError { }
        print("Performance relay: two-port negotiation, pairing EOF isolation, 256 KiB round trips and cancellation passed")
    }
    static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            guard let data, !data.isEmpty, error == nil else { connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed { error in
                if complete || error != nil { connection.cancel() } else { echo(connection) }
            })
        }
    }
    static func receive(_ connection: NWConnection, expected: Int, accumulated: Data,
                        continuation: CheckedContinuation<Data, Error>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            if let error { continuation.resume(throwing: error); return }
            var result = accumulated; if let data { result.append(data) }
            if result.count == expected { continuation.resume(returning: result) }
            else if complete { continuation.resume(throwing: Failure.mismatch) }
            else { receive(connection, expected: expected, accumulated: result, continuation: continuation) }
        }
    }
}
