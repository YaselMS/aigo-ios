import SwiftUI
import UIKit

/// Update notice (issue #38): compares the app's version with the latest
/// release of YaselMS/aigo-ios (GitHub `releases/latest`, checked at most
/// every 6 hours, cached). iOS does not let a sideloaded app update itself,
/// so the notice copies the IPA link and opens Signulous, where the user
/// re-signs it ("Upload IPA from URL").
@MainActor
final class UpdateChecker: ObservableObject {
    static let repo = "YaselMS/aigo-ios"
    static let interval: TimeInterval = 6 * 60 * 60
    /// Signulous has no documented URL scheme; its website is the entry point.
    static let signulousURL = URL(string: "https://www.signulous.com")!
    static let instructions = "Paste the link in Signulous → Upload IPA from URL."

    /// Tag of the latest release, e.g. "v0.3.2".
    @Published private(set) var latestTag: String?
    @Published private(set) var checking = false
    @Published private(set) var lastError: String?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var dismissedTag: String?

    private let defaults = UserDefaults.standard
    private enum Key {
        static let tag = "update.latestTag"
        static let checked = "update.checkedAt"
        static let dismissed = "update.dismissedTag"
    }

    init() {
        latestTag = defaults.string(forKey: Key.tag)
        let t = defaults.double(forKey: Key.checked)
        checkedAt = t > 0 ? Date(timeIntervalSince1970: t) : nil
        dismissedTag = defaults.string(forKey: Key.dismissed)
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// A newer release than this app exists.
    var updateAvailable: Bool {
        guard let tag = latestTag else { return false }
        return UpdateChecker.isNewer(tag, than: UpdateChecker.currentVersion)
    }

    /// "v0.3.2" (with the leading v).
    var latestLabel: String {
        guard let tag = latestTag else { return "" }
        return tag.hasPrefix("v") ? tag : "v" + tag
    }

    var showsBanner: Bool {
        updateAvailable && dismissedTag != latestTag
    }

    var ipaURL: URL? {
        guard let tag = latestTag, let safe = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://github.com/\(UpdateChecker.repo)/releases/download/\(safe)/Aigo-unsigned.ipa")
    }

    func dismissBanner() {
        dismissedTag = latestTag
        defaults.set(latestTag, forKey: Key.dismissed)
    }

    /// Checks GitHub if the cached answer is older than 6 hours (or `force`).
    func checkIfDue(force: Bool = false) async {
        if checking { return }
        if !force, let last = checkedAt, Date().timeIntervalSince(last) < UpdateChecker.interval { return }
        checking = true
        defer { checking = false }
        guard let url = URL(string: "https://api.github.com/repos/\(UpdateChecker.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Aigo-iOS/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                lastError = status == 404 ? "No release published yet." : "GitHub answered with HTTP \(status)."
                markChecked()
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            if let tag = release.tag_name, !tag.isEmpty, release.draft != true, release.prerelease != true {
                latestTag = tag
                defaults.set(tag, forKey: Key.tag)
            }
            lastError = nil
            markChecked()
        } catch {
            lastError = "Couldn't check for updates (\(error.localizedDescription))."
        }
    }

    private func markChecked() {
        let now = Date()
        checkedAt = now
        defaults.set(now.timeIntervalSince1970, forKey: Key.checked)
    }

    /// Copies the IPA link and opens Signulous.
    func copyLinkAndOpenSignulous() {
        guard let url = ipaURL else { return }
        UIPasteboard.general.string = url.absoluteString
        Haptics.success()
        UIApplication.shared.open(UpdateChecker.signulousURL)
    }

    private struct Release: Decodable {
        var tag_name: String?
        var draft: Bool?
        var prerelease: Bool?
    }

    /// Numeric comparison of dotted versions ("v0.10.1" > "0.9.3").
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var v = s.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
            if let dash = v.firstIndex(where: { $0 == "-" || $0 == "+" }) { v = String(v[..<dash]) }
            return v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// "Update available: vX" with the copy-link button and the Signulous steps.
struct UpdateNotice: View {
    @EnvironmentObject private var updates: UpdateChecker
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.lime)
                Text("Update available: \(updates.latestLabel)")
                    .font(.aigo(.callout, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                if let onDismiss = onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Dismiss update notice"))
                }
            }
            Text("You have \(UpdateChecker.currentVersion). \(UpdateChecker.instructions)")
                .font(.aigo(.footnote))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                updates.copyLinkAndOpenSignulous()
            } label: {
                Label("Copy IPA link & open Signulous", systemImage: "doc.on.doc")
            }
            .buttonStyle(SoftButtonStyle(tint: Theme.lime))
        }
        .padding(12)
        .aigoCard()
    }
}
