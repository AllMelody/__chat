//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-nio-irc open source project
//
// Copyright (c) 2018-2021 ZeeZide GmbH. and the swift-nio-irc project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIOIRC project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

/**
 * An IRC message
 *
 * An optional origin, an optional target and the actual command (including its
 * arguments).
 */
nonisolated public struct IRCMessage : Codable, CustomStringConvertible, Sendable {

  public enum CodingKeys: String, CodingKey {
    case origin, target, command, arguments, tags
  }

  @inlinable
  public init(origin: String? = nil, target: String? = nil,
              command: IRCCommand, tags: [String: String]? = nil)
  {
    self.origin  = origin
    self.target  = target
    self.command = command
    self.tags    = tags
  }

  /**
   * True origin of message. Do not set in clients.
   *
   * Examples:
   * - `:helge55!~textual@213.211.198.125`
   * - `:helge99`
   * - `:cherryh.freenode.net`
   *
   * This is a server name or a nickname w/ user@host parts.
   */
  public var origin : String?

  public var target : String?

  /**
   * The IRC command and its arguments (max 15).
   */
  public var command : IRCCommand

  /**
   * IRCv3 message tags (e.g., server-time).
   */
  public var tags : [String: String]?

  /**
   * Returns the server-time from tags as a Date, if present.
   * Format: 2011-10-19T16:40:51.620Z (ISO 8601)
   */
  public var serverTime: Date? {
    guard let timeString = tags?["time"] else { return nil }
    // A malformed tag just means "no server time", hence the optional parse. IRCv3
    // specifies milliseconds, but accept timestamps without them too.
    return (try? Date(timeString, strategy: IRCMessage.iso8601WithFraction))
        ?? (try? Date(timeString, strategy: IRCMessage.iso8601))
  }

  private static let iso8601WithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let iso8601 = Date.ISO8601FormatStyle()

  @inlinable
  public var description: String {
    var ms = "<IRCMsg:"
    if let origin { ms += " from=\(origin)" }
    if let target { ms += " to=\(target)" }
    ms += " "
    ms += command.description
    ms += ">"
    return ms
  }
  
  
  // MARK: - Codable

  @inlinable
  public init(from decoder: Decoder) throws {
    let c       = try decoder.container(keyedBy: CodingKeys.self)
    let cmd     = try c.decode(String.self,              forKey: .command)
    let args    = try c.decodeIfPresent([ String ].self, forKey: .arguments)
    let command = try IRCCommand(cmd, arguments: args ?? [])
    
    self.init(origin: try c.decodeIfPresent(String.self, forKey: .origin),
              target: try c.decodeIfPresent(String.self, forKey: .target),
              command: command,
              tags: try c.decodeIfPresent([String: String].self, forKey: .tags))
  }
  @inlinable
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(origin,         forKey: .origin)
    try c.encodeIfPresent(target,         forKey: .target)
    try c.encode(command.commandAsString, forKey: .command)
    try c.encode(command.arguments,       forKey: .arguments)
    try c.encodeIfPresent(tags,           forKey: .tags)
  }
}
