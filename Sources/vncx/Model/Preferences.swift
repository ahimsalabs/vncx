// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import VNCCore
import Foundation
import Observation

/// App-wide preferences backed by UserDefaults.
@Observable
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    var commandKey: CommandKeyMapping {
        didSet { defaults.set(commandKey.rawValue, forKey: "commandKey") }
    }
    var sendCommandShortcuts: Bool {
        didSet { defaults.set(sendCommandShortcuts, forKey: "sendCommandShortcuts") }
    }
    var keyboardCapture: KeyboardCapturePolicy {
        didSet { defaults.set(keyboardCapture.rawValue, forKey: "keyboardCapture"); KeyboardCapture.shared.update() }
    }
    var showMenuBarItem: Bool {
        didSet { defaults.set(showMenuBarItem, forKey: "showMenuBarItem"); MenuBarController.shared.update() }
    }
    var syncClipboard: Bool {
        didSet { defaults.set(syncClipboard, forKey: "syncClipboard") }
    }
    var smoothScaling: Bool {
        didSet { defaults.set(smoothScaling, forKey: "smoothScaling") }
    }
    var defaultQuality: Quality {
        didSet { defaults.set(defaultQuality.rawValue, forKey: "defaultQuality") }
    }
    var defaultScaling: ScalingMode {
        didSet { defaults.set(defaultScaling.rawValue, forKey: "defaultScaling") }
    }
    var fullScreenToolbar: FullScreenToolbar {
        didSet { defaults.set(fullScreenToolbar.rawValue, forKey: "fullScreenToolbar"); SessionManager.shared.applyFullScreenChrome() }
    }

    private init() {
        commandKey = CommandKeyMapping(rawValue: defaults.string(forKey: "commandKey") ?? "") ?? .superKey
        sendCommandShortcuts = defaults.object(forKey: "sendCommandShortcuts") as? Bool ?? true
        keyboardCapture = KeyboardCapturePolicy(rawValue: defaults.string(forKey: "keyboardCapture") ?? "") ?? .fullScreen
        showMenuBarItem = defaults.object(forKey: "showMenuBarItem") as? Bool ?? true
        syncClipboard = defaults.object(forKey: "syncClipboard") as? Bool ?? true
        smoothScaling = defaults.object(forKey: "smoothScaling") as? Bool ?? true
        defaultQuality = Quality(rawValue: defaults.string(forKey: "defaultQuality") ?? "") ?? .auto
        defaultScaling = ScalingMode(rawValue: defaults.string(forKey: "defaultScaling") ?? "") ?? .fit
        fullScreenToolbar = FullScreenToolbar(rawValue: defaults.string(forKey: "fullScreenToolbar") ?? "") ?? .island
    }
}

/// How a session window's toolbar behaves in full screen.
enum FullScreenToolbar: String, Codable, CaseIterable, Identifiable {
    case autoHide, island, visible
    var id: String { rawValue }
    var label: String {
        switch self {
        case .autoHide: return "Hide with Menu Bar"
        case .island: return "Floating Bar"
        case .visible: return "Always Show"
        }
    }
}
