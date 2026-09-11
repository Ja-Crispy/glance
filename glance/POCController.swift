//
//  POCController.swift
//  glance
//
//  Orchestration for credential storage: wires SecureCredentialManager to
//  KeystrokeInjector and exposes session/password status for Settings.
//

import Foundation
import Observation

@Observable
@MainActor
final class POCController {
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var sessionError: String? = nil

    /// Bound to the setup SecureField. Cleared immediately after a successful save.
    var passwordInput: String = ""

    var statusMessage: String = "Idle"

    func refreshAccessibilityStatus() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    func refreshCredentialStatus() {
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
    }

    // MARK: - Session (Touch ID gate)

    /// Must succeed before `savePassword()` or `injectStoredPassword()` will do anything.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "Authenticate to set up or use glance")
            }.value
            isSessionUnlocked = true
        } catch {
            isSessionUnlocked = false
            sessionError = error.localizedDescription
        }
    }

    func lockSession() {
        SecureCredentialManager.lockSession()
        isSessionUnlocked = false
    }

    // MARK: - Setup flow

    /// Encrypts and stores `passwordInput`. Requires the session to already
    /// be unlocked (Touch ID happens in `unlockSession()`, not here).
    func savePassword() async {
        guard !passwordInput.isEmpty else {
            statusMessage = "Enter a password first."
            return
        }
        let plaintext = passwordInput
        passwordInput = ""

        do {
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = plaintext.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            statusMessage = "Password saved and encrypted."
            hasStoredPassword = true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Injection

    /// Set and cleared on the MainActor either side of the `await`, so two calls cannot both get
    /// past the guard. Two concurrent typing loops post into the same HID stream: the characters
    /// interleave into a corrupt password, or the first run's Return unlocks the screen and the
    /// second keeps typing onto the desktop it just revealed.
    private var isInjecting = false

    /// Reads + decrypts + injects the stored password, zeroing the plaintext buffer before
    /// returning.
    ///
    /// The CGSession lock check is unconditional. It used to sit behind
    /// `requireAuthoritativeLock: Bool = false`, so the single gate between a face match and the
    /// password landing on the desktop was opt-in, and any new call site that omitted the argument
    /// silently skipped it. Only one caller ever passed `true`.
    ///
    /// `throws` rather than swallowing: `observeScanWindow` returned `.matched` regardless of
    /// whether the keystrokes went anywhere, so a failed injection still painted the success
    /// animation, and every diagnostic written here went to a `statusMessage` nothing renders.
    func injectStoredPassword() async throws {
        guard !isInjecting else { throw KeystrokeError.targetChanged }
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "Accessibility not granted — open System Settings and enable glance."
            throw KeystrokeError.accessibilityNotGranted
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Session locked — authenticate with Touch ID first."
            throw SecureCredentialError.sessionLocked
        }
        guard LockMonitor.isScreenActuallyLocked() else {
            statusMessage = "Skipped: CGSession reports screen is not actually locked."
            throw KeystrokeError.targetChanged
        }

        isInjecting = true
        defer { isInjecting = false }

        statusMessage = "Injecting…"
        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                // Re-checked before every scalar inside the loop, not just once out here — see
                // `KeystrokeInjector.typeAndReturn`.
                try KeystrokeInjector.typeAndReturn(bytes) {
                    LockMonitor.isScreenActuallyLocked()
                }
            }.value
            statusMessage = "Injected stored password + Return at \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            statusMessage = "Injection failed: \(error.localizedDescription)"
            throw error
        }
    }
}
