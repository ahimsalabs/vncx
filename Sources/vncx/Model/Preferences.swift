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

    private init() {
        commandKey = CommandKeyMapping(rawValue: defaults.string(forKey: "commandKey") ?? "") ?? .superKey
        sendCommandShortcuts = defaults.object(forKey: "sendCommandShortcuts") as? Bool ?? true
        keyboardCapture = KeyboardCapturePolicy(rawValue: defaults.string(forKey: "keyboardCapture") ?? "") ?? .fullScreen
        syncClipboard = defaults.object(forKey: "syncClipboard") as? Bool ?? true
        smoothScaling = defaults.object(forKey: "smoothScaling") as? Bool ?? true
        defaultQuality = Quality(rawValue: defaults.string(forKey: "defaultQuality") ?? "") ?? .auto
        defaultScaling = ScalingMode(rawValue: defaults.string(forKey: "defaultScaling") ?? "") ?? .fit
    }
}
