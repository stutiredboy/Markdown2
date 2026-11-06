import Foundation

/// A file's identity and a location inside it are separate. In particular,
/// fragments must not become part of the URL stored in recovery or recents.
struct DocumentLinkTarget {
    let fileURL: URL
    let fragment: String?

    init(_ url: URL) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            fileURL = url
            fragment = nil
            return
        }
        // URLComponents decodes exactly once, including non-ASCII heading IDs.
        fragment = parts.fragment
        parts.fragment = nil
        parts.query = nil
        fileURL = parts.url ?? url
    }
}
