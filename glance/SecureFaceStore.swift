//
//  SecureFaceStore.swift
//  glance
//
//  Low-level encrypted persistence for enrolled face identities — AES-GCM under the same session key SecureCredentialManager
//  uses for the Mac password, rather than a second key. `FaceEnrollmentStore` delegates its load/save here; no plaintext fallback.
//

import Foundation

enum SecureFaceStoreError: LocalizedError {
    case sessionLocked

    var errorDescription: String? {
        switch self {
        case .sessionLocked:
            return "Session is locked. Authenticate with Touch ID to access enrolled faces."
        }
    }
}

nonisolated enum SecureFaceStore {
    /// Distinct filename/extension so plaintext can never be mistaken for ciphertext.
    private static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("glance", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("face-identities.enc")
    }()

    /// True if a store exists on disk, regardless of whether the session is currently unlocked enough to read it.
    static var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Throws `.sessionLocked` rather than returning an empty array, so callers can distinguish "nothing enrolled" from "enrolled, but locked".
    static func load() throws -> [FaceIdentity] {
        guard SecureCredentialManager.isSessionUnlocked else { throw SecureFaceStoreError.sessionLocked }
        // "No file" is the only condition that legitimately means "nothing enrolled". The previous
        // `try?` turned *every* read failure — a permissions problem, a partial write, an I/O
        // error — into an empty array, which was recorded upstream as a SUCCESSFUL empty load.
        // That is what defeated `FaceEnrollmentStore`'s anti-overwrite guard: the store believed it
        // had loaded cleanly and found nothing, so the next enrollment overwrote intact ciphertext
        // with a single new identity. Real errors now reach the caller.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let ciphertext = try Data(contentsOf: fileURL)
        let plaintext = try SecureCredentialManager.decrypt(ciphertext)
        return try JSONDecoder().decode([FaceIdentity].self, from: plaintext)
    }

    static func save(_ identities: [FaceIdentity]) throws {
        guard SecureCredentialManager.isSessionUnlocked else { throw SecureFaceStoreError.sessionLocked }
        let plaintext = try JSONEncoder().encode(identities)
        let ciphertext = try SecureCredentialManager.encrypt(plaintext)
        try ciphertext.write(to: fileURL, options: .atomic)
    }

    /// Throws rather than swallowing, because a silent failure here strands the user permanently.
    ///
    /// A surviving `face-identities.enc` keeps `SecureCredentialManager.hasSessionEncryptedData`
    /// true forever, and `unlockSession` refuses to mint a new key while that is true — by design,
    /// so a re-signed build cannot render existing data unreadable. But combined with a swallowed
    /// delete it means Glance can never be set up again without an `rm` in Terminal, while the UI
    /// reports "Password and face enrollment removed".
    ///
    /// Missing-file is success: the caller asked for it gone, and it is.
    static func deleteAll() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}
