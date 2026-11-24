# #!chat

A SwiftUI IRC client for the Mac and the iPhone, built on Network.framework with no third-party dependencies. It is minimal but native: few features, stock platform behavior. The repo is public.

## Layout

- `#!chat Core/` holds everything shared: the IRC engine (`IRC/`), models, services, and `ChatStore`. It is a synchronized folder compiled into **both** app targets. It is deliberately not a Swift package, so both apps' module is `__chat` and nothing needs `public`. Platform differences go through `Platform.swift` or `#if os(macOS)`.
- `#!chat Mac/` and `#!chat iOS/` hold each app's UI. Views with the same role share a name across the two apps (`ChatApp`, `ContentView`, `Sidebar`, …).
- `#!chat Core Tests/` uses Swift Testing with `@testable import __chat`, hosted in the Mac app.
- The IRC layer's `.privateMessage` (a PRIVMSG) is a different thing from the app's `IRCPrivateConversation` / `.privateConversation`.

Build settings that shape the code: Swift 5 language mode, `MainActor` default isolation, approachable concurrency, and `MemberImportVisibility` (app targets only, not the tests). Deployment targets are macOS 26 and iOS 27. The mismatch is deliberate, so keep both.

## Product decisions

These are settled. Build within them.

- **Scope:** no mIRC color or formatting rendering, and no DCC/XDCC. Prefer features that need little new UI and use stock AppKit/SwiftUI behavior. Ask before stripping formatting codes from messages.
- **No emoji** in anything the app says (log and status lines, errors, UI strings) or in code. For less prominence, use the secondary label color. Symbols with a job (`⏎`, `…`, `⌘`) are fine, and so are emoji used as test input.
- **The Mac's LimeChat look is frozen.** Mac changes are code quality and simplification that render identically. If a change would move any pixel, say exactly what and ask first. Keep the custom code the look depends on:
  - the log stays an `NSTextView`, because SwiftUI selection stops at each `Text`;
  - the composer stays the AppKit field, which draws pasted line breaks as a gray `⏎`;
  - thumbnails keep square corners.
- **The iPhone app** has its own stock UI (a `NavigationSplitView` sidebar), separate from the Mac's. It is iPhone only, no iPad. It runs in the foreground only and reconnects on return, so there is no push or background delivery. It may lag the Mac in features. Platform behavior is the default. When the user asks for a departure, keep it narrow and mark it with a short comment at the code. The navigation bar minimizes on scroll, as iOS does.
- **The iPhone log's** rows are `Text` with `.textSelection(.enabled)`, so a selection can cross messages. Its scrolling and keyboard handling were settled by measuring on a device and are load-bearing.

## IRC behavior and scope

- **Own lines** are logged as they are sent, and the app never requests IRCv3 `echo-message`. A message marked `isOwn` was sent from one of the user's other clients on the bouncer (`znc.in/self-message`) or is replayed backlog. It is never an echo of a line this client sent, so private messages need no echo de-duplication. The client is designed for a mostly-default ZNC.
- **CTCP** covers ACTION, PING and VERSION, and that is the complete set. CTCP flood protection is left to ZNC.
- **Nick collisions** fall back through `nick_`, `nick__` and `nick___`. The original nick is reclaimed only when the user asks.

Before reviewing or changing own-message handling, `IRCName`, or how ISUPPORT is parsed, read `docs/irc-notes.md`. It has the ZNC evidence and the known gaps.

## Checking a change from the command line

Work in a throwaway SwiftPM package in the session scratchpad that symlinks the repo's files. Prefix every command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, because the Command Line Tools lack the Swift Testing macros.

```sh
R="$PWD"; H=<scratchpad>/harness
mkdir -p "$H/Sources/__chat" "$H/Tests/ChatTests"
find "#!chat Core" "#!chat Mac" -name '*.swift' | while read -r f; do ln -s "$R/$f" "$H/Sources/__chat/$(echo "$f" | tr '/ ' '__')"; done
find "#!chat Core Tests" -name '*.swift' | while read -r f; do ln -s "$R/$f" "$H/Tests/ChatTests/$(basename "$f")"; done
```

`$H/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let common: [SwiftSetting] = [  // SWIFT_APPROACHABLE_CONCURRENCY, spelled out
    .swiftLanguageMode(.v5),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
]

let package = Package(
    name: "__chat",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "__chat", path: "Sources/__chat",
                swiftSettings: common + [.enableUpcomingFeature("MemberImportVisibility")]),
        .testTarget(name: "ChatTests", dependencies: ["__chat"], path: "Tests/ChatTests", swiftSettings: common),
    ]
)
```

1. **Mac app:** run `swift build` in `$H`.
2. **Tests:** delete the `#!chat_Mac_ChatApp.swift` link, because its `@main` clashes with the test runner's, then run `swift test`. `IRCClientTests` talk to a loopback fake server and are reliable.
3. **iPhone app:** from the repo root, type-check it against the iOS SDK inside Xcode. A clean run prints nothing and exits 0.
   ```sh
   find "#!chat Core" "#!chat iOS" -name '*.swift' -print0 | xargs -0 xcrun --sdk iphoneos swiftc -typecheck \
     -target arm64-apple-ios27.0 -module-name __chat -parse-as-library -swift-version 5 \
     -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault \
     -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature InferSendableFromCaptures \
     -enable-upcoming-feature GlobalActorIsolatedTypesUsability -enable-upcoming-feature DisableOutwardActorInference \
     -enable-upcoming-feature MemberImportVisibility
   ```

When reporting, say that these checks cover compilation and tests, not the running app. To check a change in the running app (a copy with its own bundle ID, a harness, fake servers, the phone), read `docs/end-to-end-testing.md`.

## Deploying

Deploy only when asked, using the gitignored `scripts/deploy-mac.sh` and `scripts/deploy-phone.sh` on machines that have them.

## Commits and publishing

- Commit directly on `main`, which has a linear history, and push only when asked.
- Every commit and every file carries one identity: `AllMelody <AllMelody@users.noreply.github.com>`. Confirm that `git config user.email` shows it before committing. Bundle IDs use the `io.github.AllMelody.` prefix.
- `project.pbxproj` carries no `DEVELOPMENT_TEAM`, because a team identifies its owner. A signing team goes on the `xcodebuild` command line only. Xcode's Signing settings would write it into the project. Check the project file for it before every commit.
- Commits Claude makes end with a blank line and `Co-Authored-By: Claude <model name> <noreply@anthropic.com>`. The user's own commits get none. When the session says to omit attribution, say so in one line and ask whether to add the trailer before committing.
