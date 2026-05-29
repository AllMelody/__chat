import XCTest
@testable import __chat

@MainActor
final class ImageThumbnailTests: XCTestCase {
    private func thumb(_ s: String) -> String? {
        ImageCacheService.youTubeThumbnailURL(for: URL(string: s)!)
    }

    func testWatchURL() {
        XCTAssertEqual(thumb("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
                       "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    }

    func testShortURL() {
        XCTAssertEqual(thumb("https://youtu.be/dQw4w9WgXcQ"),
                       "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    }

    func testShortsURL() {
        XCTAssertEqual(thumb("https://www.youtube.com/shorts/abc123XYZ"),
                       "https://i.ytimg.com/vi/abc123XYZ/hqdefault.jpg")
    }

    func testWatchWithExtraParams() {
        XCTAssertEqual(thumb("https://youtube.com/watch?list=PL&v=ZZZ999&t=10s"),
                       "https://i.ytimg.com/vi/ZZZ999/hqdefault.jpg")
    }

    func testNonYouTubeReturnsNil() {
        XCTAssertNil(thumb("https://example.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(thumb("https://www.youtube.com/")) // no video id
        XCTAssertNil(thumb("https://vimeo.com/12345"))
    }
}
