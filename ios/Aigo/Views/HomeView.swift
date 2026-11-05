import SwiftUI
import UIKit

/// Home: status sentence → Needs you (card stack) → Since you left (digest)
/// → Everyone (all sessions).
struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showAllEvents = false
    @State private var killing: SessionInfo?
    @State private var removing: SessionInfo?
    @State private var banner: String?

    private static let collapsedEvents = 6

    var body: some View {
        List {
            statusBlock
                .homeRow(top: 8, bottom: 6)

            if let problem = store.connectionProblem {
                ConnectionProblemCard(problem: problem)
                    .homeRow(top: 4, bottom: 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let banner = banner {
                InlineBanner(text: banner) { self.banner = nil }
                    .homeRow(top: 4, bottom: 8)
            }

            let pending = store.pendingItems
            if !pending.isEmpty {
                NeedsYouStack(items: pending)
                    .homeRow(top: 14, bottom: 6)
            }

            digest

            everyone
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            dispatchBar
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle("Home")
        .refreshable {
            await store.refresh()
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.pendingItems.map { $0.id })
        .animation(.easeInOut(duration: 0.25), value: store.sortedSessions.map { $0.id })
        .confirmationDialog("Kill this session?",
                            isPresented: Binding(get: { killing != nil }, set: { if !$0 { killing = nil } }),
                            titleVisibility: .visible,
                            presenting: killing) { s in
            Button("Kill \(s.displayTitle)", role: .destructive) {
                act { await store.kill(s.id) }
            }
        } message: { _ in
            Text("The process on your PC is stopped. You can restart or resume it later.")
        }
        .confirmationDialog("Remove this session?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible,
                            presenting: removing) { s in
            Button("Remove \(s.displayTitle)", role: .destructive) {
                act { await store.remove(s.id) }
            }
        } message: { _ in
            Text("It disappears from Aigo on every device.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Wordmark()
                .layoutPriority(2)
            Spacer(minLength: 8)
            HostSwitcher()
                .layoutPriority(1)
            Button {
                store.path.append(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Settings"))
            Button {
                Haptics.tap()
                store.openNewWork()
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.lime)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Start new work"))
            .disabled(store.client == nil)
        }
        .padding(.leading, Theme.gutter)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(Theme.bg.opacity(0.97).ignoresSafeArea(edges: .top))
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.statusSentence)
                .font(Theme.display)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: store.statusSentence)
            Text(statusDetail)
                .font(Theme.monoCaption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusDetail: String {
        var parts = [store.hostLabel, store.connection.label]
        let n = store.sessions.count
        if store.hasSnapshot {
            parts.append(n == 1 ? "1 session" : "\(n) sessions")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Since you left

    @ViewBuilder
    private var digest: some View {
        let events = store.timeline
        if !events.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Since you left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.text)
                if let left = store.lastLeftAt {
                    Text(Clock.ago(left))
                        .font(.title3)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityAddTraits(.isHeader)
            .homeRow(top: 22, bottom: 12)

            let shown = showAllEvents ? Array(events.prefix(40)) : Array(events.prefix(HomeView.collapsedEvents))
            ForEach(Array(shown.enumerated()), id: \.element.id) { pair in
                TimelineRow(event: pair.element,
                            isLast: pair.offset == shown.count - 1,
                            canOpen: pair.element.sessionId.flatMap { store.session(id: $0) } != nil) {
                    if let sid = pair.element.sessionId {
                        store.openSession(sid)
                    }
                }
                .homeRow(top: 0, bottom: 0)
            }

            if events.count > HomeView.collapsedEvents {
                Button {
                    Haptics.tap()
                    withAnimation(.easeInOut(duration: 0.25)) { showAllEvents.toggle() }
                } label: {
                    Text(showAllEvents ? "Show less" : "Show \(min(events.count, 40) - HomeView.collapsedEvents) more")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.lime)
                        .frame(minHeight: 44)
                        .padding(.leading, 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .homeRow(top: 0, bottom: 0)
            }
        }
    }

    // MARK: - Everyone

    @ViewBuilder
    private var everyone: some View {
        SectionHeader(title: "Everyone", count: store.sessions.isEmpty ? nil : store.sessions.count)
            .homeRow(top: 24, bottom: 2)

        if !store.hasSnapshot && store.connectionProblem == nil {
            SkeletonRows(count: 3)
                .homeRow(top: 0, bottom: 0)
        } else if store.sessions.isEmpty {
            emptyState
                .homeRow(top: 8, bottom: 24)
        } else {
            ForEach(store.sortedSessions) { session in
                Button {
                    store.openSession(session.id)
                } label: {
                    SessionRow(session: session, activity: store.activity[session.id] ?? [])
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: Theme.gutter, bottom: 0, trailing: Theme.gutter))
                .listRowBackground(Theme.bg)
                .listRowSeparatorTint(Theme.lineSoft)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    swipeButtons(session)
                }
                .contextMenu {
                    contextButtons(session)
                }
            }
            Color.clear
                .frame(height: 24)
                .homeRow(top: 0, bottom: 0)
        }
    }

    @ViewBuilder
    private func swipeButtons(_ s: SessionInfo) -> some View {
        if s.isRunning {
            Button {
                killing = s
            } label: {
                Label("Kill", systemImage: "xmark.octagon")
            }
            .tint(Theme.coral)
            if s.status == .working || s.status == .stalled || s.status == .needsYou {
                Button {
                    Haptics.tap()
                    act { await store.interrupt(s.id) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(Color(aigoHex: 0x3A3F47))
            }
        } else {
            Button {
                removing = s
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .tint(Theme.coral)
            Button {
                Haptics.tap()
                act { await store.restart(s.id) }
            } label: {
                Label(s.isAgent ? "Resume" : "Restart", systemImage: "arrow.clockwise")
            }
            .tint(Color(aigoHex: 0x4A5A14))
        }
    }

    @ViewBuilder
    private func contextButtons(_ s: SessionInfo) -> some View {
        Button {
            store.openSession(s.id)
        } label: {
            Label("Open", systemImage: "arrow.up.forward.square")
        }
        if s.isRunning {
            Button {
                act { await store.interrupt(s.id) }
            } label: {
                Label("Stop turn", systemImage: "stop.circle")
            }
            Button(role: .destructive) {
                killing = s
            } label: {
                Label("Kill…", systemImage: "xmark.octagon")
            }
        } else {
            Button {
                act { await store.restart(s.id) }
            } label: {
                Label(s.isAgent ? "Resume" : "Restart", systemImage: "arrow.clockwise")
            }
        }
        if let cwd = s.cwd, !cwd.isEmpty {
            Button {
                UIPasteboard.general.string = cwd
                Haptics.success()
            } label: {
                Label("Copy folder path", systemImage: "doc.on.doc")
            }
        }
        Button(role: .destructive) {
            removing = s
        } label: {
            Label("Remove…", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Theme.lime)
                    .frame(width: 12, height: 12)
                    .shadow(color: Theme.lime.opacity(0.7), radius: 8)
                Text("Ready when you are")
                    .font(Theme.monoLabel)
                    .tracking(0.8)
                    .foregroundStyle(Theme.lime)
            }
            Text("Nothing is running on \(store.hostLabel).")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Start an agent in one of your projects. Its progress shows up here, and anything it needs from you lands on top.")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Haptics.tap()
                store.openNewWork(agent: codexInstalled ? "codex" : nil)
            } label: {
                Label(codexInstalled ? "Start Codex in a project" : "Start an agent in a project", systemImage: "sparkles")
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(store.client == nil)
            Button {
                store.openNewWork(agent: NewWorkView.terminalChoice)
            } label: {
                Label("Open a terminal", systemImage: "terminal")
            }
            .buttonStyle(OutlineButtonStyle())
            .disabled(store.client == nil)
        }
        .padding(16)
        .aigoCard()
    }

    private var codexInstalled: Bool {
        if let codex = store.agents.first(where: { $0.id == "codex" }) {
            return codex.installed
        }
        return store.agents.isEmpty
    }

    /// "› Start work…" bar, like the dispatch bar on the desktop.
    private var dispatchBar: some View {
        Button {
            Haptics.tap()
            store.openNewWork()
        } label: {
            HStack(spacing: 10) {
                Text("›")
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.lime)
                Text("Start work…")
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Go")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background(Theme.lime, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(Color(aigoHex: 0x101215), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(aigoHex: 0x2B2F35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.client == nil)
        .accessibilityLabel(Text("Start new work"))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg, Theme.bg], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func act(_ op: @escaping () async -> String?) {
        Task {
            if let err = await op() {
                Haptics.error()
                withAnimation { banner = err }
            }
        }
    }
}

/// One entry of the "Since you left" timeline (rail + dot + text).
struct TimelineRow: View {
    let event: TimelineEvent
    let isLast: Bool
    let canOpen: Bool
    let onOpen: () -> Void

    var body: some View {
        Button {
            if canOpen { onOpen() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Clock.short(event.date)) · \(event.lane)")
                    .font(Theme.monoCaption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Text(event.text)
                    .font(event.kind == .needsYou ? .callout.weight(.semibold) : .callout)
                    .foregroundStyle(event.kind == .needsYou ? Theme.coralText : Theme.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if canOpen {
                    Text("Open lane →")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.lime)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)
            .padding(.bottom, 16)
            .frame(minHeight: 44, alignment: .top)
            .background(alignment: .topLeading) { rail }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var rail: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(event.color)
                .frame(width: 12, height: 12)
                .background(Circle().fill(event.kind == .needsYou ? Theme.coral.opacity(0.2) : .clear).frame(width: 20, height: 20))
                .padding(.top, 2)
            if !isLast {
                Rectangle()
                    .fill(Theme.lineSoft)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: 14)
    }
}

extension View {
    /// Full-width Home list row on the graphite background without separators.
    func homeRow(top: CGFloat, bottom: CGFloat) -> some View {
        self
            .listRowInsets(EdgeInsets(top: top, leading: Theme.gutter, bottom: bottom, trailing: Theme.gutter))
            .listRowBackground(Theme.bg)
            .listRowSeparator(.hidden)
    }
}
