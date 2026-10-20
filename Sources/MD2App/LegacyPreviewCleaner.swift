import Foundation

/// Old builds wrote preview HTML beside the Markdown file. Only their UUID
/// filenames are eligible, and recent files are left alone for a running old
/// app instance. Callers run this on a background task at launch or file open.
enum LegacyPreviewCleaner {
    static func clean(in directory: URL, now: Date = Date()) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory,
                                                            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        let cutoff = now.addingTimeInterval(-3600)
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix(".md2-preview-"), name.hasSuffix(".html"),
                  UUID(uuidString: String(name.dropFirst(".md2-preview-".count).dropLast(".html".count))) != nil,
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try? manager.removeItem(at: file)
        }
    }
}
