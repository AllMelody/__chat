import SwiftUI

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
        NavigationStack {
            Form {
                Section {
                    field("Name", prompt: "Display name", text: $draft.name)
                    field("Server", prompt: "irc.example.net", text: $draft.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    field("Port", prompt: "6697", text: $draft.port)
                        .keyboardType(.numberPad)
                    Toggle("Use SSL/TLS", isOn: $draft.useTLS)
                }
                Section {
                    field("Nickname", prompt: "Optional", text: $draft.nickname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Password") {
                        SecureField("Optional", text: $draft.password)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Log in with SASL", isOn: $draft.useSASL)
                } footer: {
                    Text("SASL logs the nickname in to its account with the password, instead of sending the password as the server’s. It needs both.")
                }
                Section {
                    Toggle("Auto-connect on launch", isOn: $draft.autoConnectOnLaunch)
                }
            }
            .navigationTitle(server == nil ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Adding a server selects it, which on the Mac shows it in the sidebar;
                        // here it would open its empty log. Stay where the user was: the list.
                        let selection = store.selectedItemID
                        draft.save(editing: server, in: store)
                        store.selectedItemID = selection
                        dismiss()
                    }
                    .disabled(!draft.canSave)
                }
            }
        }
    }

    private func field(_ label: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(prompt, text: text)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct TopicEditorView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let channel: IRCChannel
    @State private var topicDraft: String

    init(channel: IRCChannel) {
        self.channel = channel
        _topicDraft = State(initialValue: channel.topic ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Topic", text: $topicDraft, axis: .vertical)
                    .lineLimit(3...10)
            }
            .navigationTitle("Topic for \(channel.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Topic") {
                        let topic = topicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Setting the same topic again would announce a change to the whole channel.
                        if topic != (channel.topic ?? "") { store.setTopic(topic, on: channel) }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SettingsView: View {
    @Environment(AppPreferences.self) private var prefs
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The log lengths to choose from, and whatever length is set already.
    private var logLengths: [Int] {
        Set([250, 500, 1000, 2500, 5000, 10000, prefs.maxLogLines]).sorted()
    }

    var body: some View {
        @Bindable var prefs = prefs
        NavigationStack {
            Form {
                Picker("Lines to keep in log", selection: $prefs.maxLogLines) {
                    ForEach(logLengths, id: \.self) { Text($0, format: .number) }
                }
                Section("Show") {
                    Toggle("Image thumbnails", isOn: $prefs.showImageThumbnails)
                    Toggle("Joins, parts and quits in channels", isOn: $prefs.showJoinsAndParts)
                }
                Section("Debug") {
                    Toggle("Log raw server traffic", isOn: $prefs.debugRawServerLog)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Apply a lowered cap to stored logs immediately; otherwise memory is only
        // reclaimed on the next received message.
        .onChange(of: prefs.maxLogLines) { _, _ in store.trimLogs() }
    }
}
