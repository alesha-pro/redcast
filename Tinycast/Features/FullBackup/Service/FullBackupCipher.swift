import CommonCrypto
import CryptoKit
import Foundation

/// PBKDF2-HMAC-SHA256 into AES-256-GCM. CryptoKit has no password KDF, and scrypt isn't public API.
enum FullBackupCipher {
    /// OWASP's 2023 figure for PBKDF2-HMAC-SHA256; about half a second on Apple silicon.
    static let iterations = 600_000
    /// A file may ask for more, never fewer, and never so many that opening it hangs the import.
    static let iterationRange = 100_000...10_000_000
    static let minimumPassphraseLength = 8

    enum CipherError: LocalizedError, Equatable {
        case wrongPassphrase
        case unsupported
        case failed

        var errorDescription: String? {
            switch self {
            case .wrongPassphrase:
                return String(localized: "The passphrase doesn't open this backup's keys.")
            case .unsupported:
                return String(localized: "This backup's keys were sealed by a newer version.")
            case .failed: return String(localized: "Couldn't seal the keys.")
            }
        }
    }

    static func seal(
        _ plaintext: Data, passphrase: String, count: Int, iterations: Int = Self.iterations
    ) throws(CipherError) -> (header: FullBackupSecretsHeader, sealed: Data) {
        let salt = randomBytes(16)
        let header = FullBackupSecretsHeader(iterations: iterations, salt: salt, count: count)
        let key = try derive(passphrase, salt: salt, iterations: iterations)
        guard let box = try? AES.GCM.seal(plaintext, using: key, authenticating: aad(header)),
            let combined = box.combined
        else { throw .failed }
        return (header, combined)
    }

    static func open(
        _ sealed: Data, header: FullBackupSecretsHeader, passphrase: String
    ) throws(CipherError) -> Data {
        guard header.kdf == FullBackupSecretsHeader.kdfName,
            header.cipher == FullBackupSecretsHeader.cipherName,
            iterationRange.contains(header.iterations), header.salt.count >= 16
        else { throw .unsupported }
        let key = try derive(passphrase, salt: header.salt, iterations: header.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
            let opened = try? AES.GCM.open(box, using: key, authenticating: aad(header))
        else { throw .wrongPassphrase }
        return opened
    }

    /// The header is authenticated, so lowering its iterations or swapping its salt fails the open.
    private static func aad(_ header: FullBackupSecretsHeader) -> Data {
        Data("tinycast-secrets|\(header.kdf)|\(header.iterations)|\(header.cipher)|".utf8) + header.salt
    }

    private static func derive(
        _ passphrase: String, salt: Data, iterations: Int
    ) throws(CipherError) -> SymmetricKey {
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: kCCKeySizeAES256)
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                passwordBytes.withMemoryRebound(to: CChar.self) { passwordChars in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), passwordChars.baseAddress, passwordChars.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        &derived, derived.count)
                }
            }
        }
        guard status == kCCSuccess else { throw .failed }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
