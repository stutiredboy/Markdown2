import MD2Core
import Testing
@testable import MD2App

struct RemoteResourceReportTests {
    @Test func countsRenderedImagesAndRecognizableDiagramImagesButLeavesCodeAndLinksOut() {
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
                .init(displayName: "https://diagram.test", referenceCount: 1),
                .init(displayName: "https://example.test", referenceCount: 3),
                .init(displayName: "https://other.test:444", referenceCount: 1)
            ])
            #expect(report.hasRemoteImages)
            #expect(!report.isPartial)
        }
    }

    @Test(arguments: [
        "",
        "Plain text. https://plain.test/image.png",
        "![local](attachments/local.png)",
        "[link](https://link.test/image.png) <https://autolink.test/image.png>",
        #"<img SRC="attachments/local.png" TITLE='src="HTTPS://title.test/image.png"' ALT='src="HTTP://alt.test/image.png"'>"#,
        #"<img alt="https://alt.test/image.png" src="data:image/png;base64,AAAA">"#,
        #"`<img src="https://example.test/image.png">`"#,
        "~~~mermaid\ngraph TD\nA[plain] --> B[plain]\nclick A \"https://link.test/image.png\"\n~~~",
    ])
    func leavesDocumentsWithoutRemoteImagesQuiet(_ source: String) {
        let rendered = MarkdownRenderer().render(source, assetMode: .appScheme)
        let report = RemoteResourceReport.inspect(body: rendered.body)
        #expect(!report.hasRemoteImages)
        #expect(report.origins.isEmpty)
        #expect(!report.isPartial)
    }

    @Test func handlesSupportedAlternateCSSSVGAndPosterImageDeclarations() {
        let report = RemoteResourceReport.inspect(body: #"""
        <picture><source srcset="data:image/svg+xml,https://data.test/image.png 1x, https://cdn.test/large.png 2x">
            <img srcset="local.png, https://cdn.test/small.png" alt="src='https://alt.test/false.png'">
        </picture>
        <div style="background-image:url(&quot;https://css.test/bg.png&quot;); content:'url(https://literal.test/example.png)'"></div>
        <style>@import url(https://styles.test/import.css);
            @font-face{src:url(https://font.test/font.woff)}
            /* url(https://comment.test/image.png) */
            .image{mask-image:\75 rl(\68 ttps://css.test/mask.svg)}
        </style>
        <svg><image xlink:href="http://svg.test/image.png"/>
            <feImage href="http://svg.test/filter.png" xlink:href="http://ignored.test/duplicate.png" />
            <rect fill="url(https://svg.test/paint.svg#color)" stroke="url(#local-paint)" />
            <a href="https://link.test/image.svg">link</a>
        </svg>
        <video poster='https://poster.test/poster.png' src='https://video.test/video.mp4'></video>
        <!-- <img src="https://comment.test/image.png"> -->
        """#)
        #expect(report.hasRemoteImages)
        #expect(report.origins == [
            .init(displayName: "http://svg.test", referenceCount: 2),
            .init(displayName: "https://cdn.test", referenceCount: 2),
            .init(displayName: "https://css.test", referenceCount: 2),
            .init(displayName: "https://poster.test", referenceCount: 1),
            .init(displayName: "https://svg.test", referenceCount: 1)
        ])
        #expect(!report.isPartial)
    }

    @Test func countsCSSImagesInDiagramStyleDeclarations() {
        let rendered = MarkdownRenderer().render("""
        ~~~mermaid
        graph TD
        A[label]
        style A fill:url(https://diagram.test/paint.svg)
        ~~~
        """, assetMode: .appScheme)
        let report = RemoteResourceReport.inspect(body: rendered.body)
        #expect(report.origins == [.init(displayName: "https://diagram.test", referenceCount: 1)])
        #expect(report.hasRemoteImages)
    }

    @Test func flagsAnAmbiguousRemoteURLWithoutReportingAGuessedOrigin() {
        let rendered = MarkdownRenderer().render(#"<img src="https:/unusual.test/image.png">"#, assetMode: .appScheme)
        let report = RemoteResourceReport.inspect(body: rendered.body)
        #expect(report.hasRemoteImages)
        #expect(report.isPartial)
        #expect(report.origins.isEmpty)
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
        #expect(report.hasRemoteImages)
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
