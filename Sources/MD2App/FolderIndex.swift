import Darwin
import Foundation
import UniformTypeIdentifiers

/// An in-memory, metadata-only view of one explicitly selected directory.
enum FolderIndex {
    enum Failure: Error {
        case rootUnavailable
        case fileUnavailable
        case fileTooLarge
    }

    enum FavoriteFailure: Error, Equatable {
        case missingOrMoved
        case permissionDenied
        case symbolicLinkOrAlias
        case unavailable
    }

    struct Limits: Sendable {
        var entries = 20_000
        var files = 2_000
        var depth = 24
    }

    struct Root: Equatable, Sendable {
        let url: URL
        fileprivate let identity: Identity
        let favoriteRemoteImageGrantID: String?

        static func == (lhs: Root, rhs: Root) -> Bool {
            lhs.url == rhs.url && lhs.identity == rhs.identity
        }
    }

    struct File: Identifiable, Equatable, Sendable {
        let url: URL
        let relativePath: String
        var id: String { url.absoluteString }
        var name: String { leaf.name }

        fileprivate let root: Root
        fileprivate let ancestors: [Component]
        fileprivate let leaf: Component
    }

    struct Node: Identifiable, Sendable {
        let id: String
        let name: String
        let children: [Node]?
        let file: File?

        fileprivate var files: [File] {
            if let file { return [file] }
            return children?.flatMap(\.files) ?? []
        }
    }

    struct Snapshot: Sendable {
        let nodes: [Node]
        let files: [File]
        let isLimited: Bool
        let hasUnreadableItems: Bool
    }

    struct OpenedFile: Sendable {
        let url: URL
        let data: Data
        let fileReference: DocumentCopyFileReference
        let fingerprint: DocumentFileFingerprint
        fileprivate let file: File
        fileprivate let stamp: ReadStamp

        /// The caller also checks this at the handoff to the document store.
        func validate() throws {
            try FolderIndex.withParent(of: file, in: file.root) { directory, leaf in
                let info = try FolderIndex.inspectFile(leaf, in: directory)
                guard ReadStamp(info) == stamp, DocumentCopyFileIdentity(info) == fileReference.identity else {
                    throw Failure.fileUnavailable
                }
            }
        }
    }

    fileprivate struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec
            birthNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }

    fileprivate struct Component: Equatable, Sendable {
        let name: String
        let identity: Identity
    }

    fileprivate struct ReadStamp: Equatable, Sendable {
        let size: off_t
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int

        init(_ info: stat) {
            size = info.st_size
            modificationSeconds = info.st_mtimespec.tv_sec
            modificationNanoseconds = info.st_mtimespec.tv_nsec
            changeSeconds = info.st_ctimespec.tv_sec
            changeNanoseconds = info.st_ctimespec.tv_nsec
        }

        var modificationDate: Date {
            Date(timeIntervalSince1970: Double(modificationSeconds) + Double(modificationNanoseconds) / 1e9)
        }
    }

    static let maximumOpenBytes = 32 * 1024 * 1024
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
    private static let markdownExtensions: Set<String> = ["md", "markdown"]

    static func isMarkdownExtension(_ suffix: String) -> Bool {
        markdownExtensions.contains(suffix.lowercased())
    }

    /// The selected item must be a real directory. Normalize existing ancestor
    /// links (for example /var on macOS) once; future operations require that
    /// same directory at its canonical path, with no inserted symlinks.
    static func authorize(_ selectedURL: URL) throws -> Root {
        try Task.checkCancellation()
        guard selectedURL.isFileURL else { throw Failure.rootUnavailable }
        var selected = stat()
        guard lstat(selectedURL.path, &selected) == 0, selected.st_mode & S_IFMT == S_IFDIR else {
            throw Failure.rootUnavailable
        }
        // Foundation may normalize /private/var back to /var even after
        // resolving symlinks. Keep the actual kernel pathname for no-follow
        // opens of the entire root path.
        guard let path = canonicalPath(of: selectedURL) else { throw Failure.rootUnavailable }
        let root: Root
        do {
            root = try authorizeCanonicalPath(path)
        } catch is FavoriteFailure {
            throw Failure.rootUnavailable
        }
        guard root.identity == Identity(selected) else { throw Failure.rootUnavailable }
        return root
    }

    static func canonicalPath(of url: URL) -> String? {
        guard url.isFileURL, let canonical = realpath(url.path, nil) else { return nil }
        defer { free(canonical) }
        return String(validatingCString: canonical)
    }

    /// A favorite already has a canonical path. Reauthorize that exact
    /// pathname, rejecting links even when they resolve to the same directory.
    static func authorizeFavorite(_ url: URL) throws -> Root {
        try Task.checkCancellation()
        guard url.isFileURL else { throw FavoriteFailure.unavailable }
        return try authorizeCanonicalPath(url.path, requiresSearchPermission: true)
    }

    /// Validates preference paths lexically. Keep the exact realpath bytes;
    /// Foundation's file path initializer can decompose Unicode characters.
    static func canonicalDirectoryURL(for path: String) -> URL? {
        let slash = UInt8(ascii: "/")
        let bytes = path.utf8
        guard bytes.first == slash, !bytes.contains(0) else { return nil }
        if bytes.count > 1 {
            let components = bytes.dropFirst().split(separator: slash, omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty && !$0.elementsEqual(".".utf8) && !$0.elementsEqual("..".utf8) }) else {
                return nil
            }
        }
        return bytePreservingFileURL(at: path == "/" ? path : path + "/")
    }

    private static func authorizeCanonicalPath(_ path: String, requiresSearchPermission: Bool = false) throws -> Root {
        guard let url = canonicalDirectoryURL(for: path) else { throw FavoriteFailure.unavailable }
        let descriptor = Darwin.open(path, directoryFlags | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else {
            let error = errno
            // Finder aliases are files. Only inspect their metadata to explain
            // why the no-follow directory open failed.
            if error == ENOTDIR, let flags = try? finderFlags(path, in: AT_FDCWD), flags.contains(.alias) {
                throw FavoriteFailure.symbolicLinkOrAlias
            }
            throw favoriteFailure(for: error)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw favoriteFailure(for: errno) }
        if requiresSearchPermission, faccessat(descriptor, ".", X_OK, AT_EACCESS) != 0 {
            throw favoriteFailure(for: errno)
        }
        try Task.checkCancellation()
        let identity = Identity(info)
        let grantID = persistentDirectoryGrantID(descriptor: descriptor, identity: identity)
        return Root(url: url, identity: identity, favoriteRemoteImageGrantID: grantID)
    }

    /// A device number can change across reboots. Only volumes that expose
    /// a UUID and persistent object identifiers can carry a favorite grant.
    private static func persistentDirectoryGrantID(descriptor: Int32, identity: Identity) -> String? {
        guard identity.birthSeconds > 0 else { return nil }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = ATTR_VOL_INFO | UInt32(ATTR_VOL_CAPABILITIES | ATTR_VOL_UUID)
        let capabilitiesOffset = MemoryLayout<UInt32>.size
        let uuidOffset = capabilitiesOffset + MemoryLayout<vol_capabilities_attr_t>.size
        var buffer = [UInt8](repeating: 0, count: uuidOffset + MemoryLayout<uuid_t>.size)
        return buffer.withUnsafeMutableBytes { bytes in
            guard fgetattrlist(descriptor, &attributes, bytes.baseAddress!, bytes.count, 0) == 0,
                  bytes.loadUnaligned(as: UInt32.self) == UInt32(bytes.count) else { return nil }
            let caps = bytes.loadUnaligned(fromByteOffset: capabilitiesOffset, as: vol_capabilities_attr_t.self)
            let persistentIDs = UInt32(VOL_CAP_FMT_PERSISTENTOBJECTIDS)
            guard caps.valid.0 & persistentIDs != 0, caps.capabilities.0 & persistentIDs != 0,
                  bytes[uuidOffset...].contains(where: { $0 != 0 }) else { return nil }
            let volume = UUID(uuid: bytes.loadUnaligned(fromByteOffset: uuidOffset, as: uuid_t.self))
            return "v1/\(volume.uuidString)/\(identity.inode)/\(identity.birthSeconds)/\(identity.birthNanoseconds)"
        }
    }

    private static func favoriteFailure(for error: Int32) -> FavoriteFailure {
        switch error {
        case ENOENT, ENXIO, ESTALE, ENODEV: .missingOrMoved
        case EACCES, EPERM: .permissionDenied
        case ELOOP: .symbolicLinkOrAlias
        default: .unavailable
        }
    }

    static func scan(_ root: Root, limits: Limits = .init()) throws -> Snapshot {
        try Task.checkCancellation()
        var scanner = Scanner(root: root, limits: limits)
        let nodes = try withRoot(root) { descriptor in
            try scanner.visit(descriptor, url: root.url, ancestors: [])
        }
        try Task.checkCancellation()
        try withRoot(root) { _ in }
        return Snapshot(nodes: nodes, files: nodes.flatMap(\.files),
                        isLimited: scanner.isLimited, hasUnreadableItems: scanner.hasUnreadableItems)
    }

    static func isCurrent(_ root: Root) -> Bool {
        (try? withRoot(root) { descriptor in
            guard faccessat(descriptor, ".", X_OK, AT_EACCESS) == 0 else { return false }
            guard let grantID = root.favoriteRemoteImageGrantID else { return true }
            return persistentDirectoryGrantID(descriptor: descriptor, identity: root.identity) == grantID
        }) == true
    }

    /// Checks the actual backing entry, independently of the bounded browser
    /// index. The expected identity must come from a still-pinned document.
    /// The path is walked from the authorized root without opening file contents.
    static func verifyRemoteImageMember(at url: URL, in root: Root, reference: DocumentCopyFileReference) -> URL? {
        guard let verified = verifiedRemoteImagePath(at: url, in: root, identity: reference.identity),
              let actualPath = reference.currentPath() else { return nil }
        if actualPath.utf8.elementsEqual(verified.path.utf8) { return verified }
        // Filesystems that ignore case or normalization can accept alternate
        // spellings. Recheck the actual entry and use that spelling for vetoes.
        guard let actualURL = bytePreservingFileURL(at: actualPath) else { return nil }
        return verifiedRemoteImagePath(at: actualURL, in: root, identity: reference.identity)
    }

    private static func verifiedRemoteImagePath(at url: URL, in root: Root, identity: DocumentCopyFileIdentity) -> URL? {
        guard let path = remoteImageMemberPath(url, in: root), let leaf = path.last,
              isMarkdownExtension((leaf as NSString).pathExtension) else { return nil }
        return try? withRoot(root) { descriptor in
            try verifyRemoteImageEntry(path[...], in: descriptor, root: root, identity: identity)
            guard isCurrent(root) else { throw Failure.rootUnavailable }
            let prefix = root.url.path == "/" ? "/" : root.url.path + "/"
            return bytePreservingFileURL(at: prefix + path.joined(separator: "/"))
        }
    }

    private static func bytePreservingFileURL(at path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "file"
        components.host = ""
        components.path = path
        return components.url
    }

    private static func remoteImageMemberPath(_ url: URL, in root: Root) -> [String]? {
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost",
              url.query == nil, url.fragment == nil else { return nil }
        let prefix = root.url.path == "/" ? "/" : root.url.path + "/"
        var path = url.path
        if !path.utf8.starts(with: prefix.utf8),
           path.hasPrefix("/var/") || path.hasPrefix("/tmp/") || path.hasPrefix("/etc/") {
            // Foundation can expose these system aliases even after resolving
            // a file URL. The descriptor walk still uses the canonical root.
            path = "/private" + path
        }
        guard path.utf8.starts(with: prefix.utf8) else { return nil }
        let relative = path.utf8.dropFirst(prefix.utf8.count)
        let parts = relative.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        guard parts.count <= Limits().depth + 1,
              parts.allSatisfy({ !$0.isEmpty && $0.first != UInt8(ascii: ".") && !$0.contains(0) }) else { return nil }
        return parts.map { String(decoding: $0, as: UTF8.self) }
    }

    private static func verifyRemoteImageEntry(_ parts: ArraySlice<String>, in directory: Int32,
                                               root: Root, identity: DocumentCopyFileIdentity) throws {
        guard let name = parts.first else { throw Failure.fileUnavailable }
        if parts.count == 1 {
            let info = try inspectFile(named: name, in: directory)
            guard info.st_dev == root.identity.device, DocumentCopyFileIdentity(info) == identity,
                  faccessat(directory, name, R_OK, AT_EACCESS | AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Failure.fileUnavailable
            }
            return
        }

        guard name != "node_modules", !isPackageDirectoryExtension((name as NSString).pathExtension.lowercased()) else {
            throw Failure.fileUnavailable
        }
        let child = openat(directory, name, directoryFlags | O_NOFOLLOW)
        guard child >= 0 else { throw Failure.fileUnavailable }
        defer { Darwin.close(child) }
        var info = stat()
        guard fstat(child, &info) == 0, info.st_dev == root.identity.device,
              info.st_flags & UInt32(UF_HIDDEN) == 0 else { throw Failure.fileUnavailable }
        let flags = try finderFlags(name, in: directory)
        guard flags.intersection([.invisible, .bundle]).isEmpty else { throw Failure.fileUnavailable }
        try verifyRemoteImageEntry(parts.dropFirst(), in: child, root: root, identity: identity)
        // Each ancestor must still name the directory traversed above.
        let checked = Identity(info)
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, Identity(info) == checked else {
            throw Failure.fileUnavailable
        }
    }

    static func open(_ file: File, in root: Root) throws -> OpenedFile {
        try Task.checkCancellation()
        let (reference, data, stamp) = try withParent(of: file, in: root) { directory, leaf in
            let info = try inspectFile(leaf, in: directory)
            guard info.st_size >= 0, info.st_size <= maximumOpenBytes else { throw Failure.fileTooLarge }
            do {
                let reference = try DocumentCopyFileReference.open(at: directory, name: leaf.name,
                    matching: DocumentCopyFileIdentity(info))
                let birthTime = reference.birthTime
                guard birthTime.second == leaf.identity.birthSeconds,
                      birthTime.nanosecond == leaf.identity.birthNanoseconds else {
                    throw Failure.fileUnavailable
                }
                let data = try reference.readPinned(expectedCount: Int(info.st_size))
                return (reference, data, ReadStamp(info))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure.fileUnavailable
            }
        }
        let fingerprint = DocumentFileFingerprint(modificationDate: stamp.modificationDate,
                                                   contentHash: DocumentFileFingerprint.hash(of: data))
        let result = OpenedFile(url: file.url, data: data, fileReference: reference,
                                fingerprint: fingerprint, file: file, stamp: stamp)
        try Task.checkCancellation()
        try result.validate()
        return result
    }

    private static func withRoot<T>(_ root: Root, _ body: (Int32) throws -> T) throws -> T {
        let descriptor = Darwin.open(root.url.path, directoryFlags | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { throw Failure.rootUnavailable }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Identity(info) == root.identity else {
            throw Failure.rootUnavailable
        }
        return try body(descriptor)
    }

    private static func withParent<T>(of file: File, in root: Root,
                                      _ body: (Int32, Component) throws -> T) throws -> T {
        guard file.root == root else { throw Failure.fileUnavailable }
        return try withRoot(root) { rootDescriptor in
            var parent = rootDescriptor
            defer { if parent != rootDescriptor { Darwin.close(parent) } }

            for component in file.ancestors {
                let flags = try finderFlags(component.name, in: parent)
                guard !flags.contains(.invisible), !flags.contains(.bundle) else {
                    throw Failure.fileUnavailable
                }
                let child = openat(parent, component.name, directoryFlags | O_NOFOLLOW)
                guard child >= 0 else { throw Failure.fileUnavailable }
                if parent != rootDescriptor { Darwin.close(parent) }
                parent = child
                var info = stat()
                guard fstat(child, &info) == 0, Identity(info) == component.identity,
                      info.st_flags & UInt32(UF_HIDDEN) == 0 else { throw Failure.fileUnavailable }
            }
            return try body(parent, file.leaf)
        }
    }

    private static func inspectFile(_ leaf: Component, in directory: Int32) throws -> stat {
        let info = try inspectFile(named: leaf.name, in: directory)
        guard Identity(info) == leaf.identity else { throw Failure.fileUnavailable }
        return info
    }

    private static func inspectFile(named name: String, in directory: Int32) throws -> stat {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_flags & UInt32(UF_HIDDEN) == 0 else {
            throw Failure.fileUnavailable
        }
        let flags = try finderFlags(name, in: directory)
        guard flags.intersection([.invisible, .alias]).isEmpty else { throw Failure.fileUnavailable }
        return info
    }

    private static func isPackageDirectoryExtension(_ suffix: String) -> Bool {
        guard !suffix.isEmpty else { return false }
        let type = UTType(filenameExtension: suffix, conformingTo: .directory)
        return type?.conforms(to: .package) == true || type == .framework
    }

    private struct FinderFlags: OptionSet {
        let rawValue: UInt16
        static let bundle = Self(rawValue: 0x2000)
        static let invisible = Self(rawValue: 0x4000)
        static let alias = Self(rawValue: 0x8000)
    }

    private static func finderFlags(_ name: String, in directory: Int32) throws -> FinderFlags {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = ATTR_CMN_RETURNED_ATTRS | attrgroup_t(ATTR_CMN_FNDRINFO)
        // The result length and available-attribute set precede FinderInfo.
        // Filesystems without FinderInfo return the zero-filled placeholder.
        // Its big-endian finderFlags field is at offset 8 for files and folders.
        let finderOffset = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
        var buffer = [UInt8](repeating: 0, count: finderOffset + 32)
        let status = buffer.withUnsafeMutableBytes {
            getattrlistat(directory, name, &attributes, $0.baseAddress!, $0.count,
                          UInt(FSOPT_NOFOLLOW | FSOPT_NOFOLLOW_ANY | FSOPT_PACK_INVAL_ATTRS))
        }
        guard status == 0 else { throw Failure.fileUnavailable }
        let bits = UInt16(buffer[finderOffset + 8]) << 8 | UInt16(buffer[finderOffset + 9])
        return FinderFlags(rawValue: bits)
    }

    private struct Scanner {
        let root: Root
        let limits: Limits
        var isLimited = false
        var hasUnreadableItems = false
        private var examined = 0
        private var indexed = 0
        private var packageExtensions: [String: Bool] = [:]

        init(root: Root, limits: Limits) {
            self.root = root
            self.limits = limits
        }

        mutating func visit(_ directory: Int32, url: URL, ancestors: [Component]) throws -> [Node] {
            let duplicate = fcntl(directory, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else {
                if ancestors.isEmpty { throw Failure.rootUnavailable }
                hasUnreadableItems = true
                return []
            }
            guard let stream = fdopendir(duplicate) else {
                Darwin.close(duplicate)
                if ancestors.isEmpty { throw Failure.rootUnavailable }
                hasUnreadableItems = true
                return []
            }
            defer { closedir(stream) }

            var nodes: [Node] = []
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 {
                        if ancestors.isEmpty { throw Failure.rootUnavailable }
                        hasUnreadableItems = true
                    }
                    break
                }
                let record = entry.pointee
                let name = withUnsafeBytes(of: record.d_name) {
                    String(validating: $0.prefix(Int(record.d_namlen)), as: UTF8.self)
                }
                if name == "." || name == ".." { continue }
                guard examined < limits.entries, indexed < limits.files else {
                    isLimited = true
                    break
                }
                examined += 1
                guard let name, !name.hasPrefix("."), record.d_type != DT_LNK else { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                let isMarkdown = isMarkdownExtension(ext)
                guard record.d_type == DT_DIR || record.d_type == DT_UNKNOWN || isMarkdown else {
                    continue
                }

                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    hasUnreadableItems = true
                    continue
                }
                guard info.st_dev == root.identity.device, info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                let isDirectory = info.st_mode & S_IFMT == S_IFDIR
                guard isDirectory || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 &&
                                      isMarkdown) else { continue }
                guard !isDirectory || (name != "node_modules" && !isPackageExtension(ext)) else { continue }

                guard let flags = try? finderFlags(name, in: directory) else {
                    hasUnreadableItems = true
                    continue
                }
                guard flags.intersection([.invisible, isDirectory ? .bundle : .alias]).isEmpty else { continue }
                let component = Component(name: name, identity: Identity(info))
                let itemURL = url.appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory)
                if isDirectory {
                    guard ancestors.count < limits.depth else {
                        isLimited = true
                        continue
                    }
                    if let node = try visitChild(component, in: directory, url: itemURL, ancestors: ancestors) {
                        nodes.append(node)
                    }
                } else {
                    let relativePath = (ancestors.map(\.name) + [name]).joined(separator: "/")
                    let file = File(url: itemURL, relativePath: relativePath,
                                    root: root, ancestors: ancestors, leaf: component)
                    nodes.append(Node(id: file.id, name: name, children: nil, file: file))
                    indexed += 1
                }
            }
            return nodes.sorted(by: Self.precedes)
        }

        private mutating func visitChild(_ component: Component, in directory: Int32, url: URL,
                                         ancestors: [Component]) throws -> Node? {
            let child = openat(directory, component.name, directoryFlags | O_NOFOLLOW)
            guard child >= 0 else {
                hasUnreadableItems = true
                return nil
            }
            defer { Darwin.close(child) }
            var info = stat()
            guard fstat(child, &info) == 0, Identity(info) == component.identity else {
                hasUnreadableItems = true
                return nil
            }
            let children = try visit(child, url: url, ancestors: ancestors + [component])
            guard !children.isEmpty else { return nil }
        guard fstatat(directory, component.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(info) == component.identity else {
            hasUnreadableItems = true
            return nil
        }
            return Node(id: url.absoluteString, name: component.name, children: children, file: nil)
        }

        private mutating func isPackageExtension(_ suffix: String) -> Bool {
            guard !suffix.isEmpty else { return false }
            if let cached = packageExtensions[suffix] { return cached }
            let isPackage = isPackageDirectoryExtension(suffix)
            packageExtensions[suffix] = isPackage
            return isPackage
        }

        private static func precedes(_ lhs: Node, _ rhs: Node) -> Bool {
            if (lhs.children == nil) != (rhs.children == nil) { return lhs.children != nil }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
