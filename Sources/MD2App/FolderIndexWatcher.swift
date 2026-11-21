import CoreServices
import Foundation

/// Observes the entire selected subtree with one stream. Opening or focusing
/// a tab never touches the filesystem through the index.
final class FolderIndexWatcher {
    private let stream: FSEventStreamRef

    init?(root: FolderIndex.Root, onChange: @escaping @MainActor () -> Void) {
        let path = root.url.path
        let callback = Callback(pathPrefix: path == "/" ? path : path + "/", onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                if let info { Unmanaged<Callback>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        let paths = [path] as CFArray
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            guard FolderIndexWatcher.changesIndex(count: count, paths: paths, flags: flags,
                                                  rootPrefix: callback.pathPrefix) else {
                return
            }
            Task { @MainActor in callback.onChange() }
        }, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, options) else { return nil }

        FSEventStreamSetDispatchQueue(stream, .global(qos: .utility))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private final class Callback: Sendable {
        let pathPrefix: String
        let onChange: @MainActor () -> Void

        init(pathPrefix: String, onChange: @escaping @MainActor () -> Void) {
            self.pathPrefix = pathPrefix
            self.onChange = onChange
        }
    }

    private static func changesIndex(count: Int, paths: UnsafeMutableRawPointer,
                                     flags: UnsafePointer<FSEventStreamEventFlags>, rootPrefix: String) -> Bool {
        let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        let recheckSubtree = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        )
        let changesEntries = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemFinderInfoMod
                | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemXattrMod
                | kFSEventStreamEventFlagItemCloned
        )
        for index in 0..<count {
            let event = flags[index]
            if event & recheckSubtree != 0 { return true }
            guard event & changesEntries != 0 else { continue }
            guard let path = paths[index].flatMap({ String(validatingCString: $0) }) else { continue }
            if path.hasPrefix(rootPrefix) {
                let components = path.dropFirst(rootPrefix.count).split(separator: "/")
                if components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) { continue }
            }
            if event & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                || FolderIndex.isMarkdownExtension((path as NSString).pathExtension) { return true }
        }
        return false
    }
}
