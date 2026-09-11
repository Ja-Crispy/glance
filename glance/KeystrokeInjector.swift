//
//  KeystrokeInjector.swift
//  glance
//
//  Synthesizes keystrokes via CGEvent, posted at the HID tap so they reach the lock screen's secure text field.
//

import Foundation
import ApplicationServices
import CoreGraphics
import Carbon.HIToolbox

enum KeystrokeError: LocalizedError {
    case accessibilityNotGranted
    case eventCreationFailed
    case invalidUTF8
    /// The keystrokes could no longer be shown to be going to the login window, so the run was
    /// abandoned partway through.
    case targetChanged

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission required. Open System Settings → Privacy & Security → Accessibility and enable glance."
        case .eventCreationFailed:
            return "Couldn't create CGEvent for keystroke."
        case .invalidUTF8:
            return "The stored credential isn't valid UTF-8."
        case .targetChanged:
            return "Stopped typing: the screen unlocked mid-password."
        }
    }
}

enum KeystrokeInjector {
    /// Returns true if the app has Accessibility permission (no prompt).
    nonisolated static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Triggers the system prompt to grant Accessibility (deep links to System Settings).
    @discardableResult
    nonisolated static func promptForAccessibility() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Types the UTF-8 bytes into whatever has keyboard focus, then presses Return. Blocking.
    ///
    /// `stillAuthorized` is re-evaluated before **every** scalar and once more before Return.
    /// The caller's single up-front check is worthless by the end of the run: this loop sleeps 24ms
    /// per character, so a 14-character password takes ~340ms and a 20-character one ~490ms, on top
    /// of a Keychain round-trip and an AES-GCM open. Anything that unlocks the screen inside that
    /// window — Apple Watch auto-unlock, Touch ID, the user typing their own password, a second
    /// scan cycle — moves focus off the login window's secure field and onto the desktop, where the
    /// remaining characters and then `Return` land in a Terminal, a chat compose box, or a browser
    /// bar, and `Return` is the character that *submits*. Aborting mid-password is strictly better
    /// than finishing into a focused app. `CGSessionCopyCurrentDictionary()` is a cheap in-process
    /// lookup, so per-scalar checking costs nothing next to the sleep that is already there.
    ///
    /// Takes `Data` rather than `String` so the plaintext stays in a buffer the caller can zero.
    /// Nothing here builds a `String`: the previous implementation decoded one (plus another per
    /// character), and Swift `String`s cannot be zeroed, so those copies outlived every
    /// `resetBytes` call on the heap. Decoding is done by hand into a `[UInt16]` this function owns
    /// and wipes on the way out.
    nonisolated static func typeAndReturn(
        _ passwordBytes: Data,
        stillAuthorized: () -> Bool
    ) throws {
        guard isAccessibilityTrusted() else {
            throw KeystrokeError.accessibilityNotGranted
        }
        guard stillAuthorized() else { throw KeystrokeError.targetChanged }

        // Secure Event Input is what stops every other process's event tap from reading these
        // keystrokes. loginwindow turns it on at the lock screen and it is normally off on a
        // plain unlocked desktop, so a true→false transition part-way through is independent
        // corroboration that the target went away — useful because CGSSessionScreenIsLocked is
        // documented in LockMonitor as lagging the real state.
        //
        // Deliberately NOT required to be true up front. That it is always enabled at the lock
        // screen is an untested assumption, and getting it wrong would refuse every unlock. Only
        // the transition is treated as disqualifying, which can only ever abort a run that was
        // already heading somewhere unintended.
        let secureInputAtStart = IsSecureEventInputEnabled()

        var units = [UInt16]()
        var scalarEnds = [Int]()
        units.reserveCapacity(passwordBytes.count)
        // `units` is uniquely referenced here, so this wipes the live buffer rather than a copy.
        defer { for i in units.indices { units[i] = 0 } }

        var decoder = UTF8()
        var iterator = passwordBytes.makeIterator()
        decodeLoop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                UTF16.encode(scalar) { units.append($0) }
                scalarEnds.append(units.count)
            case .emptyInput:
                break decodeLoop
            case .error:
                throw KeystrokeError.invalidUTF8
            }
        }

        let source = CGEventSource(stateID: .hidSystemState)

        // One event per Unicode scalar rather than per `Character`. Grapheme segmentation needs a
        // `String`, which is the copy this function exists to avoid; the receiver reassembles the
        // same text either way, since the units are posted in order.
        var start = 0
        for end in scalarEnds {
            guard stillAuthorized() else { throw KeystrokeError.targetChanged }
            if secureInputAtStart && !IsSecureEventInputEnabled() {
                throw KeystrokeError.targetChanged
            }
            try units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { throw KeystrokeError.eventCreationFailed }
                try postUnits(base + start, count: end - start, source: source)
            }
            start = end
        }

        // Re-checked immediately before the submit. Everything above can be wrong and merely leak
        // a fragment; posting Return on a stale authorization is what sends it.
        guard stillAuthorized() else { throw KeystrokeError.targetChanged }
        if secureInputAtStart && !IsSecureEventInputEnabled() {
            throw KeystrokeError.targetChanged
        }
        try postReturn(source: source)
    }

    /// Per-scalar Unicode injection — bypasses keyboard layout issues.
    private nonisolated static func postUnits(
        _ base: UnsafePointer<UInt16>, count: Int, source: CGEventSource?
    ) throws {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        // Cleared explicitly: `.hidSystemState` events inherit the modifier flags that are
        // physically held right now. A held Command or a Caps Lock left on would ride along, and if
        // focus has already moved off the login window that turns a stray character into a
        // shortcut. The unicode string below is what actually determines the text.
        keyDown.flags = []
        keyUp.flags = []
        keyDown.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
        keyUp.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
    }

    /// Physical Return key (virtual key 0x24).
    private nonisolated static func postReturn(source: CGEventSource?) throws {
        let returnKey: CGKeyCode = 0x24
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        keyUp.post(tap: .cghidEventTap)
    }
}
