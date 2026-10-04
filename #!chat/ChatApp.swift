import AppKit
import SwiftUI

@main
struct ChatApp: App {
    // @State guarantees a single instance of each for the app's lifetime.
    @State private var preferences: AppPreferences
    @State private var model: ChatStore

    init() {
        let preferences = AppPreferences()
        let model = ChatStore()
        // ChatStore holds preferences weakly; @State keeps them alive.
        model.preferences = preferences
        _preferences = State(initialValue: preferences)
        _model = State(initialValue: model)
    }

    var body: some Scene {
        // One window: the selection and sheets live in the shared ChatStore, so a second window
        // would only mirror the first.
        Window("#!chat", id: "main") { ContentView() }
            .environment(model)
            .environment(preferences)
            .commands {
                CloseCommands()

                CommandMenu("Server") {
                    Button("Add Server…") { model.isPresentingAddServer = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])

                    // No ⌘⌫ shortcut: menu shortcuts win over the composer, where ⌘⌫ has to
                    // keep deleting to the start of the line.
                    Button("Delete Server…") {
                        if let server = model.server(withID: model.selectedNodeID) {
                            model.requestDeletion(of: server)
                        }
                    }
                    .disabled(model.server(withID: model.selectedNodeID) == nil)
                }
                
                CommandMenu("Channel") {
                    Button("Show Topic…") {
                        model.isPresentingTopicEditor = true
                    }
                    .keyboardShortcut("t", modifiers: [.command])
                    .disabled(model.selectedItem?.channel == nil)
                }

                CommandMenu("Navigation") {
                    Button("Previous Item") { model.navigateSidebar(by: -1) }
                        .keyboardShortcut(.upArrow, modifiers: [.command])

                    Button("Next Item") { model.navigateSidebar(by: 1) }
                        .keyboardShortcut(.downArrow, modifiers: [.command])
                }
            }
        Settings {
            PreferencesView()
                .environment(preferences)
                .environment(model)
        }
    }
}

/// ⌘W, File ▸ Close, closes the channel or private conversation on screen once the user
/// confirms, not the main window: that would quit the app and drop every connection. Other
/// windows, like Settings, still close with it.
struct CloseCommands: Commands {
    /// Set only while the main window is key.
    @FocusedValue(ChatStore.self) private var model

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            if let model {
                let selection = model.selectedItem
                Button(selection?.channel != nil ? "Part Channel…" : "Close Conversation…") {
                    if let selection { model.requestClosing(selection) }
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
