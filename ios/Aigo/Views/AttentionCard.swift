import SwiftUI

/// "Needs you" on Home: the oldest pending request on top, the rest peeking
/// behind it. Answer one and the next slides up, so several can be answered
/// in a row without navigating. Swipe right to approve, left to deny.
struct NeedsYouStack: View {
    let items: [InboxItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Needs you", count: items.count, tint: Theme.coral)
                if let top = items.first, top.canSwipe {
                    Text("swipe → approve · ← deny")
                        .font(Theme.monoCaption)
                        .foregroundStyle(Theme.secondary.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityHidden(true)
                }
            }
            if let top = items.first {
                ZStack {
                    AttentionCard(item: top, swipeEnabled: true, position: items.count > 1 ? "1 of \(items.count)" : nil)
                        .id(top.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
                .background(alignment: .bottom) {
                    plates(count: min(items.count - 1, 2))
                }
                .padding(.bottom, CGFloat(min(items.count - 1, 2)) * 7)
            }
        }
    }

    /// Edges of the cards waiting behind the top one.
    private func plates(count: Int) -> some View {
        ZStack(alignment: .bottom) {
            ForEach(0..<max(count, 0), id: \.self) { i in
                let depth = CGFloat(count - i)
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.coralWash.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(Theme.coral.opacity(0.35 - Double(depth) * 0.1), lineWidth: 1))
                    .padding(.horizontal, depth * 10)
                    .offset(y: depth * 7)
            }
        }
        .accessibilityHidden(true)
    }
}

extension InboxItem {
    /// Plain approve/deny requests can be swiped; choices need a tap.
    var canSwipe: Bool {
        let k = kind ?? ""
        if k == "question" { return false }
        if k == "ask" && !(options ?? []).isEmpty { return false }
        return true
    }

    var isCommand: Bool {
        let tool = (toolName ?? "").lowercased()
        return ["bash", "shell", "powershell", "exec", "exec_command", "local_shell", "run_command"].contains(tool)
    }
}

/// One pending approval / question.
struct AttentionCard: View {
    let item: InboxItem
    var swipeEnabled: Bool = false
    var position: String? = nil
    /// Hides the "Open" link (already inside the session).
    var inSession: Bool = false

    @EnvironmentObject private var store: AppStore
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?
    @State private var offset: CGFloat = 0

    private static let threshold: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Text(item.title ?? "Needs your answer")
                .font(Theme.cardTitle)
                .foregroundStyle(Theme.coralText)
                .fixedSize(horizontal: false, vertical: true)

            if let message = item.message, !message.isEmpty {
                Text(message)
                    .font(item.isCommand ? Theme.monoSmall : .callout)
                    .foregroundStyle(item.isCommand ? Theme.coralCode : Theme.text.opacity(0.92))
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .textSelection(.enabled)
            }

            if let error = error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            actions
        }
        .padding(14)
        .aigoCard(border: Theme.coral.opacity(0.8), fill: Theme.coralWash)
        .overlay(alignment: offset > 0 ? .leading : .trailing) { swipeHint }
        .offset(x: offset)
        .rotationEffect(.degrees(Double(offset) / 30), anchor: .bottom)
        .gesture(drag, including: swipeEnabled && item.canSwipe && !busy && !confirming ? .all : .subviews)
        .disabled(busy)
        .opacity(busy && offset == 0 ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: confirming)
        .animation(.easeInOut(duration: 0.2), value: error)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Approve")) {
            if item.canSwipe { approveTapped() }
        }
        .accessibilityAction(named: Text("Deny")) {
            if item.canSwipe { denyTapped() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.coral)
                .frame(width: 9, height: 9)
                .background(Circle().fill(Theme.coral.opacity(0.25)).frame(width: 17, height: 17))
            Text(item.contextLine)
                .font(Theme.monoCaption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            if let position = position {
                Text("· \(position)")
                    .font(Theme.monoCaption)
                    .foregroundStyle(Theme.secondary.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !inSession, let sid = item.sessionId, !sid.isEmpty {
                Button {
                    store.openSession(sid)
                } label: {
                    Text("Open →")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.lime)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .padding(.vertical, -10)
            }
        }
    }

    @ViewBuilder
    private var swipeHint: some View {
        if abs(offset) > 24 {
            let approving = offset > 0
            let strength = min(1.0, Double(abs(offset)) / Double(AttentionCard.threshold))
            Text(approving ? "APPROVE" : "DENY")
                .font(Theme.monoLabel)
                .tracking(1.2)
                .foregroundStyle(approving ? Theme.onCoral : Theme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(approving ? Theme.coral : Theme.surface2, in: Capsule())
                .opacity(strength)
                .padding(14)
                .rotationEffect(.degrees(approving ? -8 : 8))
                .allowsHitTesting(false)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                let w = value.translation.width
                guard abs(w) > abs(value.translation.height) else { return }
                let crossed = abs(offset) < AttentionCard.threshold && abs(w) >= AttentionCard.threshold
                offset = w
                if crossed { Haptics.selection() }
            }
            .onEnded { value in
                let w = value.translation.width
                let flung = value.predictedEndTranslation.width
                if w > AttentionCard.threshold || (w > 40 && flung > AttentionCard.threshold * 2.5) {
                    approveTapped()
                } else if w < -AttentionCard.threshold || (w < -40 && flung < -AttentionCard.threshold * 2.5) {
                    denyTapped()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { offset = 0 }
                }
            }
    }

    @ViewBuilder
    private var actions: some View {
        let options = item.options ?? []
        if item.kind == "ask" && !options.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { pair in
                    Button(pair.element) {
                        Haptics.approve()
                        run(flyTo: 0) { await store.decide(item, approve: true, choice: pair.element) }
                    }
                    .buttonStyle(OutlineButtonStyle(border: Theme.coralLine))
                }
                Button("Deny") { denyTapped() }
                    .buttonStyle(OutlineButtonStyle(tint: Theme.secondary, border: Theme.coralLine))
            }
        } else if item.kind == "question" {
            if !options.isEmpty && !(item.sessionId ?? "").isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(options.enumerated()), id: \.offset) { pair in
                        Button {
                            Haptics.approve()
                            run(flyTo: 0) { await store.answerQuestion(item, number: pair.offset + 1, label: pair.element) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(pair.offset + 1).")
                                    .font(Theme.monoSmall)
                                    .foregroundStyle(Theme.secondary)
                                Text(pair.element)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(OutlineButtonStyle(border: Theme.coralLine))
                    }
                }
            } else if let sid = item.sessionId, !sid.isEmpty, !inSession {
                Button("Answer in the session") {
                    store.openSession(sid)
                }
                .buttonStyle(FilledButtonStyle(fill: Theme.coral, foreground: Theme.onCoral))
            } else if inSession {
                Text("Answer it in the terminal below.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            } else {
                Text("This agent runs outside Aigo. Answer it in its own terminal.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
        } else if confirming {
            VStack(alignment: .leading, spacing: 10) {
                Label("This looks destructive. Run it anyway?", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Cancel") {
                        Haptics.tap()
                        confirming = false
                    }
                    .buttonStyle(OutlineButtonStyle(border: Theme.coralLine))
                    Button("Yes, run it") {
                        confirming = false
                        Haptics.approve()
                        run(flyTo: swipeEnabled ? 700 : 0) { await store.decide(item, approve: true) }
                    }
                    .buttonStyle(FilledButtonStyle(fill: Theme.coral, foreground: Theme.onCoral))
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            HStack(spacing: 10) {
                Button(item.kind == "plan" ? "Approve plan" : "Approve") { approveTapped() }
                    .buttonStyle(FilledButtonStyle(fill: Theme.coral, foreground: Theme.onCoral))
                Button("Deny") { denyTapped() }
                    .buttonStyle(OutlineButtonStyle(border: Theme.coralLine))
            }
        }
    }

    private func approveTapped() {
        if item.looksDestructive {
            // Two-step: a destructive command always needs the explicit "Yes, run it".
            Haptics.warning()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                offset = 0
                confirming = true
            }
            return
        }
        Haptics.approve()
        run(flyTo: swipeEnabled ? 700 : 0) { await store.decide(item, approve: true) }
    }

    private func denyTapped() {
        Haptics.deny()
        run(flyTo: swipeEnabled ? -700 : 0) { await store.decide(item, approve: false) }
    }

    private func run(flyTo target: CGFloat, _ op: @escaping () async -> String?) {
        busy = true
        error = nil
        if target != 0 {
            withAnimation(.easeIn(duration: 0.22)) { offset = target }
        }
        Task {
            let result = await op()
            busy = false
            if let result = result {
                Haptics.error()
                error = result
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { offset = 0 }
            }
        }
    }
}
