import SwiftUI

/// The Settings window: a standard preferences form, labels on the left and controls on the
/// right, in a window just big enough to hold it.
struct SettingsView: View {
    @Environment(AppPreferences.self) private var prefs
    @Environment(ChatStore.self) private var store

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            LabeledContent("Lines to keep in log:") {
                HStack(spacing: 4) {
                    TextField("Lines to keep in log", value: $prefs.maxLogLines, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Stepper("Lines to keep in log", value: $prefs.maxLogLines, in: 1...100000)
                        .labelsHidden()
                }
            }
            // Related checkboxes share a label and sit close together; groups get a little air.
            LabeledContent("Show:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Image thumbnails", isOn: $prefs.showImageThumbnails)
                    Toggle("Joins, parts and quits in channels", isOn: $prefs.showJoinsAndParts)
                }
            }
            .padding(.top, 6)
            LabeledContent("Debug:") {
                Toggle("Log raw server traffic", isOn: $prefs.debugRawServerLog)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        // A fixed size is what makes the window fit: anything that can stretch, and SwiftUI
        // gives the Settings window room to stretch into.
        .fixedSize()
        // Apply a lowered cap to stored logs immediately; otherwise memory is only
        // reclaimed on the next received message.
        .onChange(of: prefs.maxLogLines) { _, _ in store.trimLogs() }
    }
}

/// Add/Edit server form. `server == nil` creates a new server; otherwise edits in place.
struct ServerFormView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let server: IRCServer?
    @State private var draft: ServerDraft

    init(server: IRCServer? = nil) {
        self.server = server
        _draft = State(initialValue: ServerDraft(server: server))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server == nil ? "Add Server" : "Edit Server").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Name:"); TextField("Display name", text: $draft.name).textFieldStyle(.roundedBorder) }
                GridRow { Text("Server:"); TextField("irc.example.net", text: $draft.host).textFieldStyle(.roundedBorder) }
                GridRow { Text("Port:"); TextField("6697", text: $draft.port).textFieldStyle(.roundedBorder) }
                GridRow { Text("Password:"); SecureField("Optional", text: $draft.password).textFieldStyle(.roundedBorder) }
                GridRow { Text("Nickname:"); TextField("Optional (uses default if blank)", text: $draft.nickname).textFieldStyle(.roundedBorder) }
                GridRow {
                    Text("Log in with SASL:")
                    Toggle("", isOn: $draft.useSASL)
                        .labelsHidden()
                        .help("Logs the nickname in to its account with the password, instead of sending the password as the server’s. Needs both.")
                }
                GridRow {
                    Text("Use SSL/TLS:")
                    Toggle("", isOn: $draft.useTLS).labelsHidden()
                }
                GridRow {
                    Text("Auto-connect on launch:")
                    Toggle("", isOn: $draft.autoConnectOnLaunch).labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    draft.save(editing: server, in: store)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

struct JoinChannelView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    /// As for /join: several channels separated by commas, with `#` added where there's no prefix.
    private var channels: [String] { MessageRouter.channelNames(name.filter { !$0.isWhitespace }) }
    private var canJoin: Bool { !channels.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join Channel").font(.headline)
            HStack {
                Text("Channel:")
                TextField("#channel", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Join") {
                    guard canJoin, let server = store.server(withID: store.pendingJoinServerID) else { return }
                    store.joinChannels(channels, on: server)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canJoin)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct TopicEditorView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let channel: IRCChannel
    @State private var topicDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Topic for \(channel.name)").font(.headline)
            TextEditor(text: $topicDraft)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 200)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Set Topic") {
                    let topic = topicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Setting the same topic again would announce a change to the whole channel.
                    if topic != (channel.topic ?? "") { store.setTopic(topic, on: channel) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { topicDraft = channel.topic ?? "" }
    }
}
