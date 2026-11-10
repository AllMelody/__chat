# #!chat

A native macOS IRC client built with SwiftUI and Network.framework.

## Features

- Compact UI
- Multiple servers, each with its own nickname
- Channels and private messages
- Auto-reconnect with backoff
- Passwords stored in the macOS Keychain
- Inline image thumbnails
- Flood-protected send queue
- Multi-line composer with channel topics
- Some slash commands (`/join`, `/part`, `/nick`, `/msg`, …); start a message with `//` to send a leading `/`

## Building

Open `#!chat.xcodeproj` in Xcode 26+ and Run. There are no third-party dependencies.

Debug builds keep the sandbox's incoming-connections entitlement, which only the unit tests use: they run a loopback IRC server inside the app. Release builds don't have it.

## Notes

- Heavily inspired by [LimeChat](https://github.com/psychs/limechat) by Satoshi Nakagawa.
- Earlier versions ran on an IRC engine adapted from swift-nio-irc by ZeeZide GmbH. Thanks to its authors; `#!chat/IRC` has since been rewritten from scratch.
- Almost all of the code was written by Claude by Anthropic.

## License

MIT © 2026 All Melody — see [LICENSE](LICENSE).
