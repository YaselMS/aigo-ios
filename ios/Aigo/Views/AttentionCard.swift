import SwiftUI

/// One pending approval / question. Several stack on Home so they can be
/// answered in a row; answered cards animate away.
struct AttentionCard: View {
    let item: InboxItem
    @EnvironmentObject private var store: AppStore
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.coral)
                    .frame(width: 8, height: 8)
                Text(item.contextLine)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer()
                if let sid = item.sessionId, !sid.isEmpty {
                    Button("Open") {
                        store.openSession(sid)
                    }
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 32)
                }
            }

            Text(item.title ?? "Needs your answer")
                .font(.headline)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)

            if let message = item.message, !message.isEmpty {
                Text(message)
                    .font(isCommand ? Theme.monoSmall : .callout)
                    .foregroundStyle(Theme.text.opacity(0.92))
                    .lineLimit(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .textSelection(.enabled)
            }

            if let error = error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.coral.opacity(0.35), lineWidth: 1))
        .disabled(busy)
        .opacity(busy ? 0.6 : 1.0)
    }

    private var isCommand: Bool {
        let tool = (item.toolName ?? "").lowercased()
        return ["bash", "shell", "powershell", "exec", "exec_command", "local_shell"].contains(tool)
    }

    private var options: [String] {
        item.options ?? []
    }

    @ViewBuilder
    private var actions: some View {
        if item.kind == "ask" && !options.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { pair in
                    Button(pair.element) {
                        run { await store.decide(item, approve: true, choice: pair.element) }
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
                Button("Deny") {
                    run { await store.decide(item, approve: false) }
                }
                .buttonStyle(OutlineButtonStyle(tint: Theme.secondary))
            }
        } else if item.kind == "question" {
            if !options.isEmpty && !(item.sessionId ?? "").isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(options.enumerated()), id: \.offset) { pair in
                        Button(pair.element) {
                            run { await store.answerQuestion(item, number: pair.offset + 1, label: pair.element) }
                        }
                        .buttonStyle(OutlineButtonStyle())
                    }
                }
            } else if let sid = item.sessionId, !sid.isEmpty {
                Button("Answer in the session") {
                    store.openSession(sid)
                }
                .buttonStyle(FilledButtonStyle())
            } else {
                Text("This agent runs outside Aigo. Answer it in its own terminal.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
        } else if confirming {
            VStack(alignment: .leading, spacing: 8) {
                Text("This looks destructive. Are you sure?")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.coral)
                HStack(spacing: 10) {
                    Button("Cancel") {
                        confirming = false
                    }
                    .buttonStyle(OutlineButtonStyle(tint: Theme.secondary))
                    Button("Yes, do it") {
                        confirming = false
                        run { await store.decide(item, approve: true) }
                    }
                    .buttonStyle(FilledButtonStyle(fill: Theme.coral, foreground: Theme.bg))
                }
            }
        } else {
            HStack(spacing: 10) {
                Button("Deny") {
                    run { await store.decide(item, approve: false) }
                }
                .buttonStyle(OutlineButtonStyle())
                Button(item.kind == "plan" ? "Approve plan" : "Approve") {
                    if item.looksDestructive {
                        confirming = true
                    } else {
                        run { await store.decide(item, approve: true) }
                    }
                }
                .buttonStyle(FilledButtonStyle())
            }
        }
    }

    private func run(_ op: @escaping () async -> String?) {
        busy = true
        error = nil
        Task {
            let result = await op()
            busy = false
            error = result
        }
    }
}
