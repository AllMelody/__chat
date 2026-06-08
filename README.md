# #!chat

A native macOS IRC client built with SwiftUI and SwiftNIO.

## Features

- Compact UI
- Multiple servers, each with its own nickname
- Channels and private messages
- Auto-reconnect with backoff
- Passwords stored in the macOS Keychain
- Inline image thumbnails
- Flood-protected send queue
- Multi-line composer with channel topics
- Some slash commands (`/join`, `/part`, `/nick`, `/msg`, …)

## Building

Open `#!chat.xcodeproj` in Xcode 16+ and Run. Dependencies resolve via Swift Package Manager.

## Notes

- Heavily inspired by, basically a ripoff of, [LimeChat](https://github.com/psychs/limechat) by Satoshi Nakagawa.
- The `#!chat/IRC/NIOIRC` engine is a partial rewrite of swift-nio-irc by ZeeZide GmbH (Apache-2.0); those files keep their original headers.
- Almost all of the code was written by Claude by Anthropic.

## License

MIT © 2026 All Melody — see [LICENSE](LICENSE). The `IRC/NIOIRC` sources remain Apache-2.0.
