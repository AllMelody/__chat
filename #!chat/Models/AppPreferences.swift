import Foundation
import Observation

@Observable
final class AppPreferences {
    /// Single source for the log-cap default — ChatStore.trimLogs falls back to this
    /// when preferences aren't wired up yet.
    static let defaultMaxLogLines = 1000

    var maxLogLines: Int {
        didSet {
            // Clamp here so any binding (text field, stepper) can't store a degenerate cap.
            if maxLogLines < 1 { maxLogLines = 1 }
            persist()
        }
    }
    var showImageThumbnails: Bool { didSet { persist() } }
    var debugRawServerLog: Bool { didSet { persist() } }

    init() {
        let d = UserDefaults.standard
        let storedLines = d.object(forKey: Keys.maxLogLines) as? Int
        self.maxLogLines = max(1, storedLines ?? Self.defaultMaxLogLines)
        self.showImageThumbnails = d.object(forKey: Keys.showImageThumbnails) as? Bool ?? false
        self.debugRawServerLog = d.object(forKey: Keys.debugRawServerLog) as? Bool ?? false
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(maxLogLines, forKey: Keys.maxLogLines)
        d.set(showImageThumbnails, forKey: Keys.showImageThumbnails)
        d.set(debugRawServerLog, forKey: Keys.debugRawServerLog)
    }

    private enum Keys {
        static let maxLogLines = "Preferences.maxLogLines"
        static let showImageThumbnails = "Preferences.showImageThumbnails"
        static let debugRawServerLog = "Preferences.debugRawServerLog"
    }
}