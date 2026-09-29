import SwiftUI


@main
struct ChatApp: App {
    let preferences = AppPreferences()
    let model: ChatStore
    
    init() {
        self.model = ChatStore()
        model.preferences = preferences
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

