import Foundation
import Testing
@testable import __chat

struct LinkTests {
    /// The pieces of `text` that count as web links.
    private func linked(_ text: String) -> [String] {
        Formatting.webLinks(in: text).map { (text as NSString).substring(with: $0.range) }
    }

    @Test(arguments: [
        ("see https://example.com/a.png for it", ["https://example.com/a.png"]),
        ("plain http://example.com works too", ["http://example.com"]),
        ("www.example.com and example.com/page", ["www.example.com", "example.com/page"]),   // written like links
        ("https://a.example/1 https://b.example/2", ["https://a.example/1", "https://b.example/2"]),
    ])
    func `Web links are links`(text: String, links: [String]) {
        #expect(linked(text) == links)
    }

    @Test(arguments: [
        "ssh://root@host.example",                       // other schemes open other apps
        "open file:///Applications/Calculator.app now",
        "mount smb://evil.example/share",
        "vnc://host.example",
        "x-man-page://ls",
        "ftp://example.com/file",
        "tel:+15551234567",
        "mail me at someone@example.com",
        "the fix is in README.md and main.rs",           // file names that happen to be host names
        "see lib.so or foo.pl",
        "example.com is down",                           // a bare name could be either
        "nothing to see here",
    ])
    func `Nothing else is`(text: String) {
        #expect(linked(text) == [])
    }

    @Test func `Links come with the URL to open`() throws {
        let link = try #require(Formatting.webLinks(in: "docs at example.com/guide").first)
        #expect(["http", "https"].contains(link.url.scheme))
        #expect(link.url.host() == "example.com")
        #expect(link.url.path() == "/guide")
    }
}
