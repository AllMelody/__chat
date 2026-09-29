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

nonisolated public struct IRCUserInfo : Equatable, Sendable {
  
  public let username   : String
  public let usermask   : IRCUserMode?
  public let hostname   : String?
  public let servername : String?
  public let realname   : String
  
  @inlinable
  public init(username: String, usermask: IRCUserMode, realname: String) {
    self.username   = username
    self.usermask   = usermask
    self.realname   = realname
    self.hostname   = nil
    self.servername = nil
  }
  @inlinable
  public init(username: String, hostname: String, servername: String,
              realname: String)
  {
    self.username   = username
    self.hostname   = hostname
    self.servername = servername
    self.realname   = realname
    self.usermask   = nil
  }
}

nonisolated extension IRCUserInfo : CustomStringConvertible {
  
  @inlinable
  public var description : String {
    var ms = "<IRCUserInfo: \(username)"
    if let v = usermask   { ms += " mask=\(v)" }
    if let v = hostname   { ms += " host=\(v)" }
    if let v = servername { ms += " srv=\(v)" }
    ms += " '\(realname)'"
    ms += ">"
    return ms
  }

}
