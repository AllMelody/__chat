import Foundation
import Observation

@Observable
final class AppPreferences {
    var maxLogLines: Int { didSet { persist() } }
    var showImageThumbnails: Bool { didSet { persist() } }
    var debugRawServerLog: Bool { didSet { persist() } }

    init() {
        let d = UserDefaults.standard
        let storedLines = d.object(forKey: Keys.maxLogLines) as? Int
        self.maxLogLines = max(1, storedLines ?? 1000)
        self.showImageThumbnails = d.object(forKey: Keys.showImageThumbnails) as? Bool ?? false
        self.debugRawServerLog = d.object(forKey: Keys.debugRawServerLog) as? Bool ?? false
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(max(1, maxLogLines), forKey: Keys.maxLogLines)
        d.set(showImageThumbnails, forKey: Keys.showImageThumbnails)
        d.set(debugRawServerLog, forKey: Keys.debugRawServerLog)
    }

    private enum Keys {
        static let maxLogLines = "Preferences.maxLogLines"
        static let showImageThumbnails = "Preferences.showImageThumbnails"
        static let debugRawServerLog = "Preferences.debugRawServerLog"
    }
}