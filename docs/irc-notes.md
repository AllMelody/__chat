# IRC notes

## Own messages and the bouncer

ZNC's source (`CClient::EchoMessage` in `src/Client.cpp`) shows what comes back to the client:

- **This client's own lines:** ZNC sends a client's PRIVMSG back to that same client only if the client negotiated IRCv3 `echo-message`, and #!chat doesn't request it.
- **Lines from the user's other clients:** `znc.in/self-message` makes ZNC relay the private messages they send. Their channel messages are relayed regardless.
- **Lines sent while attached:** with ZNC's defaults (`AutoClearChanBuffer` and `AutoClearQueryBuffer` both true), they aren't buffered, so they aren't replayed on reconnect either.

Backlog that a bouncer replays on reconnect is matched against the log for channels and private conversations alike (`ReplayCutoff`, `ChatStore.isReplayOfLogged`, bc360d9). A replayed line of our own is matched to the line we logged by its text, within `ReplayCutoff.clockTolerance`, because the bouncer stamps it with its own clock.

So own private messages don't show twice. Reviews have twice reported missing private-message de-duplication, and both reports were wrong for the reasons above.

## Known gaps

- **RPL_ISUPPORT (005):** `IRCSession` uses only `STATUSMSG`. Everything else assumes defaults:
  - `IRCName.isChannel` assumes `#&+!` for CHANTYPES.
  - `IRCName.equal` always uses rfc1459 for CASEMAPPING.
  - `IRCSession.memberStatusPrefixes` assumes `~&@%+` for PREFIX.

  Clients should use the advertised values, and the documented defaults until a server advertises them (modern.ircdocs.horse). `IRCName` also serves the app (the join sheet, `/join`, nick validation), where no server is at hand, so a fix has to decide what those use.
- **`/msg @#chan text`:** the message reaches the channel's ops, but `IRCConnectionService.sendMessageToTarget` also opens a private-conversation window named "@#chan", because `IRCName.isChannel("@#chan")` is false.
