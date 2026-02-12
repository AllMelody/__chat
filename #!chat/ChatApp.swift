import SwiftUI

extension Notification.Name {
    static let navigateUp = Notification.Name("navigateUp")
    static let navigateDown = Notification.Name("navigateDown")
    static let composerSubmit = Notification.Name("composerSubmit")
    static let composerFocus = Notification.Name("composerFocus")
}

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
                    Button("Previous Item") { 
                        // Send notification that ContentView will observe
                        NotificationCenter.default.post(name: .navigateUp, object: nil)
                    }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                    
                    Button("Next Item") { 
                        // Send notification that ContentView will observe
                        NotificationCenter.default.post(name: .navigateDown, object: nil)
                    }
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                }
            }
        Settings {
            PreferencesView()
                .environment(preferences)
        }
    }
}

