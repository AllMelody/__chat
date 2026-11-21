import Foundation
import Network
import Testing
@testable import __chat

/// Drives a real IRCClient against a scripted server on the loopback interface.
@Suite(.timeLimit(.minutes(1)))
struct IRCClientTests {
    @Test func `Registers, chats, and notices the server hanging up`() async throws {
        let server = try await FakeIRCServer()
        let (client, events) = makeClient(port: server.port)
        client.connect()
        try await server.accept()

        #expect(try await server.lines(3) == ["CAP LS 302", "NICK alice", "USER alice 0 * alice"])
        server.send(":srv CAP * LS :multi-prefix server-time")
        #expect(try await server.nextLine() == "CAP REQ server-time")
        server.send(":srv CAP * ACK :server-time")
        #expect(try await server.nextLine() == "CAP END")
        server.send(":srv 001 alice :Welcome to the test")
        #expect(await events.next() == .registered(nickname: "alice"))
        #expect(client.isRegistered)

        server.send("PING :keepalive")
        #expect(try await server.nextLine() == "PONG keepalive")

        client.send(.privateMessage(to: "#swift", "hello there"))
        #expect(try await server.nextLine() == "PRIVMSG #swift :hello there")
        server.send(":bob!u@h PRIVMSG #swift :hi alice")
        #expect(await events.next() == .channelMessage(channel: "#swift", .init(sender: "bob", text: "hi alice", isOwn: false, time: nil)))

        server.hangUp()
        #expect(await events.next() == .disconnected(reason: "The server closed the connection"))
    }

    @Test func `A rejected registration closes the connection`() async throws {
        let server = try await FakeIRCServer()
        let (client, events) = makeClient(port: server.port)
        client.connect()
        try await server.accept()
        _ = try await server.lines(3)

        server.send(":srv 464 * :Password incorrect")
        #expect(await events.next() == .registrationFailed(reason: "Password incorrect"))
        #expect(try await server.nextLine() == nil)   // the client hung up
    }

    @Test func `A taken nickname falls back to another`() async throws {
        let server = try await FakeIRCServer()
        let (client, events) = makeClient(port: server.port)
        client.connect()
        try await server.accept()
        _ = try await server.lines(3)

        server.send(":srv 433 * alice :Nickname is already in use")
        #expect(try await server.nextLine() == "NICK alice_")
        server.send(":srv 001 alice_ :Welcome")
        #expect(await events.next() == .registered(nickname: "alice_"))
        #expect(client.nickname == "alice_")
    }

    @Test func `The server's ERROR message explains the disconnect`() async throws {
        let server = try await FakeIRCServer()
        let (client, events) = makeClient(port: server.port)
        client.connect()
        try await server.accept()
        _ = try await server.lines(3)

        server.send("ERROR :Closing Link: 127.0.0.1 (K-Lined)")
        server.send("PING :sync")
        #expect(try await server.nextLine() == "PONG sync")   // the client has read the ERROR
        server.hangUp()
        #expect(await events.next() == .disconnected(reason: "Closing Link: 127.0.0.1 (K-Lined)"))
    }

    @Test func `Quit says goodbye before hanging up`() async throws {
        let server = try await FakeIRCServer()
        let (client, _) = makeClient(port: server.port)
        client.connect()
        try await server.accept()
        _ = try await server.lines(3)
        server.send(":srv 001 alice :Welcome")
        server.send("PING :sync")
        #expect(try await server.nextLine() == "PONG sync")   // the client has seen 001

        client.quit()
        #expect(try await server.nextLine() == "QUIT")
        #expect(try await server.nextLine() == nil)
    }

    @Test func `A failed TLS handshake is reported at once`() async throws {
        let server = try await FakeIRCServer()
        let (client, events) = makeClient(port: server.port, useTLS: true)
        client.connect()
        try await server.accept()

        server.send("NOTICE * :this server doesn't speak TLS")
        let event = await events.next()
        guard case .disconnected(let reason) = event else {
            Issue.record("Expected a disconnect, got \(String(describing: event))")
            return
        }
        #expect(reason.hasPrefix("TLS: "))
    }

    /// A client for `alice` whose events (apart from raw lines) are collected for the test.
    private func makeClient(port: UInt16, useTLS: Bool = false) -> (IRCClient, EventQueue) {
        let client = IRCClient(host: "127.0.0.1", port: Int(port), useTLS: useTLS, nickname: "alice", password: nil)
        let events = EventQueue()
        client.onEvent = { event in
            if case .lineReceived = event { return }
            events.continuation.yield(event)
        }
        return (client, events)
    }
}

final class EventQueue {
    let (stream, continuation) = AsyncStream.makeStream(of: IRCEvent.self)
    private lazy var iterator = stream.makeAsyncIterator()

    func next() async -> IRCEvent? {
        var iterator = self.iterator
        defer { self.iterator = iterator }
        return await iterator.next()
    }
}

/// Accepts one client on 127.0.0.1 and talks IRC lines with it.
final class FakeIRCServer {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let incoming = AsyncStream.makeStream(of: NWConnection.self)
    private var peer: NWConnection?
    private var buffer = IRCLineBuffer()
    private var pendingLines: [String] = []

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ports = AsyncStream.makeStream(of: UInt16.self)
        listener.stateUpdateHandler = { [listener] state in
            if case .ready = state, let port = listener.port { ports.continuation.yield(port.rawValue) }
        }
        listener.newConnectionHandler = { [incoming] in incoming.continuation.yield($0) }
        listener.start(queue: .main)
        port = await ports.stream.first { _ in true } ?? 0
    }

    deinit {
        peer?.cancel()
        listener.cancel()
    }

    func accept() async throws {
        let peer = try #require(await incoming.stream.first { _ in true })
        peer.start(queue: .main)
        self.peer = peer
    }

    func send(_ line: String) {
        peer?.send(content: Data((line + "\r\n").utf8), completion: .idempotent)
    }

    func hangUp() {
        peer?.cancel()
    }

    /// The next line from the client, or nil once it has closed the connection.
    func nextLine() async throws -> String? {
        while pendingLines.isEmpty {
            guard let peer, let data = await Self.receive(from: peer) else { return nil }
            pendingLines += try buffer.append(data)
        }
        return pendingLines.removeFirst()
    }

    func lines(_ count: Int) async throws -> [String?] {
        var lines: [String?] = []
        for _ in 0..<count { lines.append(try await nextLine()) }
        return lines
    }

    private static func receive(from peer: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            peer.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
    }
}
