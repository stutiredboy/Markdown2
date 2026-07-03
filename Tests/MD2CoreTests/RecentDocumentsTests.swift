import AppKit
import Foundation
import Testing
@testable import MD2App

/// Mimics `NSDocumentController` recents semantics: noting adds or moves to
/// the front, deduplicated by standardized path.
@MainActor
private final class FakeRecentRecorder: RecentDocumentsRecording {
    private(set) var urls: [URL] = []

    func note(_ url: URL) {
        let path = url.standardizedFileURL.path
        urls.removeAll { $0.standardizedFileURL.path == path }
        urls.insert(url, at: 0)
    }

    var recentDocumentURLs: [URL] { urls }

    func clear() { urls = [] }
}

@MainActor
struct RecentDocumentsTests {
    private let a = URL(fileURLWithPath: "/tmp/notes/alpha.md")
    private let b = URL(fileURLWithPath: "/tmp/notes/beta.md")
    private let c = URL(fileURLWithPath: "/tmp/other/alpha.md")

    @Test func notingMovesExistingEntryToFront() {
        let recorder = FakeRecentRecorder()
        recorder.note(a)
        recorder.note(b)
        recorder.note(a)
        #expect(recorder.recentDocumentURLs == [a, b])
    }

    @Test func menuEntriesDedupeByStandardizedPath() {
        let variant = URL(fileURLWithPath: "/tmp/notes/sub/../alpha.md")
        let entries = RecentDocumentsList.menuEntries(for: [a, variant, b])
        #expect(entries.map(\.url) == [a, b])
    }

    @Test func menuEntriesUseDisplayNamesAndKeepOrder() {
        let entries = RecentDocumentsList.menuEntries(for: [b, a])
        #expect(entries == [
            RecentDocumentEntry(title: "beta.md", url: b),
            RecentDocumentEntry(title: "alpha.md", url: a)
        ])
    }

    @Test func collidingNamesAreDisambiguatedWithParentFolder() {
        let entries = RecentDocumentsList.menuEntries(for: [a, c, b])
        #expect(entries == [
            RecentDocumentEntry(title: "alpha.md — notes", url: a),
            RecentDocumentEntry(title: "alpha.md — other", url: c),
            RecentDocumentEntry(title: "beta.md", url: b)
        ])
    }

    @Test func removeEntryPreservesRemainingOrder() {
        let recorder = FakeRecentRecorder()
        recorder.note(c)
        recorder.note(b)
        recorder.note(a)   // list: a, b, c
        RecentDocumentsList.removeEntry(b, from: recorder)
        #expect(recorder.recentDocumentURLs == [a, c])
    }

    @Test func removeEntryMatchesPathVariants() {
        let recorder = FakeRecentRecorder()
        recorder.note(b)
        recorder.note(a)
        RecentDocumentsList.removeEntry(URL(fileURLWithPath: "/tmp/notes/x/../alpha.md"), from: recorder)
        #expect(recorder.recentDocumentURLs == [b])
    }
}

@MainActor
struct SystemRecentDocumentsRecorderTests {
    private func makeRecorder() -> (SystemRecentDocumentsRecorder, UserDefaults, String) {
        let suite = "md2-recents-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SystemRecentDocumentsRecorder(defaults: defaults), defaults, suite)
    }

    @Test func notesPersistInDefaultsMostRecentFirst() {
        let (recorder, defaults, suite) = makeRecorder()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = URL(fileURLWithPath: "/tmp/r/a.md")
        let b = URL(fileURLWithPath: "/tmp/r/b.md")
        recorder.note(a)
        recorder.note(b)
        recorder.note(a)
        #expect(recorder.recentDocumentURLs.map(\.path) == ["/tmp/r/a.md", "/tmp/r/b.md"])

        // A fresh recorder over the same defaults sees the persisted list.
        let rehydrated = SystemRecentDocumentsRecorder(defaults: defaults)
        #expect(rehydrated.recentDocumentURLs.map(\.path) == ["/tmp/r/a.md", "/tmp/r/b.md"])
    }

    @Test func listIsCappedBySystemRecentCount() {
        let (recorder, defaults, suite) = makeRecorder()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cap = max(1, NSDocumentController.shared.maximumRecentDocumentCount)
        for index in 0..<(cap + 5) {
            recorder.note(URL(fileURLWithPath: "/tmp/r/doc-\(index).md"))
        }
        #expect(recorder.recentDocumentURLs.count == cap)
        #expect(recorder.recentDocumentURLs.first?.lastPathComponent == "doc-\(cap + 4).md")
    }

    @Test func clearEmptiesPersistedList() {
        let (recorder, defaults, suite) = makeRecorder()
        defer { defaults.removePersistentDomain(forName: suite) }
        recorder.note(URL(fileURLWithPath: "/tmp/r/a.md"))
        recorder.clear()
        #expect(recorder.recentDocumentURLs.isEmpty)
        #expect(SystemRecentDocumentsRecorder(defaults: defaults).recentDocumentURLs.isEmpty)
    }
}
