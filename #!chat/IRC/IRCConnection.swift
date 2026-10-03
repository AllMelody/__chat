import Foundation
import Network

/// The byte stream to an IRC server: TCP, optionally TLS, on Network.framework. TLS checks
/// the server's certificate against the system trust store, using the host name for SNI.
///
/// Knows nothing about IRC. Network.framework works on a private queue; results come back
/// through `async` calls and send completions.
nonisolated final class IRCConnection: Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "IRCConnection")

    init(host: String, port: UInt16, useTLS: Bool) {
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port) ?? .any,
                                  using: useTLS ? .tls : .tcp)
    }

    /// Starts connecting and returns once the connection can carry data. Throws if it
    /// fails, or when `close()` is called first.
    ///
    /// A connection that can't be established yet (refused, no network, DNS failure) keeps
    /// waiting: Network.framework retries it, e.g. as soon as the network comes back, and
    /// the caller decides how long that may take. A rejected TLS handshake won't fix itself
    /// by retrying, so it fails right away.
    func open() async throws {
        let (states, continuation) = AsyncStream.makeStream(of: NWConnection.State.self)
        connection.stateUpdateHandler = { continuation.yield($0) }
        // Nothing listens once this returns; later states are dropped rather than buffered.
        defer { continuation.finish() }
        connection.start(queue: queue)
        for await state in states {
            switch state {
            case .ready: return
            case .failed(let error): throw error
            case .waiting(let error): if case .tls = error { throw error }
            case .cancelled: throw CancellationError()
            case .setup, .preparing: continue
            @unknown default: continue
            }
        }
        throw CancellationError()
    }

    /// The next chunk of bytes from the server, or nil once the server has closed the
    /// stream. Throws when the connection fails or is closed.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)   // any end of stream shows up on the next call
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    /// Queues bytes for sending. Sends go out in call order; `completion` gets the error
    /// if the bytes couldn't be written.
    func send(_ data: Data, completion: @escaping @Sendable (NWError?) -> Void) {
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    /// Tears the connection down immediately. Pending and later `open`/`receive` calls throw.
    func close() {
        connection.cancel()
    }
}
