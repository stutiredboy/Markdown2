import MD2Core
import Testing
@testable import MD2App

struct RemoteResourceReportTests {
    @Test func countsRenderedImagesButLeavesCodeLinksAndDiagramInternalsOutsideScope() {
        let source = #"""
        ![inline](HTTPS://Example.test:443/one.png?token=secret#part)

        ![reference][cdn] ![repeat][cdn]

        [cdn]: https://user:password@example.test/two.png
        [unused]: https://unused.test/unused.png

        <img title='pretend src="https://title.test/evil.png"' alt="real" src="https&#58;//other.test:444/img.png" srcset="https://srcset.test/image.png 2x">

        ![local](attachments/local.png)
        <img src="//scheme-relative.test/image.png">
        [link](https://link.test/image.png)
        `<img src="https://code.test/inline.png">`

        ```html
        <img src="https://code.test/fence.png">
        ```

        ```mermaid
        graph TD
        A["<img src='https://diagram.test/image.png'>"]
        ```
        """#
        for policy in [RemoteResourcePolicy.blocked, .allowRemoteImages] {
            let rendered = MarkdownRenderer().render(source, assetMode: .appScheme, remoteResourcePolicy: policy)
            let report = RemoteResourceReport.inspect(body: rendered.body)
            #expect(report.origins == [
                .init(displayName: "https://example.test", referenceCount: 3),
                .init(displayName: "https://other.test:444", referenceCount: 1)
            ])
            #expect(!report.isPartial)
        }
    }

    @Test func normalizesEquivalentOriginsAndKeepsDistinctSchemesPortsAndTrailingDot() {
        let report = RemoteResourceReport.inspect(body: """
        <img src="http://a.test:080/a"><img src="HTTP://a.TEST/b">
        <img src="https://a.test/c"><img src="https://a.test:00443/d">
        <img src="https://a.test:8443/e"><img src="https://a.test./f">
        <img src="http://127.0.0.1:0/g">
        <img src="https://[0:0:0:0:0:0:0:1]:443/h"><img src="https://[::1]/i">
        """)
        #expect(report.origins == [
            .init(displayName: "http://127.0.0.1:0", referenceCount: 1),
            .init(displayName: "http://a.test", referenceCount: 2),
            .init(displayName: "https://[::1]", referenceCount: 2),
            .init(displayName: "https://a.test", referenceCount: 2),
            .init(displayName: "https://a.test.", referenceCount: 1),
            .init(displayName: "https://a.test:8443", referenceCount: 1)
        ])
        #expect(!report.isPartial)
    }

    @Test func ambiguousOrUnsupportedAuthoritiesMakeReportPartialWithoutGuessing() {
        let report = RemoteResourceReport.inspect(body: #"""
        <img src="https://safe.test/p.png">
        <img src="https://ambiguous.test\@wrong.test/x">
        <img src="http://127.1/x"><img src="http://0177.0.0.1/x"><img src="http://0x7f000001/x">
        <img src="https://%65xample.test/x"><img src="https://bücher.test/x">
        <img src="https://K.test/x"><img src="https://a.test:65536/x">
        <img src="https:/single-slash.test/x"><img src="https://[invalid]/x">
        """#)
        #expect(report.origins == [.init(displayName: "https://safe.test", referenceCount: 1)])
        #expect(report.isPartial)
    }

    @Test func boundedReportsIdentifyOmittedOriginsAndOversizedInput() {
        let body = (0..<130).map { "<img src=\"https://host-\($0).test/image.png\">" }.joined()
            + "<img src=\"https://host-0.test/repeat.png\">"
        let report = RemoteResourceReport.inspect(body: body)
        #expect(report.isPartial)
        #expect(report.origins.count == 128)
        #expect(report.origins.first == .init(displayName: "https://host-0.test", referenceCount: 2))

        let oversize = RemoteResourceReport.inspect(body: String(repeating: "x", count: 2 * 1024 * 1024) + body)
        #expect(oversize == .init(origins: [], isPartial: true))

        let longSource = RemoteResourceReport.inspect(body: "<img src=\"https://host.test/" +
            String(repeating: "a", count: 8_192) + "\">")
        #expect(longSource == .init(origins: [], isPartial: true))
    }
}
