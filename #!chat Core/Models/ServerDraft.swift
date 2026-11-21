import Foundation

/// What the Add and Edit Server forms edit, and the checks they make before saving it.
struct ServerDraft {
    var name: String
    var host: String
    var port: String
    var password: String
    /// Turning encryption on or off moves the port between the usual TLS and plain ones.
    var useTLS: Bool {
        didSet {
            guard let p = Int(port) else { return }
            if useTLS && p == 6667 { port = "6697" }
            if !useTLS && p == 6697 { port = "6667" }
        }
    }
    var useSASL: Bool
    var autoConnectOnLaunch: Bool
    var nickname: String

    /// `server`'s settings, or a new server's: encrypted, on the usual TLS port. (Setting
    /// `useTLS` here doesn't swap the port: an initializer doesn't run didSet.)
    init(server: IRCServer?) {
        name = server?.name ?? ""
        host = server?.host ?? ""
        port = String(server?.port ?? 6697)
        password = server?.password ?? ""
        useTLS = server?.useTLS ?? true
        useSASL = server?.useSASL ?? false
        autoConnectOnLaunch = server?.autoConnectOnLaunch ?? false
        nickname = server?.nickname ?? ""
    }

    private var validPort: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var trimmedNick: String { nickname.trimmingCharacters(in: .whitespaces) }
    private var nickIsValid: Bool { trimmedNick.isEmpty || IRCName.isValidNickname(trimmedNick) }
    /// SASL logs the nickname in to its account with the password, so it needs both.
    private var saslIsComplete: Bool { !useSASL || (!trimmedNick.isEmpty && !password.isEmpty) }
    var canSave: Bool { !trimmedName.isEmpty && !trimmedHost.isEmpty && validPort != nil && nickIsValid && saslIsComplete }

    /// Saves the changes to `server`, or, without one, adds a new server.
    func save(editing server: IRCServer?, in store: ChatStore) {
        guard let p = validPort else { return }
        let pwd: String? = password.isEmpty ? nil : password
        let nick: String? = trimmedNick.isEmpty ? nil : trimmedNick
        if let server {
            store.updateServer(id: server.id, name: trimmedName, host: trimmedHost, port: p, password: pwd, useTLS: useTLS, useSASL: useSASL, autoConnectOnLaunch: autoConnectOnLaunch, nickname: nick)
        } else {
            store.addServer(name: trimmedName, host: trimmedHost, port: p, password: pwd, useTLS: useTLS, useSASL: useSASL, autoConnectOnLaunch: autoConnectOnLaunch, nickname: nick)
        }
    }
}
