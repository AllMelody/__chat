import Foundation
import Testing
@testable import __chat

struct ImageThumbnailTests {
    private func thumb(_ s: String) throws -> String? {
        ImageCacheService.youTubeThumbnailURL(for: try #require(URL(string: s)))
    }

    @Test(arguments: [
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),     // watch URL
        ("https://youtu.be/dQw4w9WgXcQ", "dQw4w9WgXcQ"),                    // short URL
        ("https://www.youtube.com/shorts/abc123XYZ", "abc123XYZ"),          // shorts
        ("https://youtube.com/watch?list=PL&v=ZZZ999&t=10s", "ZZZ999"),     // extra params
    ])
    func `YouTube links map to their thumbnail`(url: String, videoID: String) throws {
        #expect(try thumb(url) == "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    @Test(arguments: [
        "https://example.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/", // no video id
        "https://vimeo.com/12345",
    ])
    func `Other links have no YouTube thumbnail`(url: String) throws {
        #expect(try thumb(url) == nil)
    }
}
