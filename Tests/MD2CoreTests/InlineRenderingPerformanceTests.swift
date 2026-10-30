import Foundation
import Testing
@testable import MD2Core

/// Guards the inline renderer's protection/restore/substitution paths against
/// super-linear growth, and pins the output of the paths the optimization touches.
///
/// Timing policy: warm up once, take the **minimum** of three runs (least
/// contaminated by scheduler noise), fail fast on the small size with an
/// absolute ceiling, then assert the doubled size is under 3x the small size
/// plus at most 2 ms of timer resolution. Linear growth is ~2x; the pre-fix
/// implementation is ~4x. The absolute ceilings only bound CI time when a
/// regression is present; the ratio is the real quadratic guard.
@Suite(.serialized)
struct InlineRenderingPerformanceTests {
    private let renderer = MarkdownRenderer()
    private let sentinel = "\u{E000}"

    // MARK: - Output characterization

    @Test func linkHrefEntityAndFormattedLabel() {
        let body = renderer.render("[**bold** and `code` &amp;](https://example.com/?a=1&amp;b=2)").body
        #expect(body.contains(#"<a href="https://example.com/?a=1&amp;b=2"><strong>bold</strong> and <code>code</code> &amp;</a>"#))
    }

    @Test func imageSourceEntity() {
        let body = renderer.render("![A&amp;B](a&amp;b.png)").body
        #expect(body.contains(#"<img src="a&amp;b.png" alt="A&amp;B">"#))
    }

    @Test func rawHTMLAttributeEntity() {
        let body = renderer.render(#"<span title="A &amp; B">x</span>"#).body
        #expect(body.contains(#"<span title="A &amp; B">x</span>"#))
    }

    @Test func mathAndCodeEntitiesKeepTheirCurrentEscaping() {
        let body = renderer.render("`x &amp; y` $a &amp; b$ &amp;").body
        #expect(body.contains(#"<code>x &amp;amp; y</code>"#))
        #expect(body.contains(#"<span class="math math-inline">a &amp;amp; b</span>"#))
        #expect(body.hasSuffix(" &amp;</p>"))
    }

    /// A bare URL directly followed by protected host-label content reads as a
    /// longer authority, so the candidate stays literal.
    @Test func bareURLAdjacentToProtectedContentStaysLiteral() {
        let body = renderer.render("https://example.com`code` https://example.com<em>end</em>").body
        #expect(!body.contains(#"<a href="https://example.com">https://example.com</a><code>code</code>"#))
        #expect(!body.contains(#"<a href="https://example.com">https://example.com</a><em>end</em>"#))
        #expect(body.contains("https://example.com"))

        let mathBody = renderer.render("https://example.com$x$").body
        #expect(!mathBody.contains(#"<a href="https://example.com">https://example.com</a>"#))
        #expect(mathBody.contains("https://example.com"))
    }

    @Test func referenceKeyWithEntityResolves() {
        let body = renderer.render("[label][ref&amp;0]\n\n[ref&amp;0]: https://example.com/path/0").body
        #expect(body.contains(#"<a href="https://example.com/path/0">label</a>"#))
    }

    /// Figures are numbered in document order; a forward `\ref` and the
    /// captions agree even though replaceMatches evaluates image transforms in
    /// descending order. The prepare pass assigns labels ascending first.
    @Test func twoLabeledImagesUseDocumentOrderNumbering() {
        let body = renderer.render("\\ref{fig:one}\n\n![one](a.png){#fig:one} ![two](b.png){#fig:two}").body
        #expect(body.contains(##"href="#fig:one">1</a>"##))
        #expect(body.contains(#"<figcaption class="fig-caption">Figure 1: one</figcaption>"#))
        #expect(body.contains(#"<figcaption class="fig-caption">Figure 2: two</figcaption>"#))
    }

    /// Duplicate `#fig:` labels are an author error, but each image must still
    /// get its own document-order number; reading the label-keyed map after the
    /// prepare pass collapsed them to one number.
    @Test func duplicateFigureLabelsUseDistinctDocumentOrderNumbers() {
        let body = renderer.render("![one](a.png){#fig:x} ![two](b.png){#fig:x}").body
        #expect(body.contains("Figure 1: one"))
        #expect(body.contains("Figure 2: two"))
    }

    /// A labeled image dropped for an unsafe URL still consumes its number: the
    /// prepare pass numbers every labeled image in document order before any of
    /// them is rendered.
    @Test func droppedLabeledImageConsumesItsNumber() {
        let body = renderer.render("![bad](javascript:x){#fig:bad} ![good](g.png){#fig:good}").body
        #expect(body.contains("Figure 2: good"))
    }

    // MARK: - D4 token-compatibility boundary

    /// Approved D4 behavior: a token formed only *after* an escaped hyphen is
    /// restored stays literal; the one-pass resolver does not re-read its output.
    /// The pre-fix descending replacement expands it into a second `<code>x</code>`.
    @Test func tokenConstructedAfterEscapedHyphenStaysLiteral() {
        let body = renderer.render("`x` \(sentinel)MD2\\-0\(sentinel)").body
        #expect(body.contains("<code>x</code> \(sentinel)MD2-0\(sentinel)"))
    }

    /// Approved D4 behavior: when two token spellings share a sentinel, the
    /// leftmost well-formed token wins. The pre-fix highest-index replacement
    /// consumes the shared sentinel from the right instead.
    @Test func sharedSentinelResolvesLeftmostToken() {
        let input = String(repeating: "&nbsp; ", count: 10)
            + "`x` \(sentinel)MD2-1\(sentinel)MD2-10\(sentinel)"
        let body = renderer.render(input).body
        #expect(body.contains("&nbsp;MD2-10\(sentinel)"))
        #expect(!body.contains("\(sentinel)MD2-1&nbsp;"))
    }

    @Test func malformedAndOutOfRangeTokensStayLiteral() {
        let body = renderer.render(
            "`x` \(sentinel)MD2-00\(sentinel) \(sentinel)MD2-x\(sentinel) \(sentinel)MD2-99\(sentinel) \(sentinel)"
        ).body
        #expect(body.contains("<code>x</code>"))
        #expect(body.contains("\(sentinel)MD2-00\(sentinel)"))
        #expect(body.contains("\(sentinel)MD2-x\(sentinel)"))
        #expect(body.contains("\(sentinel)MD2-99\(sentinel)"))
        #expect(body.hasSuffix(" \(sentinel)</p>"))
    }

    /// Value: protects=overflowing and unterminated token indexes stay literal; fails_when=token() accepts an Int-overflowing decimal or consumes a token without its closing sentinel; why_new=no prior test covered the overflow guard or a missing closing sentinel; seam=none; no_claim=green proves only these two malformed spellings stay literal, not that all adversarial private-use sequences are preserved.
    @Test func overflowingAndUnterminatedTokensStayLiteral() {
        let overflowing = String(repeating: "9", count: 40)
        let body = renderer.render(
            "`x` \(sentinel)MD2-\(overflowing)\(sentinel) \(sentinel)MD2-0"
        ).body
        #expect(body.contains("<code>x</code>"))
        #expect(body.contains("\(sentinel)MD2-\(overflowing)\(sentinel)"))
        #expect(body.contains("\(sentinel)MD2-0"))
    }

    /// The label is inside a protected link fragment; expanding that fragment
    /// only resolves indexes below its own, so the authored forward reference
    /// stays literal.
    @Test func forwardReferenceInsideProtectedFragmentStaysLiteral() {
        let body = renderer.render("[label \(sentinel)MD2-99\(sentinel)](https://example.com)").body
        #expect(body.contains("<a href=\"https://example.com\">label \(sentinel)MD2-99\(sentinel)</a>"))
    }

    /// `protectBareAutolinks` reads the authored spelling through `source(in:)`
    /// and treats the entity token as literal (it does not terminate the URL).
    @Test func bareURLWithEntityRecoversAuthoredSpelling() {
        let body = renderer.render("https://example.com/?a=1&amp;b=2").body
        #expect(body.contains(#"href="https://example.com/?a=1&amp;b=2""#))
        #expect(body.contains(#">https://example.com/?a=1&amp;b=2</a>"#))
        #expect(!body.contains("&amp;amp;"))
    }

    // MARK: - Autolink destination classification

    @Test func autolinkWithoutDestinationIsLinked() {
        let body = renderer.render("<https://example.com>").body
        #expect(body.contains(#"<a href="https://example.com">https://example.com</a>"#))
    }

    @Test func autolinkInsideAngleDestinationIsLeftForTheLinkParser() {
        let body = renderer.render("[label](<https://example.com>)").body
        #expect(body.contains(#"<a href="https://example.com">label</a>"#))
        #expect(body.components(separatedBy: #"href="https://example.com""#).count - 1 == 1)
    }

    @Test func autolinkAfterClosedDestinationIsLinked() {
        let body = renderer.render("[label](/url) <https://example.com>").body
        #expect(body.contains(#"href="/url""#))
        #expect(body.contains(#"href="https://example.com""#))
    }

    @Test func autolinkAfterNestedParenDestinationIsLinked() {
        let body = renderer.render("[label](a(b)c) <https://example.com>").body
        #expect(body.contains(#"href="https://example.com""#))
    }

    @Test func autolinkInsideNestedParenDestinationIsNotLinkedSeparately() {
        let body = renderer.render("[label](a(b) <https://example.com>)").body
        #expect(!body.contains(#"href="https://example.com""#))
    }

    @Test func autolinkAfterEscapedParenDestinationIsLinked() {
        let body = renderer.render("[label](a\\)b) <https://example.com>").body
        #expect(body.contains(#"href="https://example.com""#))
    }

    @Test func autolinkInsideUnterminatedDestinationIsNotLinked() {
        let body = renderer.render("[label](url <https://example.com>").body
        #expect(!body.contains(#"href="https://example.com""#))
        #expect(body.contains("&lt;https://example.com&gt;"))
    }

    @Test func autolinkAfterMultipleDestinationsIsLinked() {
        let body = renderer.render("[a](/one) [b](/two) <https://example.com>").body
        #expect(body.contains(#"href="/one""#))
        #expect(body.contains(#"href="/two""#))
        #expect(body.contains(#"href="https://example.com""#))
    }

    /// Value: protects=an autolink before every `](` opener is classified outside a destination; fails_when=the nearest-opener lookup returns a span whose start is after the autolink; why_new=existing destination tests always place the autolink after at least one opener; seam=none; no_claim=green proves only the no-earlier-opener boundary, not openers elsewhere on the line.
    @Test func autolinkBeforeAnyDestinationIsLinked() {
        let body = renderer.render("<https://example.com> [label](/url)").body
        #expect(body.contains(#"href="https://example.com""#))
        #expect(body.contains(#"href="/url""#))
    }

    /// Value: protects=an autolink between two closed destinations stays linked with both links intact; fails_when=the lookup skips the nearest earlier opener or the forward builder drops inter-match text; why_new=no existing case places an autolink between two destinations; seam=none; no_claim=green proves only this between-destinations arrangement, not nearest-opener selection when an earlier span is unterminated.
    @Test func autolinkBetweenDestinationsIsLinked() {
        let body = renderer.render("[a](/one) <https://example.com> [b](/two)").body
        #expect(body.contains(#"href="/one""#))
        #expect(body.contains(#"href="https://example.com""#))
        #expect(body.contains(#"href="/two""#))
    }

    /// Value: protects=an autolink after an image `](…)` destination is linked and the image still renders; fails_when=opener detection only recognizes links or the close lookup mis-handles an image destination; why_new=existing destination tests use link syntax only; seam=none; no_claim=green proves only the image-destination-after case, not autolinks inside image destinations.
    @Test func autolinkAfterImageDestinationIsLinked() {
        let body = renderer.render("![alt](img.png) <https://example.com>").body
        #expect(body.contains(#"<img src="img.png" alt="alt">"#))
        #expect(body.contains(#"href="https://example.com""#))
    }

    /// Value: protects=an unrelated `(` does not change an autolink's classification after a real destination closes; fails_when=the index treats any `(` as an opener or computes the close level without the global balance offset; why_new=no existing test combines a non-opener paren with a real destination and autolink; seam=none; no_claim=green proves only a balanced unrelated paren before the destination, not arbitrary unbalanced-paren prefixes.
    @Test func unrelatedOpenParenBeforeDestinationKeepsClassification() {
        let body = renderer.render("(note) [label](/url) <https://example.com>").body
        #expect(body.contains(#"href="/url""#))
        #expect(body.contains(#"href="https://example.com""#))
    }

    /// Value: protects=an autolink uses the nearest opener, so a closed nearer destination wins over an earlier unterminated one; fails_when=the lookup falls back to the first opener or treats any open span as containing the autolink; why_new=existing multiple-destination tests close every earlier span; seam=none; no_claim=green proves only this nearest-closed/earlier-unterminated arrangement, not general nested-destination validity.
    @Test func nearestDestinationDeterminesContainment() {
        let body = renderer.render("[a](x (nested [b](/two) <https://example.com>").body
        #expect(body.contains(#"href="https://example.com""#))
    }

    /// Regression: ISSUE-001 — an empty destination `]()` closes before the
    /// autolink, so the autolink must still be linked. The destination index
    /// skipped a close at the first position after `(`.
    /// Found by /qa on 2026-10-19
    /// Report: .gstack/qa-reports/run-20261019T011541Z/qa-report-fix-quadratic-inline-rendering-2026-10-19.md
    @Test func autolinkAfterEmptyDestinationIsLinked() {
        let body = renderer.render("[label]() <https://example.com>").body
        #expect(body.contains(#"href="https://example.com""#))
    }

    /// Value: protects=destination classification reads Unicode scalars, the unit
    /// the link pattern matches, so a combining mark after `)` still closes the
    /// destination for autolinks and paren math alike; fails_when=the tracker reads
    /// grapheme clusters, where `)` plus a mark is not a paren; why_new=the shared
    /// tracker moved from Characters to scalars; seam=none; no_claim=only a mark
    /// after the closing paren.
    @Test func combiningMarkAfterClosingParenStillClosesTheDestination() {
        let autolink = renderer.render("[a](b)\u{301} <https://example.com>").body
        #expect(autolink.contains(#"href="https://example.com""#))

        let math = renderer.render("[a](b)\u{301} \\(x\\)").body
        #expect(math.contains(#"<span class="math math-inline">x</span>"#))
    }

    /// Regression: ISSUE-003 — an authored well-formed token in a link
    /// destination must not splice a renderer fragment into the href attribute.
    /// The destination guard rejects raw markup characters before the anchor is
    /// emitted.
    /// Value: protects=link destinations reject restored markup; fails_when=isSafeURL
    /// drops the raw-character guard; why_new=no existing test places an authored
    /// token in a destination; seam=none; no_claim=only this attribute-boundary
    /// arrangement, not every author-token placement.
    @Test func authoredTokenInDestinationCannotEscapeAttribute() {
        let body = renderer.render("![i](p.png) [l](\u{E000}MD2-0\u{E000})").body
        #expect(body.contains(#"<img src="p.png" alt="i">"#))
        #expect(!body.contains(#"href="<"#))
        #expect(body.contains("l"))
    }

    /// An authored token in a reference definition's destination must be
    /// restored before the safety check; both link and image references reject
    /// the unsafe destination.
    @Test func authoredTokenInReferenceDestinationIsRejected() {
        let link = renderer.render("`x` [label][r]\n\n[r]: \u{E000}MD2-0\u{E000}").body
        #expect(!link.contains(#"href="<"#))
        #expect(link.contains("label"))
        let image = renderer.render("`x` ![label][r]\n\n[r]: \u{E000}MD2-0\u{E000}").body
        #expect(!image.contains(#"src="<"#))
    }

    /// Entity-encoded quotes and angle brackets are safe inside a quoted
    /// attribute; the guard rejects only literal markup characters.
    @Test func encodedQuoteDestinationStaysLinked() {
        let body = renderer.render("[x](https://example.com/?q=&quot;hi&quot;)").body
        #expect(body.contains(#"href="https://example.com/?q=&quot;hi&quot;""#))
    }

    /// A combining mark after the closing sentinel must not hide the token.
    @Test func combiningMarkAfterSentinelDoesNotHideToken() {
        let body = renderer.render("`x`\u{0301}").body
        #expect(body.contains("<code>x</code>\u{0301}"))
        #expect(!body.contains("MD2-"))
    }

    /// A prepended concatenation mark (U+0600) joins the token's opening
    /// sentinel into one grapheme cluster, so the literal run before the token
    /// ends mid-cluster.
    /// Value: protects=the resolver copies literal runs with exact scalar bounds;
    /// fails_when=a run is sliced or appended at Character granularity, which
    /// drops or duplicates the mark; why_new=only a run that starts mid-cluster
    /// was covered; seam=none; no_claim=only the run before one token.
    @Test func prependedMarkBeforeSentinelIsKept() {
        let body = renderer.render("a\u{0600}`x`").body
        // Bytes, not Characters, so the cluster cannot blur the comparison.
        #expect(body.utf8.contains(">a\u{0600}<code>x</code></p>".utf8))
    }

    /// The verbatim-span scan shares the destination rule; a raw `](` still opens
    /// a pseudo-destination when its `]` is escaped, so `\(x\)` after it stays
    /// literal rather than becoming a math span.
    /// Value: protects=paren-math destination classification after an escaped `](`;
    /// fails_when=the tracker drops the escaped opener or the scan uses another
    /// classifier; why_new=the math pass had no escaped-bracket test; seam=none;
    /// no_claim=only this escaped-bracket arrangement.
    @Test func parenMathAfterEscapedBracketDestinationStaysLiteral() {
        let body = renderer.render(#"\](url \(x\)"#).body
        #expect(!body.contains("math-inline"))
        #expect(body.contains("](url (x)"))
    }

    /// A crafted token DAG in a discarded attribute must not be materialized.
    /// The eager watermark expanded every fragment; the lazy resolver expands
    /// only what the final text references. A consumed size block and a figure
    /// block both drop unknown keys, so neither image's authored source may
    /// carry the block either.
    @Test(arguments: [
        ("width=1", #"<img src="p.png" alt="a" width="1">"#),
        ("#fig:f", #"<figure class="figure" id="fig:f"><img src="p.png" alt="a">"#)
    ])
    func discardedAttributeFragmentsStayUnexpanded(_ kept: String, _ image: String) {
        let sentinel = "\u{E000}"
        func token(_ index: Int) -> String { "\(sentinel)MD2-\(index)\(sentinel)" }
        let spans = (0..<24).reversed().map { index in
            index == 0 ? "`x`" : "`" + String(repeating: token(index), count: 2) + "`"
        }.joined(separator: " ")
        let start = ContinuousClock.now
        let body = renderer.render("![a](p.png){\(kept) junk=\(spans)} `y`").body
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(body.contains(image))
        #expect(body.contains("<code>y</code>"))
    }

    // MARK: - Scaling

    @Test(arguments: Workload.allCases)
    func doublingInlineFragmentsDoesNotQuadruple(_ workload: Workload) throws {
        _ = renderer.render(workload.document(count: 32))

        let smallMS = bestOf(3) { _ = renderer.render(workload.document(count: 500)) }
        // gstack-timing-ok: quadratic scaling guard; min-of-3 and the absolute ceiling bound timer noise
        try #require(
            smallMS < 1_000,
            "\(workload.testDescription): 500 fragments took \(format(smallMS)) ms; refusing to run the doubled case"
        )

        let largeMS = bestOf(3) { _ = renderer.render(workload.document(count: 1_000)) }
        // gstack-timing-ok: quadratic scaling guard; the ratio is the primary assertion
        #expect(
            largeMS < smallMS * 3.0 + 2.0,
            "\(workload.testDescription): 500=\(format(smallMS)) ms, 1,000=\(format(largeMS)) ms"
        )
        // gstack-timing-ok: absolute ceiling that bounds CI time on a regression
        #expect(
            largeMS < 2_000,
            "\(workload.testDescription): 1,000 fragments took \(format(largeMS)) ms"
        )

        let body = renderer.render(workload.document(count: 1_000)).body
        #expect(workload.matches(body, count: 1_000), "\(workload.testDescription): rendered output is incomplete")
        #expect(!body.contains(sentinel), "\(workload.testDescription): a placeholder token leaked into the body")
        #expect(!body.contains("MD2-"), "\(workload.testDescription): an MD2- marker leaked into the body")
    }

    @Test func oneURLPerLineParagraphScalesLinearly() throws {
        try assertOnePerLineScales(.urlAutolinks)
    }

    @Test func oneBareURLPerLineParagraphScalesLinearly() throws {
        try assertOnePerLineScales(.bareURLs)
    }

    /// The authority guard's continuation walk is bounded. An unbounded walk
    /// from every candidate made a single long line quadratic (16 KB ≈ 6 s on
    /// the measured machine); the bound keeps it linear.
    @Test func repeatedTerminatedBareURLsRenderInBoundedTime() throws {
        let small = String(repeating: "www.a。", count: 1_000)
        let large = String(repeating: "www.a。", count: 2_000)
        _ = renderer.render(large)

        // gstack-timing-ok: quadratic scaling guard for the continuation scan; min-of-3 bounds timer noise
        let smallMS = bestOf(3) { _ = renderer.render(small) }
        // gstack-timing-ok: fail-fast ceiling; the unbounded scan took seconds on this input
        try #require(
            smallMS < 1_000,
            "1,000 terminated bare-URL candidates took \(format(smallMS)) ms"
        )

        // gstack-timing-ok: the ratio is the quadratic guard; unbounded is ~4x per doubling
        let largeMS = bestOf(3) { _ = renderer.render(large) }
        #expect(
            largeMS < smallMS * 3.0 + 2.0,
            "terminated bare-URL candidates: 1,000=\(format(smallMS)) ms, 2,000=\(format(largeMS)) ms"
        )
        // gstack-timing-ok: absolute ceiling that bounds CI time on a regression
        #expect(largeMS < 2_000, "2,000 terminated bare-URL candidates took \(format(largeMS)) ms")

        let body = renderer.render(large).body
        #expect(body.components(separatedBy: "。").count - 1 == 2_000, "rendered output is incomplete")
    }

    /// The email guard reads only the host-shaped prefix after each address,
    /// so a long line of addresses joined by CJK punctuation and Han text stays
    /// linear: every walk ends at the next separator.
    /// Value: protects=the email continuation walk stays bounded per address;
    /// fails_when=the walk reads the whole continuation (or past the next
    /// address) from every candidate; why_new=the bare-URL bound test does not
    /// exercise the email alternative; seam=none; no_claim=only this
    /// separator-joined workload, not every email-dense line.
    @Test func repeatedEmailAutolinksRenderInBoundedTime() throws {
        let make = { (count: Int) in String(repeating: "x@a.co然后、", count: count) }
        let small = make(1_000)
        let large = make(2_000)
        _ = renderer.render(large)

        // gstack-timing-ok: quadratic scaling guard for the email continuation walk; min-of-3 bounds timer noise
        let smallMS = bestOf(3) { _ = renderer.render(small) }
        // gstack-timing-ok: fail-fast ceiling that bounds CI time on a regression
        try #require(smallMS < 1_000, "1,000 email autolinks took \(format(smallMS)) ms")

        // gstack-timing-ok: the ratio is the quadratic guard; an unbounded walk is ~4x per doubling
        let largeMS = bestOf(3) { _ = renderer.render(large) }
        #expect(
            largeMS < smallMS * 3.0 + 2.0,
            "email autolinks: 1,000=\(format(smallMS)) ms, 2,000=\(format(largeMS)) ms"
        )
        // gstack-timing-ok: absolute ceiling that bounds CI time on a regression
        #expect(largeMS < 2_000, "2,000 email autolinks took \(format(largeMS)) ms")

        let body = renderer.render(large).body
        #expect(body.components(separatedBy: "href=\"mailto:x@a.co\"").count - 1 == 2_000, "rendered output is incomplete")
    }

    private func assertOnePerLineScales(_ workload: Workload) throws {
        _ = renderer.render(workload.onePerLine(count: 32))

        let smallMS = bestOf(3) { _ = renderer.render(workload.onePerLine(count: 1_000)) }
        // gstack-timing-ok: quadratic scaling guard; min-of-3 and the absolute ceiling bound timer noise
        try #require(
            smallMS < 1_000,
            "\(workload.testDescription) one-per-line: 1,000 fragments took \(format(smallMS)) ms"
        )

        let largeMS = bestOf(3) { _ = renderer.render(workload.onePerLine(count: 2_000)) }
        // gstack-timing-ok: quadratic scaling guard; the ratio is the primary assertion
        #expect(
            largeMS < smallMS * 3.0 + 2.0,
            "\(workload.testDescription) one-per-line: 1,000=\(format(smallMS)) ms, 2,000=\(format(largeMS)) ms"
        )
        // gstack-timing-ok: absolute ceiling that bounds CI time on a regression
        #expect(
            largeMS < 2_000,
            "\(workload.testDescription) one-per-line: 2,000 fragments took \(format(largeMS)) ms"
        )

        let body = renderer.render(workload.onePerLine(count: 2_000)).body
        #expect(workload.matches(body, count: 2_000), "\(workload.testDescription) one-per-line: rendered output is incomplete")
        #expect(!body.contains(sentinel))
        #expect(!body.contains("MD2-"))
    }

    /// Regression: the paren-math pass previously used the backward
    /// isInsideLinkDestination scan, so N `\(\)` spans on one line were O(N²).
    /// The verbatim-span scan tracks the destination rule incrementally, which
    /// keeps it linear.
    /// Value: protects=paren-math destination classification scales linearly;
    /// fails_when=the scan returns to a per-match backward scan or the
    /// destination tracker regresses; why_new=no scaling test covered the math
    /// pass; seam=none; no_claim=only the no-opener workload, not math inside
    /// real destinations.
    @Test func manyParenMathSpansScaleLinearly() throws {
        let make = { (count: Int) in
            (0..<count).map { _ in "\\(x\\)" }.joined(separator: " ")
        }
        _ = renderer.render(make(32))
        let smallMS = bestOf(3) { _ = renderer.render(make(500)) }
        // gstack-timing-ok: quadratic scaling guard; min-of-3 and the absolute ceiling bound timer noise
        try #require(smallMS < 1_000, "500 paren-math spans took \(format(smallMS)) ms")
        let largeMS = bestOf(3) { _ = renderer.render(make(1_000)) }
        // gstack-timing-ok: quadratic scaling guard; the ratio is the primary assertion
        #expect(largeMS < smallMS * 3.0 + 2.0, "500=\(format(smallMS)) ms, 1,000=\(format(largeMS)) ms")
        let body = renderer.render(make(1_000)).body
        #expect(body.components(separatedBy: "math-inline").count - 1 == 1_000)
    }

    // MARK: - Helpers

    private func bestOf(_ runs: Int, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = ContinuousClock.now
            body()
            best = min(best, milliseconds(start.duration(to: .now)))
        }
        return best
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    enum Workload: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case urlAutolinks
        case markdownLinks
        case mailtoAutolinks
        case entities
        case bareURLs
        case bareURLsWithEntities
        case referenceLinks
        case referenceLinksWithProtectedKeys
        /// Code spans and both inline math forms claimed by the one scan.
        case verbatimSpans
        /// Currency `$` signs: every `$` attempt fails at the next one.
        case unpairedDollars
        /// `\(` openers with no closer: quadratic before the scan's failure frontier.
        case unterminatedParenMath

        var testDescription: String { rawValue }

        func document(count: Int) -> String {
            switch self {
            case .urlAutolinks:
                return (0..<count).map { "<https://example.com/path/\($0)>" }.joined(separator: " ")
            case .markdownLinks:
                return (0..<count).map { "[link \($0)](https://example.com/path/\($0))" }.joined(separator: " ")
            case .mailtoAutolinks:
                return (0..<count).map { "<mailto:user\($0)@example.com>" }.joined(separator: " ")
            case .entities:
                return (0..<count).map { _ in "&nbsp;" }.joined(separator: " ")
            case .bareURLs:
                return (0..<count).map { "https://example.com/path/\($0)" }.joined(separator: " ")
            case .bareURLsWithEntities:
                return (0..<count).map { "https://example.com/?a=\($0)&amp;b=2" }.joined(separator: " ")
            case .referenceLinks, .referenceLinksWithProtectedKeys:
                let protected = self == .referenceLinksWithProtectedKeys
                let body = (0..<count).map { index -> String in
                    let key = protected ? "ref&amp;\(index)" : "ref\(index)"
                    return "[label \(index)][\(key)]"
                }.joined(separator: " ")
                let definitions = (0..<count).map { index -> String in
                    let key = protected ? "ref&amp;\(index)" : "ref\(index)"
                    return "[\(key)]: https://example.com/path/\(index)"
                }.joined(separator: "\n")
                return body + "\n\n" + definitions
            case .verbatimSpans:
                return (0..<count).map { "`c\($0)` $x_\($0)$ \\(y_\($0)\\)" }.joined(separator: " ")
            case .unpairedDollars:
                return (0..<count).map { "costs $\($0) today" }.joined(separator: " ")
            case .unterminatedParenMath:
                return (0..<count).map { "\\(x\($0)" }.joined(separator: " ")
            }
        }

        func onePerLine(count: Int) -> String {
            switch self {
            case .urlAutolinks:
                return (0..<count).map { "<https://example.com/path/\($0)>" }.joined(separator: "\n")
            case .bareURLs:
                return (0..<count).map { "https://example.com/path/\($0)" }.joined(separator: "\n")
            default:
                return document(count: count)
            }
        }

        func matches(_ body: String, count: Int) -> Bool {
            switch self {
            case .urlAutolinks, .markdownLinks, .bareURLs, .referenceLinks, .referenceLinksWithProtectedKeys:
                return body.components(separatedBy: #"href="https://example.com/path/"#).count - 1 == count
            case .mailtoAutolinks:
                return body.components(separatedBy: #"href="mailto:user"#).count - 1 == count
            case .entities:
                return body.components(separatedBy: "&nbsp;").count - 1 == count
                    && !body.contains("&amp;nbsp;")
            case .bareURLsWithEntities:
                return body.components(separatedBy: #"href="https://example.com/?a="#).count - 1 == count
                    && body.contains(#"href="https://example.com/?a=\#(count - 1)&amp;b=2""#)
                    && !body.contains("&amp;amp;")
            case .verbatimSpans:
                return body.components(separatedBy: "<code>c").count - 1 == count
                    && body.components(separatedBy: "math-inline").count - 1 == 2 * count
            case .unpairedDollars:
                return body.components(separatedBy: "$").count - 1 == count && !body.contains("math-inline")
            case .unterminatedParenMath:
                return body.components(separatedBy: "(x").count - 1 == count && !body.contains("math-inline")
            }
        }
    }
}
