import Foundation
import AppKit
import CryptoKit

final class ImageCacheService {
    // In-memory thumbnails keyed by ChatMessage.id
    private var messageThumbnails: [UUID: [MessageThumbnail]] = [:]

    // Called on the main thread whenever thumbnails change for a message
    var onThumbnailUpdated: ((UUID, [MessageThumbnail]) -> Void)?
    
    // Image cache using native macOS APIs
    private let imageCache = NSCache<NSString, NSImage>()
    private let imageCacheDirectory: URL = {
        // Use Caches directory - macOS can purge this under disk pressure
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cacheDir = caches.appendingPathComponent("ChatApp/ImageCache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }()

    // Cache retention period (30 days)
    private let cacheMaxAge: TimeInterval = 30 * 24 * 60 * 60
    
    // Link cache for content type detection
    struct LinkCacheEntry: Codable { let contentType: String; let lastChecked: Date }
    private let linkCacheKey = "LinkCache.v1"
    private var linkCache: [String: LinkCacheEntry] = [:] { didSet { persistLinkCache() } }
    private var linkCacheSaveTask: Task<Void, any Error>?
    
    init() {
        setupImageCache()
        loadLinkCacheAndPrune()
        pruneOldCacheFiles()
    }
    
    private func setupImageCache() {
        // Configure NSCache with reasonable limits
        imageCache.countLimit = 100 // Maximum 100 images in memory
        imageCache.totalCostLimit = 50 * 1024 * 1024 // 50MB memory limit
    }
    
    private func loadLinkCacheAndPrune() {
        if let data = UserDefaults.standard.data(forKey: linkCacheKey),
           let dict = try? JSONDecoder().decode([String: LinkCacheEntry].self, from: data) {
            // Prune entries older than 30 days
            let cutoff = Date().addingTimeInterval(-cacheMaxAge)
            linkCache = dict.filter { $0.value.lastChecked >= cutoff }
        }
    }

    private func pruneOldCacheFiles() {
        // Run on background queue to avoid blocking startup
        DispatchQueue.global(qos: .utility).async { [imageCacheDirectory, cacheMaxAge] in
            let fileManager = FileManager.default
            let cutoffDate = Date().addingTimeInterval(-cacheMaxAge)

            do {
                let files = try fileManager.contentsOfDirectory(
                    at: imageCacheDirectory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: .skipsHiddenFiles
                )

                var prunedCount = 0
                for fileURL in files {
                    guard fileURL.pathExtension == "cache" else { continue }

                    let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                    if let modDate = resourceValues.contentModificationDate, modDate < cutoffDate {
                        try fileManager.removeItem(at: fileURL)
                        prunedCount += 1
                    }
                }

                if prunedCount > 0 {
                    print("Pruned \(prunedCount) old image cache files")
                }
            } catch {
                // Cache pruning is best-effort, don't crash on errors
                print("Cache pruning error: \(error)")
            }
        }
    }
    
    /// Debounced: bursts of link checks coalesce into one write. Encoding happens on main,
    /// where linkCache lives, so it can't race with further mutations.
    private func persistLinkCache() {
        linkCacheSaveTask?.cancel()
        linkCacheSaveTask = Task { [weak self] in
            // Task.sleep only throws on cancellation, i.e. when a newer save supersedes this one.
            try await Task.sleep(for: .seconds(1))
            guard let self else { return }
            // Strings and Dates always encode; a failure here is a programming error.
            let data = try! JSONEncoder().encode(self.linkCache)
            UserDefaults.standard.set(data, forKey: self.linkCacheKey)
        }
    }
    
    // MARK: - Image Caching Helpers
    
    private func cacheKeyForURL(_ urlString: String) -> String {
        // Create a safe filename from URL using SHA256 hash
        let data = urlString.data(using: .utf8) ?? Data()
        let hash = data.withUnsafeBytes { bytes in
            var hasher = SHA256()
            hasher.update(bufferPointer: UnsafeRawBufferPointer(bytes))
            return hasher.finalize()
        }
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func cachedImage(for urlString: String) -> NSImage? {
        let cacheKey = cacheKeyForURL(urlString)

        // Check memory cache first
        if let cachedImage = imageCache.object(forKey: cacheKey as NSString) {
            return cachedImage
        }

        // Check disk cache
        let fileURL = imageCacheDirectory.appendingPathComponent("\(cacheKey).cache")
        guard let data = try? Data(contentsOf: fileURL),
              let image = NSImage(data: data) else {
            return nil
        }

        // Touch the file to update modification date (keeps frequently-used images from being pruned)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)

        // Store in memory cache for next time
        imageCache.setObject(image, forKey: cacheKey as NSString)
        return image
    }
    
    // MARK: - Thumbnail Processing

    /// Forgets the in-memory thumbnail entries (and the NSImages they hold strongly) for
    /// messages that no longer exist — trimmed past the log cap, or removed along with their
    /// channel/PM/server. The NSCache and disk caches are untouched: they're URL-keyed and
    /// bounded on their own.
    func discardThumbnails(for messageIDs: [UUID]) {
        for id in messageIDs {
            messageThumbnails.removeValue(forKey: id)
        }
    }

    func scanMessageForThumbnails(_ message: ChatMessage, showImageThumbnails: Bool) {
        guard showImageThumbnails else { return }
        guard let detector = linkDetector else { return }
        let text = message.text
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var seen = Set<String>()
        detector.enumerateMatches(in: text, options: [], range: range) { result, _, _ in
            guard let u = result?.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return }
            let key = u.absoluteString
            if seen.insert(key).inserted {
                // YouTube: we know the thumbnail URL without a HEAD request
                if let ytThumbURL = ImageCacheService.youTubeThumbnailURL(for: u) {
                    if let cachedImage = self.cachedImage(for: key) {
                        var list = self.messageThumbnails[message.id] ?? []
                        if let idx = list.firstIndex(where: { $0.url == key }) {
                            list[idx].image = cachedImage
                        } else {
                            list.append(MessageThumbnail(url: key, image: cachedImage))
                        }
                        self.messageThumbnails[message.id] = list
                        self.onThumbnailUpdated?(message.id, list)
                    } else {
                        var list = self.messageThumbnails[message.id] ?? []
                        if !list.contains(where: { $0.url == key }) {
                            list.append(MessageThumbnail(url: key, image: nil))
                            self.messageThumbnails[message.id] = list
                            self.onThumbnailUpdated?(message.id, list)
                        }
                        self.fetchImage(urlString: ytThumbURL, messageID: message.id, displayURL: key)
                    }
                } else if let cached = self.linkCache[key], cached.contentType.lowercased().hasPrefix("image/") {
                    var list = self.messageThumbnails[message.id] ?? []
                    if !list.contains(where: { $0.url == key }) {
                        list.append(MessageThumbnail(url: key, image: nil))
                        self.messageThumbnails[message.id] = list
                        self.onThumbnailUpdated?(message.id, list)
                    }
                    self.fetchThumbnailIfNeeded(for: key, messageID: message.id)
                } else {
                    self.fetchThumbnailIfNeeded(for: key, messageID: message.id)
                }
            }
        }
    }

    /// Extracts a YouTube thumbnail URL from a youtube.com or youtu.be link.
    static func youTubeThumbnailURL(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        var videoID: String?

        if host == "youtu.be" || host == "www.youtu.be" {
            videoID = url.pathComponents.dropFirst().first
        } else if host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
                videoID = v
            } else if url.pathComponents.count >= 3 && url.pathComponents[1] == "shorts" {
                videoID = url.pathComponents[2]
            }
        }

        guard let id = videoID, !id.isEmpty else { return nil }
        return "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
    }
    
    private func fetchThumbnailIfNeeded(for urlString: String, messageID: UUID) {
        // First check if we have a cached image
        if let cachedImage = cachedImage(for: urlString) {
            DispatchQueue.main.async {
                var list = self.messageThumbnails[messageID] ?? []
                if let idx = list.firstIndex(where: { $0.url == urlString }) {
                    list[idx].image = cachedImage
                } else {
                    list.append(MessageThumbnail(url: urlString, image: cachedImage))
                }
                self.messageThumbnails[messageID] = list
                self.onThumbnailUpdated?(messageID, list)
            }
            return
        }
        
        if let cached = linkCache[urlString] {
            if cached.contentType.lowercased().hasPrefix("image/") {
                fetchImage(urlString: urlString, messageID: messageID)
            }
            return
        }
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        Task { [weak self] in
            let resp: URLResponse
            do {
                (_, resp) = try await URLSession.shared.data(for: req)
            } catch {
                // Unreachable links are expected in chat; log and skip the thumbnail.
                print("HEAD request failed for \(urlString): \(error)")
                return
            }
            guard let self else { return }

            let ct = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            self.linkCache[urlString] = LinkCacheEntry(contentType: ct, lastChecked: Date())
            if ct.lowercased().hasPrefix("image/") {
                var list = self.messageThumbnails[messageID] ?? []
                if !list.contains(where: { $0.url == urlString }) {
                    list.append(MessageThumbnail(url: urlString, image: nil))
                    self.messageThumbnails[messageID] = list
                    self.onThumbnailUpdated?(messageID, list)
                }
                self.fetchImage(urlString: urlString, messageID: messageID)
            }
        }
    }
    
    /// Fetches an image from `urlString` and stores the result.
    /// `displayURL` overrides the URL used for caching and click targets (e.g. YouTube video URL
    /// when fetching from i.ytimg.com). If nil, `urlString` is used for both.
    private func fetchImage(urlString: String, messageID: UUID, displayURL: String? = nil) {
        let cacheKey = displayURL ?? urlString
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30.0

        let memoryKey = cacheKeyForURL(cacheKey)
        let fileURL = imageCacheDirectory.appendingPathComponent("\(memoryKey).cache")

        Task { [weak self] in
            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(for: request)
            } catch {
                // Unreachable images are expected in chat; log and skip the thumbnail.
                print("Image fetch failed for \(urlString): \(error)")
                return
            }

            guard let cg = await Self.makeThumbnail(from: data, cachingPNGAt: fileURL),
                  let self else { return }

            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            self.imageCache.setObject(img, forKey: memoryKey as NSString)

            var arr = self.messageThumbnails[messageID] ?? []
            if let idx = arr.firstIndex(where: { $0.url == cacheKey }) {
                arr[idx].image = img
            } else {
                arr.append(MessageThumbnail(url: cacheKey, image: img))
            }
            self.messageThumbnails[messageID] = arr
            self.onThumbnailUpdated?(messageID, arr)
        }
    }

    /// Decodes a downscaled thumbnail and writes it to the disk cache, off the main actor.
    /// Returns a CGImage (Sendable) rather than an NSImage so it can cross back to main.
    @concurrent
    private nonisolated static func makeThumbnail(from data: Data, cachingPNGAt fileURL: URL) async -> CGImage? {
        guard !data.isEmpty, data.count < 10 * 1024 * 1024 else { return nil }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let maxPixelSize = 600
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        // The disk cache is best-effort (Caches can be purged at any time), so a failed write
        // only means the thumbnail is re-fetched next launch.
        if let pngData = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL)
        }
        return cg
    }
    
    // Cache the regex detector for performance
    private let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()
}