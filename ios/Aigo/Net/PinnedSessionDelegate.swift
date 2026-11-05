import CryptoKit
import Foundation
import Security

enum CertificatePin {
    /// Lowercase hex with separators (":" / spaces) removed.
    static func normalize(_ fingerprint: String) -> String {
        String(fingerprint.lowercased().filter { $0.isHexDigit })
    }

    /// SHA-256 (lowercase hex) of the leaf certificate's DER bytes.
    static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Trusts exactly the certificate whose SHA-256 matches the paired pin.
/// The host uses a self-signed cert, so the pin is the only trust root.
final class PinnedSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let expected: String
    private let lock = NSLock()
    private var _lastMismatch: String?

    /// The fingerprint actually presented when the pin last failed.
    var lastMismatch: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastMismatch
    }

    init(fingerprint: String) {
        expected = CertificatePin.normalize(fingerprint)
        super.init()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let result = evaluate(challenge)
        completionHandler(result.0, result.1)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let result = evaluate(challenge)
        completionHandler(result.0, result.1)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard let presented = CertificatePin.leafFingerprint(of: trust) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        if !expected.isEmpty && presented == expected {
            lock.lock()
            _lastMismatch = nil
            lock.unlock()
            return (.useCredential, URLCredential(trust: trust))
        }
        lock.lock()
        _lastMismatch = presented
        lock.unlock()
        return (.cancelAuthenticationChallenge, nil)
    }
}
