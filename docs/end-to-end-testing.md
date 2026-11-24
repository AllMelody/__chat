# End-to-end testing

Use this when a change needs checking in the running app, beyond the compile and test checks in `CLAUDE.md`. It builds and launches copies of the app with `xcodebuild`. On a machine where the project isn't built from the command line, stop at the `CLAUDE.md` checks and ask the user to try the change.

## Testing a copy

The installed app, Debug builds and the unit-test host all share the bundle ID `io.github.AllMelody.--chat`, and with it the sandbox container, saved servers and Keychain items. A Debug build launched as it is connects to the user's real servers, and the unit-test host reads the real Keychain. So every end-to-end run uses a copy with its own bundle ID:

1. **Make the copy:** rsync the repo, minus `.git`, into the scratchpad.
2. **Rename it:** change every `PRODUCT_BUNDLE_IDENTIFIER = "io.github.AllMelody.--chat"` in the copy's `project.pbxproj` to `io.github.AllMelody.chat-verify` with sed. A command-line override would also rename the test bundle.
3. **Run the unit tests in the copy too:** `xcodebuild -scheme '#!chat Mac' test`.
4. **Warn the user before launching:** on the Mac, a copy appears in the Dock with the same name and icon as the real app.
5. **Clean up afterwards:**
   - Run `lsregister -u` on each Mac copy.
   - Delete the chat-verify container's `Data` folder. The container folder itself and its metadata can't be removed from the shell.

## Mac harness

- **Hook it in:** add a throwaway harness `.swift` file to the copy's `#!chat Mac/` (the synchronized folder picks it up) and call it from `ChatApp.init`. Turn off `NotificationService`'s `requestAuthorization` in the copy. Launch with `open -g -n --env HARNESS=1 <app>`.
- **Drive it from inside:** the shell has no Accessibility or Screen Recording permission, and asking for either would put a prompt on the user's screen. Type into the composer through its field editor (paste, then `doCommand(by: #selector(NSResponder.insertNewline(_:)))`), and pause about 0.3 s after each Return so SwiftUI clears the draft. Type line breaks as `⏎`, because a raw `\n` inserted into the one-line composer becomes a space.
- **Record state as text:** `cacheDisplay` and `layer.render` miss the log's `NSTextView`.
- **Wait for sends:** a sent line can sit in the flood queue for a while. Wait for it to appear in the log before relying on it.
- **Passwords:** to give a harness server a password without touching the Keychain, add the server with `password: nil`, then set `server.password` in memory.
- **Output:** the sandboxed copy can only write to its container's temp folder. The harness can report over TCP to a sink next to the fake server instead.
- **Logs:** use `/usr/bin/log show`, because in zsh `log` is a builtin.

## Fake servers

- **Fake ircd:** a small asyncio server, run with `uv run --no-project python`, that logs what the client sends.
- **Bouncer replay:** a fake bouncer that:
  - offers `server-time` and `znc.in/self-message`, and stamps PRIVMSGs with `@time`;
  - keeps each channel's lines, including what the client sends, and replays them on every JOIN;
  - can drop the connection after storing some "while away" lines.

  Check the fake's own log to confirm it really replayed. Keep its control files to plain values like `#test 3`, because a stray word silently kills its control loop.

## A physical iPhone

Ask the user before each phone session. The phone has to be unlocked and ready, so a run started without warning fails. Signing follows `CLAUDE.md`: the team goes on the `xcodebuild` command line only.

- **Build and install:** build signed in the scratchpad and install with `xcrun devicectl device install app`, not the deploy script. That way the app isn't launched normally, and doesn't connect to IRC, on every iteration. Delete the signed build afterwards. At the end, remove the harness and deploy with the script.
- **Unlocked phone:** check `xcrun devicectl device info lockState` first, because launching on a locked phone hangs.
- **Harness:** keep the real bundle ID, and start the harness from `ChatApp.init` only when the app is launched with `devicectl device process launch --terminate-existing -e '{"HARNESS":"1"}'`. Set `isIdleTimerDisabled` so the phone stays awake.
- **Test data:**
  - Gate `ChatStore`'s auto-connect on the same variable, so test launches stay offline.
  - Fill the first server's in-memory `log` with made-up lines.
  - Make test conversations with `getOrCreatePrivateConversation(with:)`. Private conversations aren't persisted, while servers and channels are, so the harness creates only private conversations.
- **Commands in:** send them with `devicectl device copy to --domain-type appDataContainer --domain-identifier <bundle id> --source <file> --destination tmp/cmd`, and have the harness poll for them. End each command file with a terminator line, and have the harness wait for it. A "Failed to retrieve the file node for tmp/cmd" message after the app has taken the file is harmless.
- **Log out:** append to `tmp/dbg.log` and fetch it with `copy from`. `launch --console` breaks as soon as the app is suspended.
- **Screenshots:** run `devicectl device capture screenshot --display-unique-id <id>`, with the ids from `devicectl device info displays`. On a foldable, the unfolded inner screen isn't the primary display. Screen recording isn't supported.
- **Taps:**
  - *Bar buttons:* hit-test the `_UIButtonBarButton` under a point and call `sendActions(for: .touchUpInside)`. Changing `columnVisibility` in code doesn't take the same path as the sidebar button.
  - *Opening a conversation:* do what a row tap does. Call `selectItem(at:…)`, then `delegate?.collectionView?(_:didSelectItemAt:)`, on the sidebar's `UICollectionView`. It has one section per server, and each section's rows are the server, its channels, then its private conversations.
  - *The composer:* focus it with `becomeFirstResponder()` on the `UITextView` that backs its SwiftUI `TextField` (UIKit's `VerticalTextView`).
  - *Scrolling:* setting `contentOffset` isn't a user scroll as far as SwiftUI is concerned, so ask the user to do the drags.
- **Watching animations:**
  - *Slow motion:* `window.layer.speed = 0.04` slows UIKit animations 25 times, enough to screenshot mid-animation. `layer.presentation()` and `animationKeys()` show what UIKit is animating.
  - *What animates, and inside whose animation:* a `CADisplayLink` probe that logs each `UIScrollView`'s `bounds.origin`, its presentation value, `adjustedContentInset` and `layer.animation(forKey:)` (from, to, duration), together with the keyboard notifications. A 0.5 s animation is the navigation push or pop, and 0.35 to 0.38 s is the keyboard.
