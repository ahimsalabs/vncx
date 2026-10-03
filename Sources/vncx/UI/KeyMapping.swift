// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import VNCCore
import AppKit
import Carbon.HIToolbox

/// Maps macOS key events to X11 keysyms, which is what RFB KeyEvent messages carry.
enum KeyMapping {
    static let specialKeys: [UInt16: UInt32] = [
        UInt16(kVK_Return): 0xff0d, UInt16(kVK_Tab): 0xff09, UInt16(kVK_Delete): 0xff08,
        UInt16(kVK_Escape): 0xff1b, UInt16(kVK_ForwardDelete): 0xffff, UInt16(kVK_Help): 0xff63,
        UInt16(kVK_Home): 0xff50, UInt16(kVK_End): 0xff57, UInt16(kVK_PageUp): 0xff55, UInt16(kVK_PageDown): 0xff56,
        UInt16(kVK_LeftArrow): 0xff51, UInt16(kVK_UpArrow): 0xff52, UInt16(kVK_RightArrow): 0xff53, UInt16(kVK_DownArrow): 0xff54,
        UInt16(kVK_F1): 0xffbe, UInt16(kVK_F2): 0xffbf, UInt16(kVK_F3): 0xffc0, UInt16(kVK_F4): 0xffc1,
        UInt16(kVK_F5): 0xffc2, UInt16(kVK_F6): 0xffc3, UInt16(kVK_F7): 0xffc4, UInt16(kVK_F8): 0xffc5,
        UInt16(kVK_F9): 0xffc6, UInt16(kVK_F10): 0xffc7, UInt16(kVK_F11): 0xffc8, UInt16(kVK_F12): 0xffc9,
        UInt16(kVK_F13): 0xffca, UInt16(kVK_F14): 0xffcb, UInt16(kVK_F15): 0xffcc, UInt16(kVK_F16): 0xffcd,
        UInt16(kVK_F17): 0xffce, UInt16(kVK_F18): 0xffcf, UInt16(kVK_F19): 0xffd0, UInt16(kVK_F20): 0xffd1,
        UInt16(kVK_ANSI_KeypadEnter): 0xff8d, UInt16(kVK_ANSI_KeypadClear): 0xff7f,
        UInt16(kVK_ANSI_KeypadDecimal): 0xffae, UInt16(kVK_ANSI_KeypadMultiply): 0xffaa,
        UInt16(kVK_ANSI_KeypadPlus): 0xffab, UInt16(kVK_ANSI_KeypadDivide): 0xffaf,
        UInt16(kVK_ANSI_KeypadMinus): 0xffad, UInt16(kVK_ANSI_KeypadEquals): 0xffbd,
        UInt16(kVK_ANSI_Keypad0): 0xffb0, UInt16(kVK_ANSI_Keypad1): 0xffb1, UInt16(kVK_ANSI_Keypad2): 0xffb2,
        UInt16(kVK_ANSI_Keypad3): 0xffb3, UInt16(kVK_ANSI_Keypad4): 0xffb4, UInt16(kVK_ANSI_Keypad5): 0xffb5,
        UInt16(kVK_ANSI_Keypad6): 0xffb6, UInt16(kVK_ANSI_Keypad7): 0xffb7, UInt16(kVK_ANSI_Keypad8): 0xffb8,
        UInt16(kVK_ANSI_Keypad9): 0xffb9,
    ]

    enum Modifier {
        static let shiftL: UInt32 = 0xffe1, shiftR: UInt32 = 0xffe2
        static let controlL: UInt32 = 0xffe3, controlR: UInt32 = 0xffe4
        static let capsLock: UInt32 = 0xffe5
        static let metaL: UInt32 = 0xffe7, metaR: UInt32 = 0xffe8
        static let altL: UInt32 = 0xffe9, altR: UInt32 = 0xffea
        static let superL: UInt32 = 0xffeb, superR: UInt32 = 0xffec
    }

    /// Keysym for a modifier key code (from flagsChanged), honoring the user's Command-key mapping.
    static func modifierKeysym(_ keyCode: UInt16, commandMapping: CommandKeyMapping) -> UInt32? {
        switch Int(keyCode) {
        case kVK_Shift: return Modifier.shiftL
        case kVK_RightShift: return Modifier.shiftR
        case kVK_Control: return Modifier.controlL
        case kVK_RightControl: return Modifier.controlR
        case kVK_Option: return Modifier.altL
        case kVK_RightOption: return Modifier.altR
        case kVK_Command: return commandMapping.left
        case kVK_RightCommand: return commandMapping.right
        case kVK_CapsLock: return Modifier.capsLock
        default: return nil
        }
    }

    /// Keysym for a key-down event. Uses the character produced with only Shift applied, so modifiers like
    /// Control/Option/Command are sent as separate key events and composed by the remote side.
    static func keysym(for event: NSEvent) -> UInt32? {
        if let special = specialKeys[event.keyCode] { return special }
        let chars = event.characters(byApplyingModifiers: event.modifierFlags.intersection([.shift, .capsLock]))
            ?? event.charactersIgnoringModifiers
        guard let scalar = chars?.unicodeScalars.first else { return nil }
        return keysym(for: scalar)
    }

    static func keysym(for scalar: Unicode.Scalar) -> UInt32 {
        let v = scalar.value
        switch v {
        case 0x0d, 0x03: return 0xff0d
        case 0x09: return 0xff09
        case 0x08, 0x7f: return 0xff08
        case 0x1b: return 0xff1b
        case 0x20...0x7e, 0xa0...0xff: return v
        default: return 0x0100_0000 | v
        }
    }
}

enum CommandKeyMapping: String, Codable, CaseIterable, Identifiable {
    case superKey, meta, control, alt
    var id: String { rawValue }
    var label: String {
        switch self {
        case .superKey: return "Super (Windows/Command key)"
        case .meta: return "Meta"
        case .control: return "Control"
        case .alt: return "Alt"
        }
    }
    var left: UInt32 {
        switch self {
        case .superKey: return KeyMapping.Modifier.superL
        case .meta: return KeyMapping.Modifier.metaL
        case .control: return KeyMapping.Modifier.controlL
        case .alt: return KeyMapping.Modifier.altL
        }
    }
    var right: UInt32 {
        switch self {
        case .superKey: return KeyMapping.Modifier.superR
        case .meta: return KeyMapping.Modifier.metaR
        case .control: return KeyMapping.Modifier.controlR
        case .alt: return KeyMapping.Modifier.altR
        }
    }
}
