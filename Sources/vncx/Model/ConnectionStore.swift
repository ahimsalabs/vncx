import VNCCore
import Foundation
import Observation
import AppKit

struct SavedConnection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 5900
    var username = ""
    /// Set for computers discovered via Bonjour; the service name is resolved at connect time.
    var bonjourName: String?
    var quality: Quality = Preferences.shared.defaultQuality
    var scaling: ScalingMode = Preferences.shared.defaultScaling
    var viewOnly = false
    var remoteResizeRetina = false
    var lastConnected: Date?
    var lastResolution: String?

    var title: String { name.isEmpty ? (bonjourName ?? Address(host: host, port: port).display) : name }
    var subtitle: String {
        let addr = bonjourName != nil ? "Bonjour" : Address(host: host, port: port).display
        return username.isEmpty ? addr : "\(username)@\(addr)"
    }
    var keychainAccount: String { Keychain.account(host: bonjourName ?? host, port: port, username: username) }
}

/// Persists saved connections as JSON in Application Support.
@Observable
final class ConnectionStore {
    static let shared = ConnectionStore()

    private(set) var connections: [SavedConnection] = []
    /// Bumped when a thumbnail changes so cards reload their images.
    var thumbnailGeneration = 0

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("vncx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Thumbnails"), withIntermediateDirectories: true)
        return dir
    }()
    private var fileURL: URL { Self.directory.appendingPathComponent("connections.json") }

    private init() { load() }

    var sorted: [SavedConnection] {
        connections.sorted { a, b in
            switch (a.lastConnected, b.lastConnected) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    func connection(_ id: UUID) -> SavedConnection? { connections.first { $0.id == id } }

    func upsert(_ c: SavedConnection) {
        if let i = connections.firstIndex(where: { $0.id == c.id }) { connections[i] = c } else { connections.append(c) }
        save()
    }

    func delete(_ c: SavedConnection) {
        connections.removeAll { $0.id == c.id }
        try? FileManager.default.removeItem(at: thumbnailURL(c.id))
        save()
    }

    /// Finds an existing entry for the same host/port/user (so quick-connects reuse history).
    func match(host: String, port: Int, username: String, bonjourName: String?) -> SavedConnection? {
        if let bonjourName { return connections.first { $0.bonjourName == bonjourName } }
        return connections.first {
            $0.bonjourName == nil && $0.host.caseInsensitiveCompare(host) == .orderedSame && $0.port == port
                && (username.isEmpty || $0.username == username)
        }
    }

    func thumbnailURL(_ id: UUID) -> URL {
        Self.directory.appendingPathComponent("Thumbnails/\(id.uuidString).png")
    }

    func thumbnail(_ id: UUID) -> NSImage? {
        _ = thumbnailGeneration
        return NSImage(contentsOf: thumbnailURL(id))
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        connections = (try? dec.decode([SavedConnection].self, from: data)) ?? []
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(connections) { try? data.write(to: fileURL, options: .atomic) }
    }
}
