// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import VNCCore
import Foundation
import Network
import Observation

/// Discovers VNC / Screen Sharing servers on the local network (`_rfb._tcp`).
@Observable
final class BonjourBrowser {
    struct Service: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let endpoint: NWEndpoint
        static func == (a: Service, b: Service) -> Bool { a.name == b.name }
        func hash(into h: inout Hasher) { h.combine(name) }
    }

    static let shared = BonjourBrowser()
    private(set) var services: [Service] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_rfb._tcp", domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> Service? in
                if case .service(let name, _, _, _) = r.endpoint { return Service(name: name, endpoint: r.endpoint) }
                return nil
            }
            DispatchQueue.main.async {
                self?.services = Array(Set(list)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func endpoint(named name: String) -> NWEndpoint {
        services.first { $0.name == name }?.endpoint
            ?? .service(name: name, type: "_rfb._tcp", domain: "local.", interface: nil)
    }
}
