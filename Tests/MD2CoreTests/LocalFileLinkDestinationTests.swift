import Foundation
import Testing

/// Test-only comparison for a local link after the browser has parsed its URL.
enum LocalFileLinkDestination {
    static func matches(_ actual: URL, _ expected: URL) -> Bool {
        guard actual.isFileURL, expected.isFileURL,
              let actual = URLComponents(url: actual, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: expected, resolvingAgainstBaseURL: false) else { return false }
        // Decode the path once through Foundation, then account only for the
        // filesystem's Unicode normalization. Never percent-decode it again.
        // Keep authority and query exact; fragments are decoded once but their
        // Unicode bytes remain exact because heading IDs are not filesystem names.
        return actual.scheme == expected.scheme
            && actual.host == expected.host
            && actual.port == expected.port
            && actual.percentEncodedUser == expected.percentEncodedUser
            && actual.percentEncodedPassword == expected.percentEncodedPassword
            && actual.path.precomposedStringWithCanonicalMapping == expected.path.precomposedStringWithCanonicalMapping
            && actual.percentEncodedQuery == expected.percentEncodedQuery
            && actual.fragment.map { Array($0.utf8) } == expected.fragment.map { Array($0.utf8) }
    }
}

struct LocalFileLinkDestinationTests {
    @Test func equivalentURLSpellingsAddressTheSameFixture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-link-url-semantics-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.absoluteString + "/"
        let cases = [
            ("cafe\u{301}.md", "caf%C3%A9.md#x&y", "cafe%CC%81.md#x&y"),
            ("literal&num;.md", "literal&num;.md#target", "literal&num%3B.md#target")
        ]
        for (filename, actualSpelling, expectedSpelling) in cases {
            let payload = Data("Fixture: \(filename)".utf8)
            try payload.write(to: directory.appendingPathComponent(filename))
            let actual = try #require(URL(string: base + actualSpelling))
            let expected = try #require(URL(string: base + expectedSpelling))
            #expect(actual.absoluteString != expected.absoluteString)
            #expect(try Data(contentsOf: URL(fileURLWithPath: actual.path)) == payload)
            #expect(try Data(contentsOf: URL(fileURLWithPath: expected.path)) == payload)
            let actualID = try #require(FileManager.default.attributesOfItem(atPath: actual.path)[.systemFileNumber] as? NSNumber)
            let expectedID = try #require(FileManager.default.attributesOfItem(atPath: expected.path)[.systemFileNumber] as? NSNumber)
            #expect(actualID == expectedID, "both spellings must identify the same real fixture")
            #expect(actual.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath(),
                    "the app delegate's existing-window/recovery comparison must identify the same file")
            #expect(LocalFileLinkDestination.matches(actual, expected), "\(actual) and \(expected) are the same target")
        }
    }

    @Test func distinctDestinationsDoNotCollapse() throws {
        let cases = [
            ("file:///tmp/literal%2523.md#target", "file:///tmp/literal%23.md#target"),
            ("file:///tmp/literal&num;.md#target", "file:///tmp/literal#num;.md#target"),
            ("file:///tmp/next.md#target", "file:///tmp/other.md#target"),
            ("file:///tmp/next.md#target", "file:///tmp/next.md#other"),
            ("file:///tmp/next.md#%2523", "file:///tmp/next.md#%23"),
            ("file:///tmp/next.md#caf%C3%A9", "file:///tmp/next.md#cafe%CC%81"),
            ("file:///tmp/next.md", "file:///tmp/next.md#"),
            ("file:///tmp/next.md?q=a%26b", "file:///tmp/next.md?q=a&b"),
            ("file:///tmp/next.md", "file://remote/tmp/next.md"),
            ("file:///tmp/next.md", "https://example.com/tmp/next.md")
        ]
        for (actualSpelling, expectedSpelling) in cases {
            let actual = try #require(URL(string: actualSpelling))
            let expected = try #require(URL(string: expectedSpelling))
            #expect(!LocalFileLinkDestination.matches(actual, expected), "must distinguish \(actual) from \(expected)")
        }
    }
}
