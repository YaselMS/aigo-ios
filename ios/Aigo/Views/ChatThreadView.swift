import SwiftUI
import UIKit

/// Structured chat of a chat-mode session (host API §7k): bubbles with
/// streaming markdown, compact tool rows, inline approval cards, plan
/// checklists and end-of-turn lines.
struct ChatThreadView: View {
    @ObservedObject var model: ChatModel
    /// Follow new output; off while the user scrolls back.
    @State private var follow = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.hasMore {
                        Button("Load earlier messages") {
                            model.loadOlder()
                        }
                        .font(.aigo(.footnote, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    if model.items.isEmpty {
                        emptyState
                    }
                    ForEach(model.items) { item in
                        ChatItemRow(item: item, model: model)
                            .id(item.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("chat-bottom")
                        .onAppear { follow = true }
                        .onDisappear { follow = false }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                if !follow && !model.items.isEmpty {
                    Button {
                        follow = true
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: Theme.iconWeight))
                            .foregroundStyle(Theme.text)
                            .frame(width: 40, height: 40)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .accessibilityLabel(Text("Jump to latest"))
                    .transition(.opacity)
                }
            }
            .onChange(of: model.bottomTick) { _, _ in
                // A new item: follow it (a message the user just sent always scrolls).
                if follow || model.items.last?.type == "user" {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: model.streamTick) { _, _ in
                if follow {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if !model.loaded && model.error == nil {
                ProgressView().tint(Theme.muted)
            }
            Text(model.error ?? (model.loaded ? "No messages yet. Say what it should do." : "Loading the conversation…"))
                .font(.aigo(.callout))
                .foregroundStyle(model.error == nil ? Theme.muted : Theme.danger)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 48)
    }
}

/// One timeline item.
struct ChatItemRow: View {
    let item: ChatItem
    /// Not observed: a row redraws only when its own item changes.
    let model: ChatModel

    var body: some View {
        switch item.type {
        case "user":
            ChatUserBubble(item: item)
        case "assistant":
            ChatAssistantText(item: item)
        case "reasoning":
            ChatReasoningRow(item: item)
        case "tool":
            ChatToolRow(item: item)
                .padding(.leading, (item.parent ?? "").isEmpty ? 0 : 14)
        case "plan":
            ChatPlanView(item: item)
        case "request":
            ChatRequestCard(item: item, model: model)
        case "notice":
            ChatNoticeLine(item: item)
        case "turn":
            ChatTurnLine(item: item)
        default:
            EmptyView()
        }
    }
}

// MARK: - Messages

struct ChatUserBubble: View {
    let item: ChatItem

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.aigo(.callout))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .textSelection(.enabled)
                if let by = item.by, !by.isEmpty {
                    Text(by)
                        .font(.aigo(.caption2))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

struct ChatAssistantText: View {
    let item: ChatItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChatMarkdown(text: item.text ?? "")
            if item.isRunning {
                ChatStreamingDot()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small pulsing lime block while text streams.
struct ChatStreamingDot: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: 7, height: 13)
            .opacity(on ? 0.25 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = true }
            }
            .accessibilityLabel(Text("Writing"))
    }
}

/// Collapsed "Thought"; tap for the summary.
struct ChatReasoningRow: View {
    let item: ChatItem
    @State private var expanded = false

    var body: some View {
        let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Haptics.selection()
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .regular))
                    Text(item.isRunning ? "Thinking…" : "Thought")
                        .font(.aigo(.caption))
                    Spacer()
                }
                .foregroundStyle(Theme.muted)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            if expanded && !text.isEmpty {
                Text(text)
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .textSelection(.enabled)
            }
        }
    }
}

struct ChatNoticeLine: View {
    let item: ChatItem

    var body: some View {
        HStack(spacing: 6) {
            if item.isRunning {
                ProgressView().controlSize(.mini).tint(Theme.muted)
            }
            Text((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.aigo(.caption))
                .foregroundStyle(item.status == "error" ? Theme.danger : Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// End of a turn: status, duration, tokens; the error text when it failed.
struct ChatTurnLine: View {
    let item: ChatItem

    var body: some View {
        let error = item.status == "error"
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Rectangle().fill(Theme.line).frame(height: 1)
                Text(label)
                    .font(.aigo(.caption2))
                    .foregroundStyle(error ? Theme.danger : Theme.muted)
                    .lineLimit(1)
                    .fixedSize()
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            if error, let t = item.text, !t.isEmpty {
                Text(t)
                    .font(.aigo(.caption))
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private var label: String {
        var parts: [String]
        switch item.status {
        case "error": parts = ["Failed"]
        case "interrupted": parts = ["Stopped"]
        default: parts = ["Done"]
        }
        if let ms = item.ms, ms > 0 { parts.append(ChatFormat.duration(ms)) }
        if let total = item.usage?.total, total > 0 { parts.append("\(ChatFormat.tokens(total)) tokens") }
        return parts.joined(separator: " · ")
    }
}

enum ChatFormat {
    static func duration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let s = Double(ms) / 1000
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60
        return "\(m)m \(Int(s) % 60)s"
    }

    static func tokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}

// MARK: - Tools

/// One compact row: kind icon, verb, title, status, time. Tap for the
/// output or the coloured diff.
struct ChatToolRow: View {
    let item: ChatItem
    @State private var expanded = false

    private var tool: ChatTool { item.tool ?? ChatTool() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.selection()
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(item.status == "error" ? Theme.danger : Theme.muted)
                        .frame(width: 14)
                    Text(verb)
                        .font(.aigo(.caption, .semibold))
                        .foregroundStyle(Theme.text)
                        .fixedSize()
                    Text(oneLine(tool.title ?? ""))
                        .font(.aigo(.caption))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    statusView
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)
            if expanded {
                details
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var hasDetail: Bool {
        !(tool.output ?? "").isEmpty || !(tool.diff ?? "").isEmpty || !(tool.detail ?? "").isEmpty
            || (tool.title ?? "").count > 40
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.status {
        case "running":
            ProgressView().controlSize(.mini).tint(Theme.accent)
        case "error":
            Text(tool.exit.map { "exit \($0)" } ?? "failed")
                .font(.aigo(.caption2))
                .foregroundStyle(Theme.danger)
                .fixedSize()
        case "declined":
            Text("declined").font(.aigo(.caption2)).foregroundStyle(Theme.danger).fixedSize()
        case "interrupted":
            Text("stopped").font(.aigo(.caption2)).foregroundStyle(Theme.muted).fixedSize()
        default:
            if let ms = item.ms, ms > 0 {
                Text(ChatFormat.duration(ms))
                    .font(.aigo(.caption2))
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if (tool.title ?? "").count > 40 || (tool.title ?? "").contains("\n") {
                Text(tool.title ?? "")
                    .font(.custom(TerminalScreen.fontName, fixedSize: 11))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
            }
            if let detail = tool.detail, !detail.isEmpty {
                Text(detail)
                    .font(.aigo(.caption2))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            if let diff = tool.diff, !diff.isEmpty {
                ChatDiffView(diff: diff)
            }
            if let output = tool.output, !output.isEmpty {
                ChatOutputView(text: output)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? s
    }

    private var icon: String {
        switch tool.kind ?? "" {
        case "command": return "terminal"
        case "edit": return "pencil"
        case "read": return "doc.text"
        case "search": return "magnifyingglass"
        case "mcp": return "puzzlepiece.extension"
        case "web": return "globe"
        case "agent": return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }

    private var verb: String {
        let running = item.isRunning
        switch tool.kind ?? "" {
        case "command": return running ? "Running" : "Ran"
        case "edit": return running ? "Editing" : "Edited"
        case "read": return running ? "Reading" : "Read"
        case "search": return running ? "Searching" : "Searched"
        case "mcp": return running ? "Calling" : "Called"
        case "web": return running ? "Fetching" : "Fetched"
        case "agent": return running ? "Delegating" : "Agent"
        default: return running ? "Using" : "Used"
        }
    }
}

/// Command output, mono, the last 300 lines.
struct ChatOutputView: View {
    let text: String

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        let shown = lines.count > 300 ? Array(lines.suffix(300)) : lines
        VStack(alignment: .leading, spacing: 4) {
            if lines.count > 300 {
                Text("… \(lines.count - 300) earlier lines")
                    .font(.aigo(.caption2))
                    .foregroundStyle(Theme.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(shown.joined(separator: "\n"))
                    .font(.custom(TerminalScreen.fontName, fixedSize: 11))
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .fixedSize()
                    .padding(8)
            }
            .background(Theme.term, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .textSelection(.enabled)
        }
    }
}

/// Unified diff with + / - / @@ colours (as the Changes tab).
struct ChatDiffView: View {
    let diff: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ChatDiffView.lines(diff).enumerated()), id: \.offset) { pair in
                    Text(pair.element.isEmpty ? " " : pair.element)
                        .font(.custom(TerminalScreen.fontName, fixedSize: 11))
                        .foregroundStyle(ChangesView.color(pair.element))
                        .fixedSize()
                }
            }
            .padding(8)
        }
        .background(Theme.term, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .textSelection(.enabled)
    }

    static func lines(_ diff: String) -> [String] {
        let all = diff.components(separatedBy: "\n").filter { !$0.hasPrefix("diff --git") && !$0.hasPrefix("index ") }
        return Array(all.prefix(400))
    }
}

// MARK: - Plan

struct ChatPlanView: View {
    let item: ChatItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plan")
                .font(.aigo(.caption, .semibold))
                .foregroundStyle(Theme.muted)
            if let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, (item.steps ?? []).isEmpty {
                ChatMarkdown(text: t)
            }
            ForEach(Array((item.steps ?? []).enumerated()), id: \.offset) { pair in
                let step = pair.element
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(step.status))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(color(step.status))
                        .frame(width: 14)
                    Text(step.text ?? "")
                        .font(.aigo(.footnote))
                        .foregroundStyle(step.status == "done" ? Theme.muted : Theme.text)
                        .strikethrough(step.status == "done", color: Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(step.text ?? ""), \(step.status ?? "pending")"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aigoCard()
    }

    private func icon(_ status: String?) -> String {
        switch status {
        case "done": return "checkmark.square.fill"
        case "running": return "arrow.right.square"
        default: return "square"
        }
    }

    private func color(_ status: String?) -> Color {
        switch status {
        case "done": return Theme.done
        case "running": return Theme.work
        default: return Theme.muted
        }
    }
}

// MARK: - Requests

/// Inline approval / question card with the harness's own options. Sends
/// the option's native id, never its label.
struct ChatRequestCard: View {
    let item: ChatItem
    let model: ChatModel

    @State private var busy = false
    @State private var error: String?
    @State private var confirming: ChatOption?
    @State private var answers: [String: String] = [:]

    private var request: ChatRequest { item.request ?? ChatRequest() }
    private var open: Bool { (item.status ?? "open") == "open" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(request.title ?? (request.kind == "question" ? "A question" : "Needs your approval"))
                    .font(.aigo(.footnote, .semibold))
                    .foregroundStyle(open ? Theme.ask : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let tool = request.tool, !tool.isEmpty {
                    Text(tool)
                        .font(.aigo(.caption2))
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                }
            }
            if let body = request.body, !body.isEmpty {
                Text(body)
                    .font(.custom(TerminalScreen.fontName, fixedSize: 12))
                    .foregroundStyle(request.kind == "approval" ? Theme.text : Theme.text.opacity(0.92))
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Theme.term, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .textSelection(.enabled)
            }
            if open {
                openActions
            } else {
                closedLine
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.ask)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aigoCard(border: open ? Theme.askLine : Theme.line, fill: open ? Theme.askSoft : Theme.panel)
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.2), value: item.status)
    }

    @ViewBuilder
    private var closedLine: some View {
        let who = (item.by ?? "").isEmpty ? "" : " · \(item.by!)"
        if item.status == "answered" {
            Label("\((request.answer ?? "").isEmpty ? "Answered" : request.answer!)\(who)", systemImage: "checkmark")
                .font(.aigo(.caption))
                .foregroundStyle(Theme.muted)
        } else {
            Text("No longer answerable.")
                .font(.aigo(.caption))
                .foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder
    private var openActions: some View {
        let questions = request.questions ?? []
        let options = request.options ?? []
        if let c = confirming {
            VStack(alignment: .leading, spacing: 8) {
                Label("This looks destructive. Run it anyway?", systemImage: "exclamationmark.triangle.fill")
                    .font(.aigo(.footnote, .semibold))
                    .foregroundStyle(Theme.ask)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Yes, \(c.title)") {
                        confirming = nil
                        Haptics.approve()
                        send(option: c.id)
                    }
                    .buttonStyle(SoftButtonStyle(tint: Theme.ask, text: Theme.ask))
                    Button("Cancel") {
                        Haptics.tap()
                        confirming = nil
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        } else if !questions.isEmpty {
            questionForm(questions)
            if !options.isEmpty {
                optionButtons(options)
            }
        } else {
            optionButtons(options)
        }
    }

    private func optionButtons(_ options: [ChatOption]) -> some View {
        VStack(spacing: 6) {
            ForEach(options) { option in
                Button(option.title) {
                    tapped(option)
                }
                .buttonStyle(style(option))
            }
        }
    }

    private func style(_ option: ChatOption) -> AnyButtonStyleBox {
        switch option.style ?? "" {
        case "primary": return AnyButtonStyleBox(.soft(Theme.ask, Theme.ask))
        case "danger": return AnyButtonStyleBox(.secondary(Theme.ask))
        default: return AnyButtonStyleBox(.secondary(Theme.text))
        }
    }

    @ViewBuilder
    private func questionForm(_ questions: [ChatQuestion]) -> some View {
        let single = questions.count == 1 && questions[0].freeText != true && !(questions[0].options ?? []).isEmpty
        VStack(alignment: .leading, spacing: 10) {
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 6) {
                    if let h = q.header, !h.isEmpty {
                        Text(h)
                            .font(.aigo(.caption2))
                            .foregroundStyle(Theme.muted)
                    }
                    if let t = q.text, !t.isEmpty {
                        Text(t)
                            .font(.aigo(.footnote))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(q.options ?? []) { o in
                        let picked = answers[q.id] == o.id
                        Button {
                            Haptics.selection()
                            if single {
                                send(option: o.id)
                            } else {
                                answers[q.id] = o.id
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if !single {
                                    Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(picked ? Theme.accent : Theme.muted)
                                }
                                Text(o.title)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle(alignment: .leading))
                    }
                    if q.freeText == true {
                        let binding = Binding<String>(
                            get: { answers[q.id] ?? "" },
                            set: { answers[q.id] = $0 })
                        Group {
                            if q.secret == true {
                                SecureField("Answer", text: binding)
                            } else {
                                TextField("Answer", text: binding, axis: .vertical)
                                    .lineLimit(1...4)
                            }
                        }
                        .font(.aigo(.footnote))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 40)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .strokeBorder(Theme.line, lineWidth: 1))
                    }
                }
            }
            if !single {
                let ready = questions.allSatisfy { !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
                Button("Send answer") {
                    Haptics.approve()
                    run { await model.respond(requestId: item.id, answers: answers) }
                }
                .buttonStyle(SoftButtonStyle(tint: Theme.ask, text: Theme.ask))
                .disabled(!ready)
            }
        }
    }

    private func tapped(_ option: ChatOption) {
        if option.style == "primary" && looksDestructive {
            Haptics.warning()
            confirming = option
            return
        }
        if option.style == "danger" { Haptics.deny() } else { Haptics.approve() }
        send(option: option.id)
    }

    private var looksDestructive: Bool {
        InboxItem(id: item.id, title: request.title, message: request.body, toolName: request.tool).looksDestructive
    }

    private func send(option: String) {
        run { await model.respond(requestId: item.id, option: option) }
    }

    private func run(_ op: @escaping () async -> String?) {
        busy = true
        error = nil
        Task {
            let err = await op()
            busy = false
            if let err {
                Haptics.error()
                error = err
            }
        }
    }
}

/// Picks one of the two shared button styles at runtime.
struct AnyButtonStyleBox: ButtonStyle {
    enum Kind {
        case soft(Color, Color)
        case secondary(Color)
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .soft(let tint, let text):
            SoftButtonStyle(tint: tint, text: text).makeBody(configuration: configuration)
        case .secondary(let tint):
            SecondaryButtonStyle(tint: tint).makeBody(configuration: configuration)
        }
    }
}

// MARK: - Composer

/// Model / effort / access pickers, the message field, Send (Queue while a
/// turn runs) and Stop only during a turn.
struct ChatComposer: View {
    @ObservedObject var model: ChatModel
    let placeholder: String
    var onError: (String) -> Void = { _ in }

    @State private var draft = ""
    @State private var sending = false
    @State private var stopping = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = model.thread {
                pickers(t)
                if t.live == false {
                    Text("Stopped. Your next message resumes it.")
                        .font(.aigo(.caption2))
                        .foregroundStyle(Theme.muted)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Text("›")
                    .font(.aigo(.body, .medium))
                    .foregroundStyle(Theme.faint)
                    .frame(minHeight: 42)
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .textInputAutocapitalization(.sentences)
                    .font(.aigo(.footnote))
                    .padding(.vertical, 12)
                    .foregroundStyle(Theme.text)
                if model.isRunning {
                    Button {
                        stop()
                    } label: {
                        Group {
                            if stopping {
                                ProgressView().tint(Theme.danger)
                            } else {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 13, weight: Theme.iconWeight))
                            }
                        }
                        .frame(width: 40, height: 40)
                        .background(Theme.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Stop the turn"))
                    .padding(.bottom, 1)
                    .transition(.opacity)
                }
                Button {
                    send()
                } label: {
                    Group {
                        if sending {
                            ProgressView().tint(Theme.muted)
                        } else if model.isRunning {
                            Text("Queue")
                                .font(.aigo(.caption, .medium))
                                .padding(.horizontal, 8)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .regular))
                        }
                    }
                    .frame(minWidth: 40, minHeight: 40)
                    .background(canSend ? Theme.accentBg : Theme.tint,
                                in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .foregroundStyle(canSend ? Theme.accentInk : Theme.faint)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(Text(model.isRunning ? "Queue message" : "Send"))
                .padding(.bottom, 1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 2)
            .padding(.vertical, 1)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1))
        }
        .animation(.easeInOut(duration: 0.2), value: model.isRunning)
    }

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Pickers

    @ViewBuilder
    private func pickers(_ t: ChatThread) -> some View {
        let models = t.models ?? []
        let current = models.first { $0.id == t.model } ?? models.first { $0.isDefault == true }
        let efforts = current?.efforts ?? []
        let modes = t.accessModes ?? []
        if !models.isEmpty || !efforts.isEmpty || !modes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if !models.isEmpty {
                        Menu {
                            ForEach(models) { m in
                                Button {
                                    apply(model: m.id)
                                } label: {
                                    if m.id == current?.id {
                                        Label(m.title, systemImage: "checkmark")
                                    } else {
                                        Text(m.title)
                                    }
                                }
                            }
                        } label: {
                            chip(current?.title ?? (t.model ?? "Model"), icon: "cpu")
                        }
                        .accessibilityLabel(Text("Model: \(current?.title ?? t.model ?? "default")"))
                    }
                    if !efforts.isEmpty {
                        let effort = t.effort ?? current?.defaultEffort ?? ""
                        Menu {
                            ForEach(efforts, id: \.self) { e in
                                Button {
                                    apply(effort: e)
                                } label: {
                                    if e == effort {
                                        Label(e, systemImage: "checkmark")
                                    } else {
                                        Text(e)
                                    }
                                }
                            }
                        } label: {
                            chip(effort.isEmpty ? "Effort" : effort, icon: "gauge.medium")
                        }
                        .accessibilityLabel(Text("Effort: \(effort.isEmpty ? "default" : effort)"))
                    }
                    if !modes.isEmpty {
                        let access = t.access ?? "default"
                        Menu {
                            ForEach(modes, id: \.self) { m in
                                Button {
                                    apply(access: m)
                                } label: {
                                    if m == access {
                                        Label(ChatAccess.label(m), systemImage: "checkmark")
                                    } else {
                                        Text(ChatAccess.label(m))
                                    }
                                }
                            }
                        } label: {
                            chip(ChatAccess.label(access), icon: "lock.shield")
                        }
                        .accessibilityLabel(Text("Access: \(ChatAccess.label(access))"))
                    }
                    if let pct = t.ctxPct, pct > 0 {
                        Text("ctx \(pct)%")
                            .font(.aigo(.caption2))
                            .foregroundStyle(pct >= 85 ? Theme.ask : Theme.muted)
                            .padding(.horizontal, 6)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func chip(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .regular))
            Text(title)
                .font(.aigo(.caption))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .regular))
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Theme.tint, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .fixedSize()
    }

    private func apply(model id: String? = nil, effort: String? = nil, access: String? = nil) {
        Haptics.selection()
        Task {
            if let err = await model.settings(model: id, effort: effort, access: access) {
                Haptics.error()
                onError(err)
            }
        }
    }

    // MARK: Actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Haptics.tap()
        let kept = draft
        draft = ""
        Task {
            if let err = await model.send(text, by: UIDevice.current.name) {
                Haptics.error()
                if draft.isEmpty { draft = kept }
                onError(err)
            }
            sending = false
        }
    }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        Haptics.tap()
        Task {
            if let err = await model.interrupt() {
                Haptics.error()
                onError(err)
            }
            stopping = false
        }
    }
}
