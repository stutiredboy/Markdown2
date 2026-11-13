import Foundation
import Network

/// Request evidence shared by native export tests. Each instance has a fresh
/// loopback port; callers put a unique token in every path. No URLProtocol mock.
final class ExportNetworkTestServer: @unchecked Sendable {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
    struct Request: Sendable { let path: String; let header: String; let date: Date }
    private let listener: NWListener
    private let lock = NSLock()
    private var records: [Request] = []
    private var connections: [NWConnection] = []
    private var delayed: [NWConnection] = []
    private let image: Data
    private(set) var port: UInt16 = 0
    var requests: [Request] { lock.withLock { records } }
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(image: Data = ExportNetworkTestServer.png) throws {
        self.image = image
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: .global())
            self.receive(connection, prefix: Data())
        }
        listener.start(queue: DispatchQueue(label: "md2-export-server"))
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue else {
            listener.cancel(); throw URLError(.cannotConnectToHost)
        }
        port = bound
    }

    private func receive(_ connection: NWConnection, prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            let data = prefix + (bytes ?? Data())
            guard data.count <= 32_768 else { connection.cancel(); return }
            guard let header = String(data: data, encoding: .utf8), header.contains("\r\n\r\n") else {
                if !complete, error == nil { self.receive(connection, prefix: data) }
                else { connection.cancel() }
                return
            }
            let path = header.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            self.lock.withLock { self.records.append(Request(path: path, header: header, date: Date())) }
            if path.contains("slow") {
                self.lock.withLock { self.delayed.append(connection) }
            } else if path.contains("redirect") {
                self.respond(connection, status: "302 Found", body: Data(), extra: "Location: \(self.baseURL)/redirect-target.png\r\n")
            } else if path.contains("broken") {
                self.respond(connection, body: Data("not an image".utf8))
            } else {
                self.respond(connection, body: self.image)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String = "200 OK", body: Data, extra: String = "") {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: image/png\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n\(extra)Connection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    func releaseDelayed() {
        let pending = lock.withLock { let copy = delayed; delayed.removeAll(); return copy }
        pending.forEach { respond($0, body: image) }
    }

    func stop() {
        ExportTestEvidence.saveRequests(requests, port: port)
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections.removeAll(); delayed.removeAll() }
    }
}

enum ExportTestEvidence {
    private static var root: URL? {
        ProcessInfo.processInfo.environment["MD2_EXPORT_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func preserveThenRemove(_ directory: URL) {
        if let root {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: directory, to: root.appendingPathComponent(directory.lastPathComponent))
        }
        try? FileManager.default.removeItem(at: directory)
    }

    static func preservePrint(_ url: URL) {
        guard let root else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: url, to: root.appendingPathComponent(url.lastPathComponent))
    }

    static func saveRequests(_ requests: [ExportNetworkTestServer.Request], port: UInt16) {
        guard let root else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let object: [String: Any] = ["port": port, "count": requests.count,
            "requests": requests.map { ["path": $0.path, "header": $0.header, "date": $0.date.timeIntervalSince1970] as [String: Any] }]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("requests-\(port)-\(UUID()).json"))
        }
    }
}
