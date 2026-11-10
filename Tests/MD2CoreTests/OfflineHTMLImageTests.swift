import Foundation
import Testing
@testable import MD2App

struct OfflineHTMLImageTests {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    @Test func embeddedImageCannotCarryASecondActiveSource() {
        let html = "<img src=\"data:image/png;base64,\(png)\" srcset=\"https://test.invalid/extra.png 2x\" style=\"background:url(https://test.invalid/style.png)\" alt=\"safe\">"
        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: nil)
        #expect(output.html.contains("data:image/png;base64,"))
        #expect(output.html.contains("alt=\"safe\""))
        #expect(!output.html.contains("test.invalid"))
        #expect(!output.html.contains("srcset"))
        #expect(output.unembeddedLocalImages.isEmpty)
    }

    @Test func protocolRelativeAndEntityEncodedImagesBecomeReadableInertText() {
        let html = #"<img src="//test.invalid/a.png" alt="&lt;image&gt;"><img src="http&#58;//test.invalid/b.png">"#
        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: nil,
            labels: OfflineHTMLLabels(remoteImageBlocked: "已阻止", localImageUnavailable: "无法嵌入"))
        #expect(output.remoteImages == ["//test.invalid/a.png", "http://test.invalid/b.png"])
        #expect(!output.html.contains("<img"))
        #expect(output.html.contains("已阻止 — &lt;image&gt;"))
    }

    @Test(arguments: [
        #"<image href="https://test.invalid/a.png"/>"#,
        #"<use href="file:///tmp/a.svg#x"/>"#,
        #"<foreignObject><img xmlns="http://www.w3.org/1999/xhtml" src="https://test.invalid/a"/></foreignObject>"#,
        #"<style>@import 'https://test.invalid/a.css';</style>"#,
        #"<rect style="fill:u\72l(https://test.invalid/a.svg)"/>"#,
        #"<rect fill="url(https://test.invalid/a.svg#x)"/>"#,
        #"<script href="https://test.invalid/a.js"/>"#,
        #"<set attributeName="href" to="https://test.invalid/a"/>"#
    ])
    func existingDataSVGRejectsNestedExternalOrAmbiguousResources(fragment: String) {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"2\">\(fragment)</svg>"
        let source = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        let output = SelfContainedHTMLBuilder.build(html: "<img src=\"\(source)\">", baseURL: nil)
        #expect(!output.html.contains("<img"))
        #expect(output.unembeddedLocalImages == ["Embedded image"])
        #expect(output.localImageFailures["Embedded image"] == .invalidImage)
    }

    @Test func vectorSVGKeepsLocalGradientsMarkersAndStyles() {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><style>.paint { fill: url(#gradient); stroke: #000; stroke-width: 2 }</style><defs><linearGradient id="gradient"><stop stop-color="red" offset="0%"/><stop stop-color="blue" offset="100%"/></linearGradient><marker id="arrow"><path d="M0 0 L5 5"/></marker></defs><rect class="paint" width="20" height="20" style="marker-end:url(#arrow)"/></svg>"#
        let source = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        let output = SelfContainedHTMLBuilder.build(html: "<img src=\"\(source)\">", baseURL: nil)
        #expect(output.unembeddedLocalImages.isEmpty)
        #expect(output.html.contains(source))
    }

    @Test func existingDataImageUsesTheSameTotalBudget() {
        var limits = SelfContainedHTMLBuilder.Limits()
        limits.totalBytes = Data(base64Encoded: png)!.count
        let image = "<img src=\"data:image/png;base64,\(png)\">"
        let output = SelfContainedHTMLBuilder.build(html: image + image, baseURL: nil, limits: limits)
        #expect(output.html.components(separatedBy: "<img").count == 2)
        #expect(output.localImageFailures["Embedded image"] == .resourceLimit)
    }
}
