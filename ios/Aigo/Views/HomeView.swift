import SwiftUI
import UIKit

/// Home (round 3): a slim top row (wordmark, PC switcher, quiet icons), the
/// board as calm sections (Needs you with one-tap answers, Working, To
/// review, Done today; empty sections hidden, no zero counts), recent
/// sessions to continue, and New chat / Continue at the bottom.
struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var updates: UpdateChecker
    @State private var killing: SessionInfo?
    @State private var removing: SessionInfo?
    @State private var banner: String?
    @State private var showAllDone = false
    /// Version label next to the wordmark (#67); tap to hide, Settings → Show version brings it back.
    @AppStorage("showVersionLabel") private var showVersion = true

    private static let doneShown = 4

    var body: some View {
        let board = store.board
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let problem = store.connectionProblem {
                        ConnectionProblemCard(problem: problem)
                            .transition(.opacity)
                    }
                    if let banner = banner {
                        InlineBanner(text: banner) { self.banner = nil }
                    }
                    if updates.showsBanner {
                        UpdateNotice {
                            withAnimation { updates.dismissBanner() }
                        }
                        .transition(.opacity)
                    }
                    if !store.hasSnapshot && store.connectionProblem == nil {
                        SkeletonRows(count: 3)
                    } else if store.hasSnapshot {
                        summary(board)
                        boardSections(board)
                        continueSection
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .animation(.easeInOut(duration: 0.25), value: BoardColumn.allCases.map { (board[$0] ?? []).map(\.id) })
            }
            .refreshable {
                await store.refresh()
            }
            bottomBar
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle("Home")
        .confirmationDialog("Kill this session?",
                            isPresented: Binding(get: { killing != nil }, set: { if !$0 { killing = nil } }),
                            titleVisibility: .visible,
                            presenting: killing) { s in
            Button("Kill \(s.displayTitle)", role: .destructive) {
                act { await store.kill(s.id) }
            }
        } message: { _ in
            Text("The process on your PC is ended. You can restart or resume it later.")
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
        HStack(spacing: 4) {
            Button {
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.15)) { showVersion.toggle() }
            } label: {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    AigoWordmark(size: 17)
                    if showVersion {
                        Text("v\(UpdateChecker.currentVersion)")
                            .font(.aigo(size: 11))
                            .foregroundStyle(Theme.faint)
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Aigo version \(UpdateChecker.currentVersion)"))
            .accessibilityHint(Text(showVersion ? "Hides the version" : "Shows the version"))
            .padding(.trailing, 6)
            HostSwitcher()
                .layoutPriority(1)
            Spacer(minLength: 4)
            QuietIconButton(symbol: "magnifyingglass", label: "Search") {
                store.showSearch = true
            }
            if store.hasWorkspace {
                QuietIconButton(symbol: "sidebar.left", label: "Sessions") {
                    store.path.append(.sessions)
                }
            }
            QuietIconButton(symbol: "gearshape", label: "Settings") {
                store.path.append(.settings)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Theme.bg)
    }

    // MARK: - Board

    /// One quiet line: only the non-zero parts ("2 need you · 3 working").
    @ViewBuilder
    private func summary(_ board: [BoardColumn: [BoardCard]]) -> some View {
        let ask = board[.ask]?.count ?? 0
        let work = board[.work]?.count ?? 0
        let review = board[.review]?.count ?? 0
        let parts = [ask > 0 ? "\(ask) need\(ask == 1 ? "s" : "") you" : nil,
                     work > 0 ? "\(work) working" : nil,
                     review > 0 ? "\(review) to review" : nil].compactMap { $0 }
        Text(parts.isEmpty ? "All quiet on \(store.hostLabel)." : parts.joined(separator: " · "))
            .font(.aigo(.title3, .semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(2)
            .contentTransition(.opacity)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
        if parts.isEmpty && store.sessions.isEmpty {
            Text("Start a chat with an agent in one of your projects. What it needs from you shows up here.")
                .font(.aigo(.footnote))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func boardSections(_ board: [BoardColumn: [BoardCard]]) -> some View {
        ForEach(BoardColumn.allCases) { col in
            let cards = board[col] ?? []
            if !cards.isEmpty {
                sectionHeader(col.label, count: cards.count, color: col.color)
                if col == .done {
                    let shown = showAllDone ? cards : Array(cards.prefix(HomeView.doneShown))
                    VStack(spacing: 0) {
                        ForEach(shown) { card in
                            doneRow(card)
                        }
                    }
                    .aigoCard()
                    if cards.count > HomeView.doneShown {
                        Button(showAllDone ? "Show less" : "Show all \(cards.count)") {
                            withAnimation(.easeInOut(duration: 0.2)) { showAllDone.toggle() }
                        }
                        .font(.aigo(.footnote))
                        .foregroundStyle(Theme.muted)
                        .buttonStyle(.plain)
                        .frame(minHeight: 32)
                    }
                } else {
                    ForEach(cards) { card in
                        cardView(card)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.aigo(.footnote, .medium))
                .foregroundStyle(Theme.text2)
            Text("\(count)")
                .font(.aigo(.footnote))
                .foregroundStyle(Theme.faint)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func cardView(_ card: BoardCard) -> some View {
        if let item = card.item {
            AttentionCard(item: item, session: card.session)
                .contextMenu { if let s = card.session { contextButtons(s, column: card.column) } }
        } else if let s = card.session {
            SessionCard(session: s, column: card.column, onError: { banner = $0 })
                .contextMenu { contextButtons(s, column: card.column) }
        } else if let e = card.external {
            ExternalCard(session: e, column: card.column)
        }
    }

    /// Done today: one line per session.
    @ViewBuilder
    private func doneRow(_ card: BoardCard) -> some View {
        if let s = card.session {
            Button {
                store.openSession(s.id)
            } label: {
                HStack(spacing: 10) {
                    StatusDot(status: s.status, size: 6)
                    Text(s.displayTitle)
                        .font(.aigo(.callout))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Age.short(card.date))
                        .font(.aigo(.caption))
                        .foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietPressStyle())
            .contextMenu { contextButtons(s, column: .done) }
        }
    }

    @ViewBuilder
    private func contextButtons(_ s: SessionInfo, column: BoardColumn) -> some View {
        Button {
            store.openSession(s.id)
        } label: {
            Label("Open", systemImage: "arrow.up.right")
        }
        if column == .review {
            Button {
                act { await store.markSeen(s.id) }
            } label: {
                Label("Mark reviewed", systemImage: "checkmark")
            }
        }
        if s.isRunning {
            Button {
                act { await store.stop(s.id) }
            } label: {
                Label("Stop", systemImage: "stop")
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

    // MARK: - Continue

    @ViewBuilder
    private var continueSection: some View {
        let recent = store.recentSessions()
        if !recent.isEmpty {
            HStack {
                Text("Continue")
                    .font(.aigo(.footnote, .medium))
                    .foregroundStyle(Theme.text2)
                Spacer(minLength: 0)
                Button(store.hasWorkspace ? "All sessions" : "Search") { openContinue() }
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.muted)
                    .buttonStyle(.plain)
                    .frame(minHeight: 32)
            }
            .padding(.top, 12)
            .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(recent) { s in
                    Button {
                        store.openSession(s.id)
                    } label: {
                        HStack(spacing: 10) {
                            StatusDot(status: s.status, size: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.displayTitle)
                                    .font(.aigo(.callout))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Text(s.subtitle)
                                    .font(.aigo(.caption))
                                    .foregroundStyle(Theme.faint)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 6)
                            Text(Age.short(s.activityDate))
                                .font(.aigo(.caption))
                                .foregroundStyle(Theme.faint)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(QuietPressStyle())
                    .contextMenu { contextButtons(s, column: store.column(of: s) ?? .done) }
                }
            }
            .aigoCard()
        }
    }

    private func openContinue() {
        Haptics.tap()
        if store.hasWorkspace {
            store.path.append(.sessions)
        } else {
            store.showSearch = true
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                Haptics.tap()
                store.openNewWork()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(PrimaryButtonStyle(minHeight: 44))
            .disabled(store.client == nil)
            .accessibilityLabel(Text("Start a new chat"))
            Button {
                openContinue()
            } label: {
                Label("Continue", systemImage: "arrow.uturn.forward")
            }
            .buttonStyle(SecondaryButtonStyle(minHeight: 44))
            .disabled(store.client == nil)
            .accessibilityLabel(Text("Continue a session"))
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.bg.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
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
