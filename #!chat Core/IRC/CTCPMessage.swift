/// A CTCP message (Client-to-Client Protocol, https://modern.ircdocs.horse/ctcp.html): the
/// text of a PRIVMSG (a query or an ACTION) or a NOTICE (a reply) wrapped in `\u{1}`
/// delimiters, like `\u{1}ACTION waves\u{1}` for `/me waves`.
nonisolated struct CTCPMessage: Equatable, Sendable {
    /// The command, uppercased: `ACTION`, `VERSION`, `PING`, …
    var command: String
    /// Whatever follows the command and its space; nil when nothing does.
    var parameters: String?

    init(command: String, parameters: String? = nil) {
        self.command = command
        self.parameters = parameters
    }

    /// Reads a CTCP message from PRIVMSG or NOTICE text; nil when the text isn't one. As
    /// the spec asks, the closing delimiter is optional on input.
    init?(parsing text: String) {
        guard text.hasPrefix(Self.delimiter) else { return nil }
        var body = text.dropFirst()
        if body.hasSuffix(Self.delimiter) { body = body.dropLast() }
        let command = body.prefix { $0 != " " }
        guard !command.isEmpty else { return nil }
        let rest = body[command.endIndex...]
        self.init(command: command.uppercased(), parameters: rest.isEmpty ? nil : String(rest.dropFirst()))
    }

    /// The message as PRIVMSG or NOTICE text, delimiters included.
    var text: String {
        Self.delimiter + command + (parameters.map { " " + $0 } ?? "") + Self.delimiter
    }

    private static let delimiter = "\u{1}"
}
