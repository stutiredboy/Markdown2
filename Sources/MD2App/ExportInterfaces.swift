import Foundation
import MD2Core

@MainActor
protocol PDFExporting: AnyObject {
    func export(
        html: String,
        outline: [Heading],
        baseURL: URL?,
        remoteResourcePolicy: RemoteResourcePolicy,
        documentTitle: String,
        remoteImageBlockedLabel: String,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func cancel()
}

extension PDFExporting {
    func export(html: String, outline: [Heading], baseURL: URL?, remoteResourcePolicy: RemoteResourcePolicy,
                documentTitle: String, completion: @escaping (Result<Void, Error>) -> Void) {
        export(html: html, outline: outline, baseURL: baseURL, remoteResourcePolicy: remoteResourcePolicy,
               documentTitle: documentTitle, remoteImageBlockedLabel: "Remote image blocked", completion: completion)
    }
    /// Existing callers without a document grant always take the blocked path.
    func export(html: String, outline: [Heading], baseURL: URL?, documentTitle: String,
                completion: @escaping (Result<Void, Error>) -> Void) {
        export(html: html, outline: outline, baseURL: baseURL, remoteResourcePolicy: .blocked,
               documentTitle: documentTitle, completion: completion)
    }
}

@MainActor
protocol DocumentPrinting: AnyObject {
    func print(
        html: String,
        outline: [Heading],
        baseURL: URL?,
        remoteResourcePolicy: RemoteResourcePolicy,
        profile: ExportProfile,
        documentTitle: String,
        remoteImageBlockedLabel: String,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func cancel()
}

extension DocumentPrinting {
    func print(html: String, outline: [Heading], baseURL: URL?, remoteResourcePolicy: RemoteResourcePolicy,
               profile: ExportProfile, documentTitle: String, completion: @escaping (Result<Void, Error>) -> Void) {
        print(html: html, outline: outline, baseURL: baseURL, remoteResourcePolicy: remoteResourcePolicy,
              profile: profile, documentTitle: documentTitle, remoteImageBlockedLabel: "Remote image blocked", completion: completion)
    }
    func print(html: String, outline: [Heading], baseURL: URL?, profile: ExportProfile,
               documentTitle: String, completion: @escaping (Result<Void, Error>) -> Void) {
        print(html: html, outline: outline, baseURL: baseURL, remoteResourcePolicy: .blocked,
              profile: profile, documentTitle: documentTitle, completion: completion)
    }
}
