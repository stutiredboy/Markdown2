import Foundation

/// The two versions displayed by the comparison sheet. A decision applies only
/// to this request, editor revision, path, disk identity and disk content.
struct ExternalConflictComparison: Sendable {
    let request: ExternalConflictRequest
    let documentID: UUID
    let editorRevision: Int
    let editorText: String
    let editorFormat: MarkdownFileFormat
    let url: URL
    let disk: DiskVersion
    let decoded: MarkdownFileDecoder.DecodedFile?
    var diskText: String? { decoded?.text }
    var diskFormat: MarkdownFileFormat? { decoded?.format }

    struct DiskVersion: Equatable, Sendable {
        let identity: DocumentCopyFileIdentity
        let contentHash: Data

        /// Preserve the stronger identity contract for folder/copy documents.
        /// Ordinary documents may have hard links or a final symlink. Pin a
        /// regular file and validate the read before presenting its bytes.
        static func read(at url: URL, reference: DocumentCopyFileReference?) throws -> (DiskVersion, Data) {
            let data: Data
            let identity: DocumentCopyFileIdentity
            if let reference {
                data = try reference.read(at: url)
                identity = reference.identity
            } else {
                let file = try DocumentLinkedSaveFile(at: url, writable: false)
                let contents = try file.read()
                data = contents.data
                identity = try DocumentCopyFileIdentity(file.validate(matching: contents))
            }
            return (DiskVersion(identity: identity, contentHash: DocumentFileFingerprint.hash(of: data)), data)
        }
    }
}
