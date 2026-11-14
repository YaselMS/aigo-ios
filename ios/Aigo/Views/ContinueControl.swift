import SwiftUI

/// Continue (north star goal 2, host API §7j): resumes a conversation in a
/// new Aigo session on the PC and opens its terminal. For one running in
/// another window it shows the host's message with "Continue a copy here"
/// (fork) and "Notify me when it ends" (POST /continue/watch).
/// Callers show it only when the host has the `sessions.continue` capability.
struct ContinueControl: View {
    /// Search item id: an Aigo session id or "<agent>:<agentSessionId>".
    let id: String
    var label = "Continue"

    @EnvironmentObject private var store: AppStore
    @State private var busy = false
    @State private var conflict: ContinueBusy?
    @State private var note: String?
    @State private var noteIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let conflict {
                Text(conflict.error ?? "Running in another window on \(store.hostLabel).")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.coralText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if conflict.canFork == true {
                        Button("Continue a copy here") { run(fork: true) }
                            .buttonStyle(SoftButtonStyle())
                    }
                    if conflict.canWatch ?? true {
                        Button("Notify me when it ends") { watch() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .disabled(busy)
            } else {
                Button {
                    run(fork: false)
                } label: {
                    HStack(spacing: 8) {
                        if busy {
                            ProgressView().controlSize(.small).tint(Theme.lime)
                        }
                        Text(label)
                    }
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(busy)
            }
            if let note {
                Text(note)
                    .font(.aigo(.caption))
                    .foregroundStyle(noteIsError ? Theme.coralText : Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func run(fork: Bool) {
        guard !busy else { return }
        busy = true
        note = nil
        Haptics.tap()
        Task {
            let outcome = await store.continueSession(id, fork: fork)
            busy = false
            switch outcome {
            case .opened:
                conflict = nil
            case .runningElsewhere(let b):
                withAnimation(.easeInOut(duration: 0.2)) { conflict = b }
            case .failed(let msg):
                Haptics.error()
                note = msg
                noteIsError = true
            }
        }
    }

    private func watch() {
        guard !busy else { return }
        busy = true
        Task {
            let res = await store.watchContinue(id)
            busy = false
            note = res.text
            noteIsError = res.isError
            if res.ended {
                // The other window closed: offer plain Continue again.
                withAnimation(.easeInOut(duration: 0.2)) { conflict = nil }
            }
        }
    }
}
