import VNCCore
import AppKit
import ApplicationServices

enum KeyboardCapturePolicy: String, Codable, CaseIterable, Identifiable {
    case never, fullScreen, always
    var id: String { rawValue }
    var label: String {
        switch self {
        case .never: return "Never"
        case .fullScreen: return "In Full Screen"
        case .always: return "Always"
        }
    }
}

/// Grabs system keyboard shortcuts (⌘Tab, ⌘Space, ⌃-arrows, Mission Control keys…) while a remote view has focus,
/// so they go to the remote computer instead of macOS. Uses a session event tap, which requires the
/// Accessibility permission.
final class KeyboardCapture {
    static let shared = KeyboardCapture()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var prompted = false

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Re-evaluates whether the tap should be running. Call when focus, full screen state, or preferences change.
    func update() {
        if shouldCapture {
            guard tap == nil else { CGEvent.tapEnable(tap: tap!, enable: true); return }
            guard isTrusted else {
                if !prompted {
                    prompted = true
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(opts)
                }
                return
            }
            install()
        } else if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    /// The remote view that should receive captured keys right now, if any.
    fileprivate var target: RemoteView? {
        guard NSApp.isActive, let window = NSApp.keyWindow, let view = window.firstResponder as? RemoteView,
              !view.viewOnly, view.session?.client != nil else { return nil }
        switch Preferences.shared.keyboardCapture {
        case .never: return nil
        case .always: return view
        case .fullScreen: return window.styleMask.contains(.fullScreen) ? view : nil
        }
    }

    private var shouldCapture: Bool { target != nil }

    private func install() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: keyboardTapCallback, userInfo: nil)
        else { NSLog("vncx: could not create keyboard event tap"); return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// Keys that macOS would otherwise act on before the app sees them.
    fileprivate static func isSystemShortcut(_ event: CGEvent) -> Bool {
        let flags = event.flags
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // ⌃⌘ shortcuts, ⌘Q and ⌘H stay with vncx.
        if flags.contains(.maskCommand) && flags.contains(.maskControl) { return false }
        if flags.contains(.maskCommand), [12, 4].contains(code), !flags.contains(.maskAlternate) { return false } // Q, H
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return true }
        // Function keys that trigger Mission Control, Launchpad, Show Desktop, etc.
        let functionKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 160, 131, 130]
        return functionKeys.contains(code)
    }
}

private func keyboardTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        KeyboardCapture.shared.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp, KeyboardCapture.isSystemShortcut(event),
          let view = KeyboardCapture.shared.target, let ns = NSEvent(cgEvent: event) else {
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown { view.keyDown(with: ns) } else { view.keyUp(with: ns) }
    return nil // swallowed: macOS never sees it
}
