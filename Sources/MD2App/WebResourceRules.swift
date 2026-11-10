import Foundation
import MD2Core
import WebKit

/// Independent of page markup: even a page missing its CSP cannot make a
/// request outside the native caller's permission. The image exception applies
/// only within its own list; a separately installed deny list always wins.
@MainActor
enum WebResourceRules {
    struct Lists {
        let blocked: WKContentRuleList
        let images: WKContentRuleList
    }

    nonisolated static func json(for policy: RemoteResourcePolicy) -> String {
        let deny = #"{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}"#
        let image = #"{"trigger":{"url-filter":"^https?://","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}"#
        return "[" + deny + (policy == .allowRemoteImages ? "," + image : "") + "]"
    }

    /// Compiled constants contain no document URL or saved permission. Keep the
    /// cache private to this process instead of modifying a user's default store.
    private static let compilation = Task<Lists, Error> { @MainActor in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-resource-rules-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let store = WKContentRuleListStore(url: directory) else { throw URLError(.cannotCreateFile) }
        @MainActor func compile(_ policy: RemoteResourcePolicy, identifier: String) async throws -> WKContentRuleList {
            try await withCheckedThrowingContinuation { continuation in
                store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json(for: policy)) { rules, error in
                    if let rules { continuation.resume(returning: rules) }
                    else { continuation.resume(throwing: error ?? URLError(.cannotParseResponse)) }
                }
            }
        }
        let blocked = try await compile(.blocked, identifier: "md2-deny-remote-v1")
        let images = try await compile(.allowRemoteImages, identifier: "md2-remote-images-v1")
        return Lists(blocked: blocked, images: images)
    }

    static func compiled() async throws -> Lists { try await compilation.value }
}
