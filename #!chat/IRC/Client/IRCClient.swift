//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-nio-irc open source project
//
// Copyright (c) 2018-2024 ZeeZide GmbH. and the swift-nio-irc project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIOIRC project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIO
#if canImport(NIOSSL)
@preconcurrency import NIOSSL
#endif
#if canImport(Network)
import Network
#endif

    #if canImport(NIOTransportServices)
      import NIOTransportServices
    #endif

/**
 * A simple IRC client based on SwiftNIO.
 *
 * Checkout swift-nio-irc-eliza or swift-nio-irc-webclient for examples on this.
 *
 * The basic flow is:
 * - create a `IRCClient` object, quite likely w/ custom `IRCClientOptions`
 * - implement and assign an `IRCClientDelegate`, which is going to handle
 *   incoming commands
 * - `connect` the client
 */
open class IRCClient : IRCClientMessageTarget {
  
  public let options   : IRCClientOptions
  public let eventLoop : EventLoop
  public weak var delegate  : IRCClientDelegate?
  /// The app's server identifier for this connection (set by IRCConnectionService),
  /// giving an O(1) client -> serverID mapping with no staleness.
  public var serverID  : UUID?
  
  public enum Error : Swift.Error {
    case writeError(Swift.Error)
    case stopped
    case notImplemented
    case internalInconsistency
    case unexpectedInput
    case channelError(Swift.Error)
  }

  /// Simplified public connection state for external observers.
  /// This hides internal details like CAP negotiation phases.
  public enum ConnectionState: Equatable, CustomStringConvertible {
    case disconnected
    case connecting
    case connected(nick: String)

    public var description: String {
      switch self {
      case .disconnected: return "disconnected"
      case .connecting: return "connecting"
      case .connected(let nick): return "connected(\(nick))"
      }
    }
  }

  enum State : CustomStringConvertible {
    case disconnected
    case connecting
    case capNegotiating(channel: Channel, nick: IRCNickName, userInfo: IRCUserInfo)
    case registering(channel: Channel, nick: IRCNickName, userInfo: IRCUserInfo)
    case registered (channel: Channel, nick: IRCNickName, userInfo: IRCUserInfo)

    var isRegistered : Bool {
      switch self {
        case .registered: return true
        default:          return false
      }
    }

    var nick : IRCNickName? {
      @inline(__always) get {
        switch self {
          case .capNegotiating(_, let v, _): return v
          case .registering(_, let v, _): return v
          case .registered (_, let v, _): return v
          default: return nil
        }
      }
    }

    var userInfo : IRCUserInfo? {
      @inline(__always) get {
        switch self {
          case .capNegotiating(_, _, let v): return v
          case .registering(_, _, let v): return v
          case .registered (_, _, let v): return v
          default: return nil
        }
      }
    }

    var channel : Channel? {
      @inline(__always) get {
        switch self {
          case .capNegotiating(let channel, _, _): return channel
          case .registering(let channel, _, _): return channel
          case .registered (let channel, _, _): return channel
          default: return nil
        }
      }
    }

    var canStartConnection : Bool {
      switch self {
        case .disconnected:    return true
        case .connecting:      return false
        case .capNegotiating:  return false
        case .registering:     return false
        case .registered:      return false
      }
    }

    nonisolated var description : String {
      switch self {
        case .disconnected:                   return "disconnected"
        case .connecting:                     return "connecting..."
        case .capNegotiating(_, let nick, _): return "negotiating<\(nick.stringValue)>..."
        case .registering(_, let nick, _):    return "registering<\(nick.stringValue)>..."
        case .registered (_, let nick, _):    return "registered<\(nick.stringValue)>"
      }
    }
  }
  
  private var state : State = .disconnected {
    didSet { notifyConnectionStateChangeIfNeeded() }
  }
  private var lastNotifiedConnectionState: ConnectionState = .disconnected
  private var userMode = IRCUserMode()
  
  // CAP negotiation state
  private var availableCapabilities: Set<String> = []
  private var requestedCapabilities: Set<String> = []
  private var acknowledgedCapabilities: Set<String> = []
  private var capNegotiationInProgress = false
  private var capTimeoutTask: Scheduled<Void>?
  
  var usermask : String? {
    guard case .registered(_, let nick, let info) = state else { return nil }
    let host = info.servername ?? options.hostname ?? "??"
    return "\(nick.stringValue)!~\(info.username)@\(host)"
  }

  private let bootstrap : NIOClientTCPBootstrapProtocol
  
  public init(options: IRCClientOptions) {
    self.options = options
    
    let eventLoop = options.eventLoopGroup.next()
    self.eventLoop = eventLoop
  
    // what a mess :-)
    #if canImport(NIOTransportServices)
      #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        var overrideBootstrap : NIOClientTCPBootstrapProtocol?
        if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
          if options.eventLoopGroup is NIOTSEventLoopGroup {
            var tsBootstrap = NIOTSConnectionBootstrap(group: eventLoop)
            if options.useTLS {
              let tls = NWProtocolTLS.Options()
              // Set SNI if available
              if let host = options.hostname {
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
              }
              tsBootstrap = tsBootstrap.tlsOptions(tls)
            }
            overrideBootstrap = tsBootstrap
          }
        }
      #else
        let overrideBootstrap : NIOClientTCPBootstrapProtocol? = nil
      #endif
    #else
      let overrideBootstrap : NIOClientTCPBootstrapProtocol? = nil
    #endif
    
    self.bootstrap = overrideBootstrap ?? ClientBootstrap(group: eventLoop)

    _ = bootstrap.channelOption(ChannelOptions.reuseAddr, value: 1)
    
    _ = bootstrap.channelInitializer { [weak self] channel in
      var chain: EventLoopFuture<Void> = channel.eventLoop.makeSucceededFuture(())
      if let me = self, me.options.useTLS {
        #if canImport(NIOSSL)
        do {
          var config = TLSConfiguration.makeClientConfiguration()
          config.applicationProtocols = [ "irc", "ircv3", "h2", "http/1.1" ]
          let context  = try NIOSSLContext(configuration: config)
          let hostname = me.options.hostname
          // Note: NIOSSLClientHandler Sendable warning is a swift-nio-ssl library issue
          // that will be resolved when the library updates for Swift 6
          let handler  = try NIOSSLClientHandler(context: context,
                                                 serverHostname: hostname)
          chain = channel.pipeline.addHandler(handler, position: .first)
        }
        catch {
          let p = channel.eventLoop.makePromise(of: Void.self)
          p.fail(error)
          return p.futureResult
        }
        #endif
      }
      return chain
        .flatMap {
          channel.pipeline
            .addHandler(IRCChannelHandler(),
                        name: "de.zeezide.nio.irc.protocol")
        }
        .flatMap { [weak self] _ in
          guard let me = self else {
            let error = channel.eventLoop.makePromise(of: Void.self)
            error.fail(Error.internalInconsistency)
            return error.futureResult
          }
          return channel.pipeline
            .addHandler(Handler(client: me),
                        name: "de.zeezide.nio.irc.client")
        }
    }
  }
  deinit {
    // Safely capture the channel reference to avoid simultaneous access
    let currentState = state
    switch currentState {
    case .registered(let channel, _, _), .registering(let channel, _, _), .capNegotiating(let channel, _, _):
      channel.eventLoop.execute {
        channel.close(mode: .all, promise: nil)
      }
    default:
      break
    }
  }
  
  
  // MARK: - Commands
  
  open func changeNick(_ nick: IRCNickName) {
    send(.NICK(nick))
  }

  
  // MARK: - Connect
  
  var retryInfo = IRCRetryInfo()
  var channel : Channel? { @inline(__always) get { return state.channel } }

  /// Returns true if the connection is active and can send/receive data
  public var isActive: Bool {
    guard let channel = self.channel else { return false }
    return channel.isActive
  }

  /// Returns true if the client is fully registered and can send messages.
  /// This is more reliable than `isActive` because it explicitly checks the registration state.
  public var canSend: Bool {
    guard case .registered(let channel, _, _) = state else { return false }
    return channel.isActive
  }

  /// The current connection state, derived from the internal state machine.
  /// This is the single source of truth for connection state.
  public var connectionState: ConnectionState {
    switch state {
    case .disconnected:
      return .disconnected
    case .connecting, .capNegotiating, .registering:
      return .connecting
    case .registered(_, let nick, _):
      return .connected(nick: nick.stringValue)
    }
  }

  /// Notifies delegate if the public connection state has changed.
  private func notifyConnectionStateChangeIfNeeded() {
    let newState = connectionState
    guard newState != lastNotifiedConnectionState else { return }
    lastNotifiedConnectionState = newState
    delegate?.client(self, connectionStateChanged: newState)
  }

  open func connect() {
    guard eventLoop.inEventLoop else { return eventLoop.execute(self.connect) }
    
    guard state.canStartConnection else { return }
    _ = _connect(host: options.hostname ?? "localhost", port: options.port)
  }

  private func _connect(host: String, port: Int) -> EventLoopFuture<Channel> {
    assert(eventLoop.inEventLoop,    "threading issue")
    assert(state.canStartConnection, "cannot start connection!")
    
    clearListCollectors()
    userMode = IRCUserMode()
    state    = .connecting
    
    retryInfo.attempt += 1
    
    return bootstrap.connect(host: host, port: port)
      .map { channel in
        self.retryInfo.registerSuccessfulConnect()

        guard case .connecting = self.state else {
          print("WARNING: Expected connecting state in \(#function), but got: \(self.state)")
          return channel
        }

        // Start CAP negotiation to request server-time
        self.state = .capNegotiating(channel: channel,
                                     nick:     self.options.nickname,
                                     userInfo: self.options.userInfo)
        self._startCapNegotiation()
        return channel
      }
  }
  
  private func _startCapNegotiation() {
    assert(eventLoop.inEventLoop, "threading issue")

    guard case .capNegotiating(_, let nick, let user) = state else {
      print("WARNING: Expected cap negotiating state in \(#function), but got: \(state)")
      return
    }

    // Start IRCv3 capability negotiation
    capNegotiationInProgress = true
    availableCapabilities.removeAll()
    requestedCapabilities.removeAll()
    acknowledgedCapabilities.removeAll()

    // Set timeout for CAP negotiation (5 seconds)
    capTimeoutTask = eventLoop.scheduleTask(in: .seconds(5)) {
      self.capNegotiationTimeout()
    }

    // Per IRCv3 spec: Send CAP LS, then NICK/USER
    // Server will hold registration until we send CAP END
    send(.CAP(.LS, ["302"]))

    // Send PASS if needed (before NICK/USER per IRC spec)
    if let pwd = options.password {
      send(.otherCommand("PASS", [ pwd ]))
    }

    // Send NICK and USER - server needs these to respond to CAP
    send(.NICK(nick))
    send(.USER(user))
  }
  
  private func handleCapMessage(_ message: IRCMessage) -> Bool {
    guard case .CAP(let subcmd, let capIDs) = message.command else {
      return false
    }

    // Cancel timeout on first CAP response - server supports CAP
    capTimeoutTask?.cancel()
    capTimeoutTask = nil

    switch subcmd {
    case .LS:
      // Server lists available capabilities
      for cap in capIDs {
        // Strip any capability values (e.g., "sasl=PLAIN" -> "sasl")
        let capName = cap.split(separator: "=").first.map(String.init) ?? cap
        availableCapabilities.insert(capName)
      }

      // Build list of capabilities we want to request
      var capsToRequest: [String] = []

      // Request server-time if available (standard or ZNC variant)
      if availableCapabilities.contains("server-time") {
        capsToRequest.append("server-time")
      } else if availableCapabilities.contains("znc.in/server-time-iso") {
        capsToRequest.append("znc.in/server-time-iso")
      }

      // Request self-message for ZNC buffer playback (see your own sent messages)
      if availableCapabilities.contains("znc.in/self-message") {
        capsToRequest.append("znc.in/self-message")
      }

      if !capsToRequest.isEmpty {
        for cap in capsToRequest {
          requestedCapabilities.insert(cap)
        }
        send(.CAP(.REQ, capsToRequest))
      } else {
        // No capabilities we want, end negotiation
        send(.CAP(.END, []))
        proceedToRegistration()
      }

    case .ACK:
      // Server acknowledges requested capabilities
      for cap in capIDs {
        acknowledgedCapabilities.insert(cap)
      }

      // End CAP negotiation
      send(.CAP(.END, []))
      proceedToRegistration()

    case .NAK:
      // Server rejects requested capabilities
      send(.CAP(.END, []))
      proceedToRegistration()

    default:
      break
    }

    return true
  }
  
  private func capNegotiationTimeout() {
    guard case .capNegotiating = state else { return }
    proceedToRegistration()
  }

  private func proceedToRegistration() {
    guard case .capNegotiating(let channel, let nick, let user) = state else {
      print("WARNING: proceedToRegistration called but not in cap negotiating state: \(state)")
      return
    }

    // Cancel timeout (may already be cancelled, but make sure)
    capTimeoutTask?.cancel()
    capTimeoutTask = nil

    capNegotiationInProgress = false
    // Move to registering state - NICK/USER were already sent during CAP negotiation
    // Server will now complete registration after receiving CAP END
    state = .registering(channel: channel, nick: nick, userInfo: user)
    // Don't call _register() - we already sent NICK/USER in _startCapNegotiation()
  }
  
  private func _register() {
    assert(eventLoop.inEventLoop, "threading issue")

    guard case .registering(_, let nick, let user) = state else {
      print("WARNING: Expected registering state in \(#function), but got: \(state)")
      return
    }

    if let pwd = options.password {
      send(.otherCommand("PASS", [ pwd ]))
    }

    send(.NICK(nick))
    send(.USER(user))
  }
  
  /// Immediately closes the connection and transitions to disconnected state.
  /// This ensures clean shutdown on errors - no lingering half-open states.
  private func closeImmediately() {
    assert(eventLoop.inEventLoop, "threading issue")

    // Cancel any pending CAP timeout
    capTimeoutTask?.cancel()
    capTimeoutTask = nil

    // Grab channel before clearing state
    let channel = state.channel

    // Transition to disconnected
    state = .disconnected

    // Close the channel
    channel?.close(mode: .all, promise: nil)

    // Clean up
    clearListCollectors()
  }
  
  open func close() {
    guard eventLoop.inEventLoop else { return eventLoop.execute(close) }
    _ = channel?.close(mode: .all)
    clearListCollectors()
  }
  
  
  func handleRegistrationDone() {
    guard case .registering(let channel, let nick, let user) = state else {
      print("WARNING: Expected registering state in \(#function), but got: \(state)")
      return
    }
    
    state = .registered(channel: channel, nick: nick, userInfo: user)
    delegate?.client(self, registered: nick, with: user)
  }
  
  func handleRegistrationFailed(with message: IRCMessage) {
    guard case .registering(_, let nick, _) = state else {
      print("WARNING: Expected registering state in \(#function), but got: \(state)")
      return
    }
    print("ERROR: registration of \(nick) failed:", message)

    // Close cleanly, then notify delegate
    closeImmediately()
    delegate?.clientFailedToRegister(self)
  }
  
  
  // MARK: - List Collectors
  
  var messageOfTheDay = ""
  
  func clearListCollectors() {
    messageOfTheDay = ""
  }
  
  
  // MARK: - Handler Delegate
  
  func handlerDidDisconnect(_ context: ChannelHandlerContext) { // Q: own
    switch state {
      case .disconnected:
        // Already disconnected, nothing to do
        break
      case .capNegotiating, .registering, .connecting:
        state = .disconnected
        delegate?.clientFailedToRegister(self)
      case .registered:
        state = .disconnected
        delegate?.clientDidDisconnect(self)
    }
  }
  
  func handlerHandleResult(_ message: IRCMessage) { // Q: own

    // Handle CAP negotiation messages before anything else
    if case .capNegotiating(let channel, let nick, let user) = state {
      if handleCapMessage(message) {
        return  // Message was handled by CAP negotiation, don't process further
      }

      // Server might not support CAP and just proceed with registration
      // Check if we received a registration success message
      if message.command.signalsSuccessfulRegistration {
        capTimeoutTask?.cancel()
        capTimeoutTask = nil
        capNegotiationInProgress = false
        state = .registered(channel: channel, nick: nick, userInfo: user)
        delegate?.client(self, registered: nick, with: user)
        return
      }

      // Handle registration errors during CAP negotiation
      if case .numeric(.errorNicknameInUse, _) = message.command {
        print("Registration failed: nickname in use")
        closeImmediately()
        delegate?.clientFailedToRegister(self)
        return
      }
      else if message.command.isErrorReply {
        print("Registration failed: \(message.command)")
        closeImmediately()
        delegate?.clientFailedToRegister(self)
        return
      }
    }

    if case .registering = state {
      if message.command.signalsSuccessfulRegistration {
        handleRegistrationDone()
      }

      if case .numeric(.errorNicknameInUse, _) = message.command {
        print("NEEDS NEW NICK!")
        // TODO: recover using a callback
        return handleRegistrationFailed(with: message)
      }
      else if message.command.isErrorReply {
        return handleRegistrationFailed(with: message)
      }
    }

    do {
      try irc_msgSend(message)
    }
    catch let error as IRCDispatcherError {
      // TBD:
      print("handle dispatcher error:", error)
    }
    catch {
      // TBD:
      print("handle generic error:", type(of: error), error)
    }

  }
  
  func handlerCaughtError(_ error: Swift.Error,
                          in context: ChannelHandlerContext) // Q: own
  {
    retryInfo.lastSocketError = error
    print("IRCClient error:", error)

    // Determine if we were registered before the error
    let wasRegistered = state.isRegistered

    // Close immediately - no lingering error state
    closeImmediately()

    // Notify delegate appropriately
    if wasRegistered {
      delegate?.clientDidDisconnect(self)
    } else {
      delegate?.clientFailedToRegister(self)
    }
  }
  
  
  // MARK: - Handler
  
  final class Handler : ChannelInboundHandler {
    
    typealias InboundIn = IRCMessage
    
    let client : IRCClient
    
    init(client: IRCClient) {
      self.client = client
    }
    
    func channelActive(context: ChannelHandlerContext) {
    }
    func channelInactive(context: ChannelHandlerContext) {
      client.handlerDidDisconnect(context)
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      let value = unwrapInboundIn(data)
      client.handlerHandleResult(value)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
      self.client.handlerCaughtError(error, in: context)
      context.close(promise: nil)
    }
  }

  
  // MARK: - Writing
  
  public var origin : String? { return nil }
  
  public func sendMessages<T: Collection>(_ messages: T,
                                          promise: EventLoopPromise<Void>?)
                where T.Element == IRCMessage
  {
    // TBD: this looks a little more difficult than necessary.
    guard let channel = channel else {
      promise?.fail(Error.stopped)
      return
    }
    
    guard channel.eventLoop.inEventLoop else {
      return channel.eventLoop.execute {
        self.sendMessages(messages, promise: promise)
      }
    }
    
    let count = messages.count
    if count == 0 {
      promise?.succeed(())
      return
    }
    if count == 1 {
      return channel.writeAndFlush(messages.first!, promise: promise)
    }
    
    guard let promise = promise else {
      for message in messages {
        channel.write(message, promise: nil)
      }
      return channel.flush()
    }
    
    EventLoopFuture<Void>
      .andAllSucceed(messages.map { channel.write($0) },
                     on: promise.futureResult.eventLoop)
      .cascade(to: promise)
    channel.flush()
  }
}

extension ChannelOptions {
  
  static let reuseAddr =
    ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET),
                          SO_REUSEADDR)
  
}

extension IRCCommand {
  
  var isErrorReply : Bool {
    guard case .numeric(let code, _) = self else { return false }
    return code.rawValue >= 400 // Hmmm
  }
  
  var signalsSuccessfulRegistration : Bool {
    switch self {
      case .MODE: return true // Freenode sends a MODE
      case .numeric(let code, _):
        switch code {
          case .replyWelcome, .replyYourHost, .replyMotD, .replyEndOfMotD:
            return true
          default:
            return false
        }

      default: return false
    }
  }
  
}

extension IRCClient : IRCDispatcher {

  public func irc_msgSend(_ message: IRCMessage) throws {
    // Handle NICK and QUIT BEFORE the dispatcher to prevent doNick() being called for other users
    switch message.command {
      case .NICK(let newNick):
        guard let origin = message.origin, let user = IRCUserID(origin) else {
          return print("ERROR: NICK is missing a proper origin:", message)
        }
        // Check if this is us changing our nick or someone else
        if let myNick = state.nick, myNick == user.nick {
          // It's us - update our state and notify
          try? doNick(newNick)
        } else {
          // It's someone else - notify delegate
          delegate?.client(self, user: user, changedNickTo: newNick)
        }
        return  // Don't let dispatcher handle this

      case .QUIT(let quitMessage):
        guard let origin = message.origin, let user = IRCUserID(origin) else {
          return print("ERROR: QUIT is missing a proper origin:", message)
        }
        delegate?.client(self, userQuit: user, message: quitMessage)
        return  // Don't let dispatcher handle this

      default:
        break  // Let dispatcher handle everything else
    }

    do {
      return try irc_defaultMsgSend(message)
    }
    catch let error as IRCDispatcherError {
      guard case .doesNotRespondTo = error else { throw error }
    }
    catch { throw error }

    switch message.command {
      /* Message of the Day coalescing */
      case .numeric(.replyMotDStart, let args):
        messageOfTheDay = (args.last ?? "") + "\n"
      case .numeric(.replyMotD, let args):
        messageOfTheDay += (args.last ?? "") + "\n"
      case .numeric(.replyEndOfMotD, _):
        if !messageOfTheDay.isEmpty {
          delegate?.client(self, messageOfTheDay: messageOfTheDay)
        }
        messageOfTheDay = ""
      
      // 353 (NAMES) and 366 (end-of-NAMES) are intentionally NOT handled here: they fall
      // through to the `default:` arm below, which forwards them to the delegate's
      // received(_:) so IRCConnectionService can build the channel member list.

      case .numeric(.replyTopic, let args):
        // :localhost 332 Guest31 #NIO :Welcome to #nio!
        guard args.count > 2, let channel = IRCChannelName(args[1]) else {
          return print("ERROR: topic args incomplete:", message)
        }
        delegate?.client(self, changeTopic: args[2], of: channel)

      /* join/part, we need the origin here ... (fix dispatcher) */
        
      case .JOIN(let channels, _):
        guard let origin = message.origin, let user = IRCUserID(origin) else {
          return print("ERROR: JOIN is missing a proper origin:", message)
        }
        delegate?.client(self, user: user, joined: channels)
      
      case .PART(let channels, let leaveMessage):
        guard let origin = message.origin, let user = IRCUserID(origin) else {
          return print("ERROR: PART is missing a proper origin:", message)
        }
        delegate?.client(self, user: user, left: channels, with: leaveMessage)

      /* NICK and QUIT are now handled before the dispatcher - see top of irc_msgSend */

      /* unexpected stuff */

      case .otherNumeric(let code, let args):
        #if false
          print("OTHER NUM:", code, args)
        #endif
        delegate?.client(self, received: message)

      default:
        #if false
          print("OTHER COMMAND:", message.command,
                message.origin ?? "-", message.target ?? "-")
        #endif
        delegate?.client(self, received: message)
    }
  }
  
  public func doNotice(recipients: [ IRCMessageRecipient ], message: String,
                       serverTime: Date?) throws
  {
    delegate?.client(self, notice: message, for: recipients, serverTime: serverTime)
  }

  public func doMessage(sender     : IRCUserID?,
                      recipients : [ IRCMessageRecipient ],
                      message    : String,
                      serverTime : Date?) throws
  {
    guard let sender = sender else { return }
    delegate?.client(self, message: message, from: sender, for: recipients, serverTime: serverTime)
  }

  public func doNick(_ newNick: IRCNickName) throws {
    switch state {
      case .registering(let channel, let nick, let info):
        guard nick != newNick else { return }
        state = .registering(channel: channel, nick: newNick, userInfo: info)
      
      case .registered(let channel, let nick, let info):
        guard nick != newNick else { return }
        state = .registered(channel: channel, nick: newNick, userInfo: info)

      default: return // hmm
    }
    
    delegate?.client(self, changedNickTo: newNick)
  }
  
  public func doMode(nick: IRCNickName, add: IRCUserMode, remove: IRCUserMode)
              throws
  {
    guard let myNick = state.nick, myNick == nick else {
      return
    }
    
    var newMode = userMode
    newMode.subtract(remove)
    newMode.formUnion(add)
    if newMode != userMode {
      userMode = newMode
      delegate?.client(self, changedUserModeTo: newMode)
    }
  }

  public func doPing(_ server: String, server2: String? = nil) throws {
    let msg : IRCMessage
    
    msg = IRCMessage(origin: origin, // probably wrong
                     command: .PONG(server: server, server2: server))
    sendMessage(msg)
  }
}
