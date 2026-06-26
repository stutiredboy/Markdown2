import Testing
@testable import MD2Core

/// Task 1.3: the corpus loads offline from the bundle and is categorised.
struct ConformanceCorpusTests {
    @Test func loadsBothCorporaOfflineFromBundle() throws {
        let entries = try ConformanceCorpus.load()

        // CommonMark 0.31.2 ships 652 examples; the GFM extension subset adds 24.
        #expect(entries.count == 652 + 24)
        #expect(entries.contains { $0.origin == .commonMark })
        #expect(entries.contains { $0.origin == .gfm })
    }

    @Test func examplesExposeSourceMarkdownAndSection() throws {
        let groups = try ConformanceCorpus.groupedBySection()
        let sections = Set(groups.map(\.section))

        #expect(sections.contains("ATX headings"))
        #expect(sections.contains("Tables (extension)"))
        #expect(sections.contains("Task list items (extension)"))

        for (section, entries) in groups {
            #expect(!section.isEmpty)
            #expect(!entries.isEmpty)
            for entry in entries {
                #expect(entry.section == section)
            }
        }
    }

    @Test func everyExampleHasAStableUniqueID() throws {
        let ids = try ConformanceCorpus.load().map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
