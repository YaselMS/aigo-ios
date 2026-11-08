import Foundation

/// What the phone keeps for one paired PC (stored in the Keychain).
struct HostCredentials: Codable, Identifiable, Equatable {
    var addr: String          // host:port in use (the last one that answered)
    var fingerprint: String   // lowercase hex SHA-256 of the leaf certificate DER
    var token: String         // device bearer token
    var hostId: String
    var hostName: String
    /// Every known host:port of this PC, best first (pairing link `a=`,
    /// refreshed from host info `remote.endpoints`). nil for older pairings.
    var addrs: [String]? = nil

    var id: String { hostId.isEmpty ? addr : hostId }

    /// Every address to try, best first; always includes `addr`.
    var endpoints: [String] {
        var out = PairDraft.dedupe(addrs ?? [])
        if !addr.isEmpty && !out.contains(addr) { out.append(addr) }
        return out
    }
}

/// Pairing details collected from a QR code, an aigo://pair link or by hand.
struct PairDraft: Equatable {
    var addr: String = ""
    var fingerprint: String = ""
    var code: String = ""
    var hostName: String = ""
    /// `a=` of the pairing link: every endpoint, best first (docs/API.md §7).
    var addrs: [String] = []

    /// The addresses to try, in order: the link's list (best first), or the
    /// typed address first when it is not in that list.
    var candidates: [String] {
        let typed = PairDraft.normalizeAddress(addr)
        let list = PairDraft.dedupe(addrs.map(PairDraft.normalizeAddress))
        if typed.isEmpty { return list }
        if list.contains(typed) { return list }
        return [typed] + list
    }

    /// Drops empty entries and duplicates, keeping the first occurrence.
    static func dedupe(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for a in list {
            let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t.lowercased()) else { continue }
            seen.insert(t.lowercased())
            out.append(t)
        }
        return out
    }

    var isComplete: Bool {
        !addr.trimmingCharacters(in: .whitespaces).isEmpty &&
            CertificatePin.normalize(fingerprint).count == 64 &&
            code.filter { $0.isNumber }.count == 6
    }

    static let defaultPort = "47211"

    /// Strips schemes/slashes and adds the default port when missing.
    static func normalizeAddress(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "wss://", "ws://"] {
            if s.lowercased().hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
            }
        }
        while s.hasSuffix("/") {
            s.removeLast()
        }
        if s.isEmpty {
            return s
        }
        let hasPort: Bool
        if s.hasPrefix("[") {
            hasPort = s.contains("]:")
        } else {
            hasPort = s.contains(":")
        }
        if !hasPort {
            s += ":" + defaultPort
        }
        return s
    }
}

extension PairDraft {
    /// Parses `aigo://pair?h=<host:port>&a=<host:port,host:port,...>&fp=<sha256hex>&c=<code>&n=<hostName>`.
    /// Parsed by hand so slightly malformed links (unescaped spaces) still work.
    init?(string raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("aigo://"), let q = s.firstIndex(of: "?") else {
            return nil
        }
        var draft = PairDraft()
        let query = s[s.index(after: q)...]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).lowercased()
            // Go's url.QueryEscape encodes spaces as "+".
            let encoded = String(parts[1]).replacingOccurrences(of: "+", with: " ")
            let value = encoded.removingPercentEncoding ?? encoded
            switch key {
            case "h": draft.addr = value
            case "a":
                draft.addrs = value.split(separator: ",").map { PairDraft.normalizeAddress(String($0)) }.filter { !$0.isEmpty }
            case "fp": draft.fingerprint = value
            case "c": draft.code = value
            case "n": draft.hostName = value
            default: break
            }
        }
        if draft.addr.isEmpty, let first = draft.addrs.first {
            draft.addr = first
        }
        if draft.addr.isEmpty && draft.fingerprint.isEmpty && draft.code.isEmpty {
            return nil
        }
        self = draft
    }

    init?(url: URL) {
        self.init(string: url.absoluteString)
    }
}
