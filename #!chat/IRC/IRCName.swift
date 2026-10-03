import Foundation

/// IRC naming rules: nickname syntax, channel names, and case-insensitive comparison.
nonisolated enum IRCName {
    /// Whether `name` can be a nickname (RFC 2812 §2.3.1): a letter or one of `[]\`_^{|}`,
    /// then any of those, digits, or `-`. Relaxed where servers differ and have the final
    /// say anyway: letters and digits may be non-ASCII, a digit may come first, and there's
    /// no length limit.
    static func isValidNickname(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        return nicknameStart.contains(first) && name.unicodeScalars.dropFirst().allSatisfy(nicknameRest.contains)
    }

    private static let nicknameStart = CharacterSet.letters
        .union(.decimalDigits)
        .union(CharacterSet(charactersIn: "[]\\`_^{|}"))
    private static let nicknameRest = nicknameStart.union(CharacterSet(charactersIn: "-"))

    /// True when `target` names a channel rather than a user: it starts with one of the
    /// channel prefixes of RFC 2812 §1.3 (`#` network-wide, `&` server-local, `+` modeless,
    /// `!` safe).
    static func isChannel(_ target: some StringProtocol) -> Bool {
        target.first.map { "#&+!".contains($0) } ?? false
    }

    /// Whether two names are the same to the server, under the RFC 1459 case mapping that
    /// servers use by default: ASCII letters fold, and so do `[]\^`, the "uppercase" forms
    /// of `{}|~`.
    static func equal(_ a: some StringProtocol, _ b: some StringProtocol) -> Bool {
        a.utf8.elementsEqual(b.utf8) { folded($0) == folded($1) }
    }

    /// `A`…`^` (0x41–0x5E: the letters plus `[\]^`) sit exactly 0x20 below their lowercase
    /// forms `a`…`~`.
    private static func folded(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "^")).contains(byte) ? byte + 0x20 : byte
    }
}
