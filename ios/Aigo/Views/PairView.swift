import SwiftUI
import UIKit

/// Pair with a PC, step by step: open pairing on the PC, scan its QR code
/// (primary), or paste an aigo://pair link / type the details by hand.
struct PairView: View {
    var draft: PairDraft?
    var onDone: (() -> Void)?

    @EnvironmentObject private var store: AppStore
    @State private var address = ""
    @State private var code = ""
    @State private var fingerprint = ""
    @State private var hostName = ""
    @State private var showScanner = false
    @State private var showManual = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var field: Field?

    private enum Field: Hashable {
        case address, code, fingerprint
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro

                step(1, title: "On your PC", text: "Open Aigo → Settings → Remote access and choose Pair a device. A QR code and a 6-digit code appear.")

                step(2, title: "Scan the QR code", text: "Point the camera at the code on the PC screen. Pairing starts by itself.") {
                    Button {
                        Haptics.tap()
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(FilledButtonStyle())
                    .disabled(busy)
                }

                if let error = error {
                    InlineBanner(text: error) { withAnimation { self.error = nil } }
                        .transition(.opacity)
                }

                other

                trustNote
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 16)
            .animation(.easeInOut(duration: 0.25), value: showManual)
            .animation(.easeInOut(duration: 0.2), value: error)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .overlay {
            if busy {
                busyOverlay
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { value in
                showScanner = false
                if let d = PairDraft(string: value) {
                    Haptics.success()
                    apply(d)
                    if d.isComplete {
                        pair()
                    } else {
                        showManual = true
                    }
                } else {
                    Haptics.error()
                    error = "That QR code is not an Aigo pairing code."
                }
            }
        }
        .onAppear {
            if let d = draft {
                apply(d)
                if !d.isComplete {
                    showManual = true
                }
            }
        }
        .onChange(of: draft) { _, newValue in
            if let d = newValue {
                apply(d)
            }
        }
    }

    // MARK: - Pieces

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Wordmark(size: 28)
            Text(introTitle)
                .font(Theme.display)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Aigo shows what every agent on your PC is doing and lets you answer them from here.")
                .font(.aigo(.callout))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private var introTitle: String {
        if let d = draft, !d.hostName.isEmpty, !d.isComplete {
            return "Pair again with \(d.hostName)"
        }
        return "Connect this iPhone to your PC"
    }

    private func step(_ n: Int, title: String, text: String) -> some View {
        step(n, title: title, text: text) { EmptyView() }
    }

    private func step<Extra: View>(_ n: Int, title: String, text: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.aigo(.callout, .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 30, height: 30)
                .background(Theme.lime, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.aigo(.headline))
                        .foregroundStyle(Theme.text)
                    Text(text)
                        .font(.aigo(.callout))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                extra()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aigoCard()
        .accessibilityElement(children: .contain)
    }

    private var other: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Other ways")
            Button {
                pasteLink()
            } label: {
                Label("Paste pairing link", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(OutlineButtonStyle())
            .disabled(busy)

            Button {
                Haptics.selection()
                showManual.toggle()
            } label: {
                HStack {
                    Label("Enter the details by hand", systemImage: "keyboard")
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showManual ? 180 : 0))
                }
            }
            .buttonStyle(OutlineButtonStyle())

            if showManual {
                manual
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var manual: some View {
        VStack(alignment: .leading, spacing: 14) {
            fieldBlock("PC address", hint: "LAN or Tailscale address. The port defaults to 47211.") {
                TextField("10.0.0.10:47211", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(Theme.mono)
                    .focused($field, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { field = .code }
            }
            fieldBlock("6-digit code", hint: nil) {
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .font(.aigo(.title3))
                    .focused($field, equals: .code)
            }
            fieldBlock("Certificate fingerprint", hint: "Aigo trusts only the PC whose certificate matches this fingerprint.") {
                TextField("64 hex characters", text: $fingerprint, axis: .vertical)
                    .lineLimit(2...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(Theme.monoSmall)
                    .focused($field, equals: .fingerprint)
            }
            Button {
                pair()
            } label: {
                Text(hostName.isEmpty ? "Pair" : "Pair with \(hostName)")
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(busy)
        }
        .padding(16)
        .aigoCard()
    }

    private func fieldBlock<F: View>(_ title: String, hint: String?, @ViewBuilder field: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Theme.monoLabel)
                .tracking(0.8)
                .foregroundStyle(Theme.secondary)
            field()
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 46)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            if let hint = hint {
                Text(hint)
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trustNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Theme.ice)
            Text("The connection is encrypted and pinned to your PC's certificate. Nothing goes through a cloud service.")
                .font(.aigo(.footnote))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var busyOverlay: some View {
        ZStack {
            Theme.bg.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(Theme.lime)
                Text(hostName.isEmpty ? "Pairing…" : "Pairing with \(hostName)…")
                    .font(.aigo(.headline))
                    .foregroundStyle(Theme.text)
            }
            .padding(28)
            .aigoCard()
        }
        .transition(.opacity)
    }

    // MARK: - Behaviour

    private func apply(_ d: PairDraft) {
        if !d.addr.isEmpty { address = d.addr }
        if !d.code.isEmpty { code = d.code }
        if !d.fingerprint.isEmpty { fingerprint = d.fingerprint }
        if !d.hostName.isEmpty { hostName = d.hostName }
        error = nil
    }

    private func pasteLink() {
        guard let text = UIPasteboard.general.string, let d = PairDraft(string: text) else {
            Haptics.error()
            error = "The clipboard has no aigo://pair link. Copy it on the PC first."
            return
        }
        apply(d)
        if d.isComplete {
            pair()
        } else {
            showManual = true
        }
    }

    private func pair() {
        guard !busy else { return }
        field = nil
        withAnimation { busy = true }
        error = nil
        let d = PairDraft(addr: address, fingerprint: fingerprint, code: code, hostName: hostName)
        Task {
            do {
                try await store.pair(d)
                withAnimation { busy = false }
                onDone?()
            } catch {
                withAnimation { busy = false }
                Haptics.error()
                self.error = APIError.describe(error)
                showManual = true
            }
        }
    }
}
