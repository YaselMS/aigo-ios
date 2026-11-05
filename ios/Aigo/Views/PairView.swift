import SwiftUI
import UIKit

/// Pair with a PC: scan its QR code, paste/tap an aigo://pair link, or type
/// the address, 6-digit code and certificate fingerprint by hand.
struct PairView: View {
    var draft: PairDraft?
    var onDone: (() -> Void)?

    @EnvironmentObject private var store: AppStore
    @State private var address = ""
    @State private var code = ""
    @State private var fingerprint = ""
    @State private var hostName = ""
    @State private var showScanner = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Wordmark()
                    Text("On your PC, open Aigo → Settings → Remote access and choose Pair a device. Scan the QR code it shows, or type the details below.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)

            Section {
                Button {
                    showScanner = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        .frame(minHeight: 44)
                }
                Button {
                    pasteLink()
                } label: {
                    Label("Paste pairing link", systemImage: "doc.on.clipboard")
                        .frame(minHeight: 44)
                }
            }
            .listRowBackground(Theme.surface)

            Section {
                TextField("10.0.0.10:47211", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(Theme.mono)
                    .frame(minHeight: 44)
            } header: {
                Text("PC address")
            } footer: {
                Text("Your PC's LAN or Tailscale address. The port defaults to 47211.")
            }
            .listRowBackground(Theme.surface)

            Section("6-digit code") {
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(.title3, design: .monospaced))
                    .frame(minHeight: 44)
            }
            .listRowBackground(Theme.surface)

            Section {
                TextField("64 hex characters", text: $fingerprint, axis: .vertical)
                    .lineLimit(2...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(Theme.monoSmall)
            } header: {
                Text("Certificate fingerprint")
            } footer: {
                Text("Aigo trusts only the PC whose certificate matches this fingerprint.")
            }
            .listRowBackground(Theme.surface)

            if let error = error {
                Section {
                    Text(error)
                        .foregroundStyle(Theme.coral)
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                Button {
                    pair()
                } label: {
                    HStack {
                        Spacer()
                        if busy {
                            ProgressView().tint(Theme.bg)
                        } else {
                            Text(hostName.isEmpty ? "Pair" : "Pair with \(hostName)")
                        }
                        Spacer()
                    }
                }
                .buttonStyle(FilledButtonStyle())
                .disabled(busy)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { value in
                showScanner = false
                if let d = PairDraft(string: value) {
                    apply(d)
                    if d.isComplete {
                        pair()
                    }
                } else {
                    error = "That QR code is not an Aigo pairing code."
                }
            }
        }
        .onAppear {
            if let d = draft {
                apply(d)
            }
        }
        .onChange(of: draft) { _, newValue in
            if let d = newValue {
                apply(d)
            }
        }
    }

    private func apply(_ d: PairDraft) {
        if !d.addr.isEmpty { address = d.addr }
        if !d.code.isEmpty { code = d.code }
        if !d.fingerprint.isEmpty { fingerprint = d.fingerprint }
        if !d.hostName.isEmpty { hostName = d.hostName }
        error = nil
    }

    private func pasteLink() {
        guard let text = UIPasteboard.general.string, let d = PairDraft(string: text) else {
            error = "The clipboard has no aigo://pair link."
            return
        }
        apply(d)
    }

    private func pair() {
        guard !busy else { return }
        busy = true
        error = nil
        let d = PairDraft(addr: address, fingerprint: fingerprint, code: code, hostName: hostName)
        Task {
            do {
                try await store.pair(d)
                busy = false
                onDone?()
            } catch {
                busy = false
                self.error = APIError.describe(error)
            }
        }
    }
}
