import Foundation
import Network
import Security

/// One connection to an IRC server, as the app sees it: it opens the transport, splits what
/// arrives into lines, runs them through the protocol session, and reports the outcome to
/// `onEvent`. Everything happens on the main actor, so `nickname` and `isRegistered` can be
/// read at any time and always agree with the events delivered so far.
final class IRCClient {
    /// Receives every event in order. Not called again once the app calls `close()` or
    /// `quit()`, or after `registrationFailed` or `disconnected`.
    var onEvent: (IRCEvent) -> Void = { _ in }

    /// Our nickname: the one we registered with, or the one we're trying to register with.
    var nickname: String { session.nickname }
    var isRegistered: Bool { session.isRegistered }

    private let host: String
    private let port: Int
    private let useTLS: Bool
    private var session: IRCSession
    private var connection: IRCConnection?
    private var lineBuffer = IRCLineBuffer()
    private var isClosed = false

    init(host: String, port: Int, useTLS: Bool, nickname: String, password: String?) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        session = IRCSession(nickname: nickname, password: password)
    }

    /// Connects and registers. Events follow asynchronously, never from inside this call.
    func connect() {
        precondition(connection == nil, "IRCClient.connect() called twice")
        guard let port = UInt16(exactly: port), port > 0 else {
            Task { finish(reason: "Invalid port \(self.port)") }
            return
        }
        let connection = IRCConnection(host: host, port: port, useTLS: useTLS)
        self.connection = connection
        Task { await run(connection) }
    }

    /// Sends a message to the server. A failed write ends the connection with `disconnected`.
    func send(_ message: IRCMessage) {
        guard !isClosed, let connection else { return }
        connection.send(Self.encode(message)) { error in
            guard let error else { return }
            Task { @MainActor in self.finish(reason: Self.describe(error)) }
        }
    }

    /// Leaves the server politely with QUIT, then closes the connection. No events follow.
    func quit() {
        guard isRegistered, !isClosed, let connection else {
            close()
            return
        }
        isClosed = true
        connection.send(Self.encode(.quit())) { _ in connection.close() }
    }

    /// Drops the connection immediately, without a word to the server. No events follow.
    func close() {
        isClosed = true
        connection?.close()
    }

    // MARK: - Connection lifetime

    private func run(_ connection: IRCConnection) async {
        guard !isClosed else { return }   // closed before the connection even started
        do {
            try await connection.open()
            guard !isClosed else { return }
            session.registrationMessages().forEach(send)

            while let bytes = try await connection.receive() {
                for line in try lineBuffer.append(bytes) {
                    guard !isClosed else { return }
                    receive(line)
                }
            }
            finish(reason: "The server closed the connection")
        } catch {
            finish(reason: Self.describe(error))
        }
    }

    private func receive(_ line: String) {
        onEvent(.lineReceived(line))
        guard let message = IRCMessage(line) else { return }
        let output = session.handle(message)
        output.replies.forEach(send)
        for event in output.events {
            guard !isClosed else { return }
            if case .registrationFailed = event { close() }   // nothing more to do on this connection
            onEvent(event)
        }
    }

    /// Ends the connection on its own terms (refused, dropped, closed by the server, failed
    /// write) and reports it, unless the app already closed it. The server's own explanation,
    /// when it gave one, beats what the socket saw.
    private func finish(reason: String) {
        guard !isClosed else { return }
        close()
        onEvent(.disconnected(reason: session.closingReason ?? reason))
    }

    private static func encode(_ message: IRCMessage) -> Data {
        Data((message.wireFormat + "\r\n").utf8)
    }

    /// A short reason for a connection error, like "Connection refused".
    private static func describe(_ error: any Error) -> String {
        switch error {
        case NWError.posix(let code):
            String(cString: strerror(code.rawValue))
        case NWError.dns:
            "Server not found"
        case NWError.tls(let status):
            "TLS: " + (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
        case is IRCLineBuffer.LineTooLong:
            "The server sent an overlong line"
        default:
            "\(error)"
        }
    }
}
