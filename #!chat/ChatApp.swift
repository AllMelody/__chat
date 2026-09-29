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

    private var isChannelSelected: Bool {
        guard let id = model.selectedNodeID else { return false }
        return model.servers.contains { $0.channels.contains { $0.id == id } }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .environment(model)
            .environment(preferences)
            .commands {
                CommandMenu("Server") {
                    Button("Add Server…") { model.isPresentingAddServer = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])

                    Button("Delete Server…") {
                        if let server = model.server(withID: model.selectedNodeID) {
                            model.deleteServer(server)
                        }
                    }
                    .disabled(model.server(withID: model.selectedNodeID) == nil)
                    .keyboardShortcut(.delete, modifiers: [.command])
                }
                
                CommandMenu("Channel") {
                    Button("Show Topic...") {
                        model.isPresentingTopicEditor = true
                    }
                    .keyboardShortcut("t", modifiers: [.command])
                    .disabled(!isChannelSelected)
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

