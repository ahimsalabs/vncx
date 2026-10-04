// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import VNCCore
import Foundation
import Observation
import AppKit

/// The shortcut sent to the remote to paste dropped text.
enum PasteShortcut: String, Codable, CaseIterable, Identifiable {
    case automatic, controlV, commandV, controlShiftV, shiftInsert
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic (⌘V on Macs, Ctrl+V elsewhere)"
        case .controlV: return "Ctrl+V"
        case .commandV: return "Command+V"
        case .controlShiftV: return "Ctrl+Shift+V (terminals)"
        case .shiftInsert: return "Shift+Insert"
        }
    }
}

/// A cap on how fast the server sends. Automatic leaves it to the server: WayVNC and TigerVNC pace themselves with
/// fences, and pacing requests from the client (as a fixed limit does) has preceded long stalls with WayVNC.
enum BandwidthLimit: String, Codable, CaseIterable, Identifiable {
    case automatic, unlimited, mbit50, mbit20, mbit10, mbit5
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .unlimited: return "Unlimited"
        case .mbit50: return "50 Mbit/s"
        case .mbit20: return "20 Mbit/s"
        case .mbit10: return "10 Mbit/s"
        case .mbit5: return "5 Mbit/s"
        }
    }
    /// The fixed limit in bits/s; nil for automatic and unlimited.
    var bitsPerSecond: Double? {
        switch self {
        case .automatic, .unlimited: return nil
        case .mbit50: return 50e6
        case .mbit20: return 20e6
        case .mbit10: return 10e6
        case .mbit5: return 5e6
        }
    }
}

enum LocalCursorMode: String, Codable, CaseIterable, Identifiable {
    case arrow, dot, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .arrow: return "Arrow"
        case .dot: return "Dot"
        case .hidden: return "Hidden"
        }
    }
}

struct SavedConnection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 5900
    var username = ""
    /// Set for computers discovered via Bonjour; the service name is resolved at connect time.
    var bonjourName: String?
    var quality: Quality = Preferences.shared.defaultQuality
    var bandwidth: BandwidthLimit = .automatic
    var scaling: ScalingMode = Preferences.shared.defaultScaling
    var viewOnly = false
    var remoteResizeRetina = false
    var lastConnected: Date?
    var lastResolution: String?
    /// What to show locally when the server never sends cursor shapes.
    var localCursor: LocalCursorMode = .arrow
    var ssh = SSHSettings()
    var wake = WakeSettings()
    /// The remote display last chosen for the main window ("number:WxH"), for multi-monitor servers.
    var preferredDisplay: String?
    var pasteShortcut: PasteShortcut = .automatic

    /// The SSH destination to use (defaults to the VNC host).
    var sshDestination: String {
        let d = ssh.destination.trimmingCharacters(in: .whitespaces)
        return d.isEmpty ? host : d
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, bonjourName, quality, bandwidth, scaling, viewOnly, remoteResizeRetina
        case lastConnected, lastResolution, localCursor, ssh, wake, preferredDisplay, pasteShortcut
    }

    /// Tolerant decoding: any missing or unreadable key keeps its default, so adding settings never
    /// invalidates connections saved by an older version.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        id = get(.id, id)
        name = get(.name, name)
        host = get(.host, host)
        port = get(.port, port)
        username = get(.username, username)
        bonjourName = get(.bonjourName, bonjourName)
        quality = get(.quality, quality)
        bandwidth = get(.bandwidth, bandwidth)
        scaling = get(.scaling, scaling)
        viewOnly = get(.viewOnly, viewOnly)
        remoteResizeRetina = get(.remoteResizeRetina, remoteResizeRetina)
        lastConnected = get(.lastConnected, lastConnected)
        lastResolution = get(.lastResolution, lastResolution)
        localCursor = get(.localCursor, localCursor)
        ssh = get(.ssh, ssh)
        wake = get(.wake, wake)
        preferredDisplay = get(.preferredDisplay, preferredDisplay)
        pasteShortcut = get(.pasteShortcut, pasteShortcut)
    }

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
        let dir = base.appendingPathComponent(AppIdentity.dataFolderName, isDirectory: true)
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

/// One monitor of a multi-screen remote desktop.
struct RemoteDisplay: Identifiable, Equatable {
    let id: UInt32
    let number: Int
    let rect: CGRect
    var sizeText: String { "\(Int(rect.width))x\(Int(rect.height))" }
    var key: String { "\(number):\(sizeText)" }
    var label: String { "Display \(number) (\(Int(rect.width))×\(Int(rect.height)))" }
}

final class WeakRemoteView {
    weak var view: RemoteView?
    init(view: RemoteView) { self.view = view }
}
