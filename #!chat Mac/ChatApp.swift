import AppKit
import SwiftUI

@main
struct ChatApp: App {
    // @State guarantees a single instance of each for the app's lifetime.
    @State private var preferences: AppPreferences
    @State private var store: ChatStore

    init() {
        let preferences = AppPreferences()
        let store = ChatStore()
        // ChatStore holds preferences weakly; @State keeps them alive.
        store.preferences = preferences
        _preferences = State(initialValue: preferences)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        // One window: the selection and sheets live in the shared ChatStore, so a second window
        // would only mirror the first.
        Window("#!chat", id: "main") { ContentView() }
            .environment(store)
            .environment(preferences)
            .commands {
                CloseCommands()
                FindCommands()

                CommandMenu("Server") {
                    Button("Add Server…") { store.isPresentingAddServer = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])

                    Divider()

                    // These act on the server of whatever is selected: the server itself, or
                    // the one a selected conversation is on.
                    let server = store.selectedItem?.server
                    switch server?.connectionStatus {
                    case .connected:
                        Button("Disconnect") { if let server { store.disconnect(server) } }
                    case .connecting, .reconnecting:
                        Button("Cancel Connection") { if let server { store.disconnect(server) } }
                    case .disconnected, .connectionTimeout, nil:
                        Button("Connect") { if let server { store.connect(server) } }
                            .disabled(server == nil)
                    }
                    Button("Join Channel…") {
                        store.pendingJoinServerID = server?.id
                        store.isPresentingJoinChannel = true
                    }
                    .keyboardShortcut("j")
                    .disabled(server?.isConnected != true)
                    Button("Edit Server…") {
                        store.pendingEditServerID = server?.id
                        store.isPresentingEditServer = true
                    }
                    .disabled(server == nil)

                    Divider()

                    // Only with the server itself selected, and no ⌘⌫ shortcut: menu shortcuts
                    // win over the composer, where ⌘⌫ has to keep deleting to the start of the
                    // line.
                    Button("Delete Server…") {
                        if let server = store.server(withID: store.selectedItemID) {
                            store.requestDeletion(of: server)
                        }
                    }
                    .disabled(store.server(withID: store.selectedItemID) == nil)
                }
                
                CommandMenu("Channel") {
                    Button("Show Topic…") {
                        store.isPresentingTopicEditor = true
                    }
                    .keyboardShortcut("t", modifiers: [.command])
                    .disabled(store.selectedItem?.channel == nil)
                }

                CommandMenu("Navigation") {
                    Button("Previous Item") { store.navigateSidebar(by: -1) }
                        .keyboardShortcut(.upArrow, modifiers: [.command])

                    Button("Next Item") { store.navigateSidebar(by: 1) }
                        .keyboardShortcut(.downArrow, modifiers: [.command])
                }
            }
        Settings {
            SettingsView()
                .environment(preferences)
                .environment(store)
        }
    }
}

/// Edit ▸ Find searches the log on screen, in a find bar above it, whichever view has keyboard
/// focus: it's the only text there is to search. (SwiftUI's own Find commands go to the
/// focused view, which is nearly always the composer.)
struct FindCommands: Commands {
    /// Set only while the main window is key.
    @FocusedValue(ChatStore.self) private var store

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { store?.find(.showFindInterface) }
                .keyboardShortcut("f")
                .disabled(store == nil)
            Button("Find Next") { store?.find(.nextMatch) }
                .keyboardShortcut("g")
                .disabled(store == nil)
            Button("Find Previous") { store?.find(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(store == nil)
        }
    }
}

/// ⌘W, File ▸ Close, closes the channel or private conversation on screen once the user
/// confirms, not the main window: that would quit the app and drop every connection. Other
/// windows, like Settings, still close with it.
struct CloseCommands: Commands {
    /// Set only while the main window is key.
    @FocusedValue(ChatStore.self) private var store

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            if let store {
                let selection = store.selectedItem
                Button(selection?.channel != nil ? "Part Channel…" : "Close Conversation…") {
                    if let selection { store.requestClosing(selection) }
                }
                .keyboardShortcut("w")
                .disabled(selection?.isConversation != true)
            } else {
                Button("Close") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
        }
    }
}
