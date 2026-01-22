//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-nio-irc open source project
//
// Copyright (c) 2018 ZeeZide GmbH. and the swift-nio-irc project authors
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
 * Delegate methods called by `IRCClient` upon receiving IRC commands.
 */
public protocol IRCClientDelegate {
  
  func client(_ client        : IRCClient,
              registered nick : IRCNickName,
              with   userInfo : IRCUserInfo)

  func clientFailedToRegister(_ client: IRCClient)
  func clientDidDisconnect(_ client: IRCClient)

  /// Called when the connection state changes.
  /// This is the primary way to observe connection state transitions.
  func client(_ client: IRCClient, connectionStateChanged state: IRCClient.ConnectionState)

  func client(_ client: IRCClient, received message: IRCMessage)

  func client(_ client: IRCClient, messageOfTheDay: String)
  func client(_ client: IRCClient, notice message:  String,
              for recipients: [ IRCMessageRecipient ],
              serverTime: Date?)
  func client(_ client: IRCClient,
              message: String, from user: IRCUserID,
              for recipients: [ IRCMessageRecipient ],
              serverTime: Date?)

  func client(_ client: IRCClient, changedUserModeTo mode: IRCUserMode)
  func client(_ client: IRCClient, changedNickTo     nick: IRCNickName)

  func client(_ client: IRCClient, user: IRCUserID, joined: [ IRCChannelName ])
  func client(_ client: IRCClient, user: IRCUserID, left:   [ IRCChannelName ],
              with: String?)

  // User changed their nickname (not us, someone else)
  func client(_ client: IRCClient, user: IRCUserID, changedNickTo newNick: IRCNickName)
  // User quit IRC entirely (removes them from all channels on the server)
  func client(_ client: IRCClient, userQuit user: IRCUserID, message: String?)
  
  func client(_ client: IRCClient,
              changeTopic: String, of channel: IRCChannelName)
}


// MARK: - Default No-Op Implementations

public extension IRCClientDelegate {
  
  func client(_ client: IRCClient, registered nick: IRCNickName,
              with userInfo: IRCUserInfo) {}
  func client(_ client: IRCClient, received message: IRCMessage) {}

  func clientFailedToRegister(_ client: IRCClient) {}
  func clientDidDisconnect(_ client: IRCClient) {}
  func client(_ client: IRCClient, connectionStateChanged state: IRCClient.ConnectionState) {}

  func client(_ client: IRCClient, messageOfTheDay: String) {}
  func client(_ client: IRCClient,
              notice message: String,
              for recipients: [ IRCMessageRecipient ],
              serverTime: Date?) {}
  func client(_ client: IRCClient,
              message: String, from sender: IRCUserID,
              for recipients: [ IRCMessageRecipient ],
              serverTime: Date?) {}
  func client(_ client: IRCClient, changedUserModeTo mode: IRCUserMode) {}
  func client(_ client: IRCClient, changedNickTo nick: IRCNickName) {}

  func client(_ client: IRCClient,
              user: IRCUserID, joined channels: [ IRCChannelName ]) {}
  func client(_ client: IRCClient,
              user: IRCUserID, left   channels: [ IRCChannelName ],
              with message: String?) {}
  func client(_ client: IRCClient,
              user: IRCUserID, changedNickTo newNick: IRCNickName) {}
  func client(_ client: IRCClient,
              userQuit user: IRCUserID, message: String?) {}
  func client(_ client: IRCClient,
              changeTopic: String, of channel: IRCChannelName) {}
}

