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
        // An iPhone shows one thing at a time, and opens on the list of conversations rather
        // than inside the first server's log. There, nothing selected is that list on screen.
        store.selectedItemID = nil
        _preferences = State(initialValue: preferences)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Links in the log open in Safari's view inside the app, not in Safari.
                .onOpenURL(prefersInApp: true)
                .environment(store)
                .environment(preferences)
        }
    }
}
