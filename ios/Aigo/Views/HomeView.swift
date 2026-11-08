import SwiftUI
import UIKit

/// Home = the board as four tabs with counts: Needs you / Working / Review /
/// Done. Needs-you cards are answered inline; Review cards have "Looks good";
/// every card opens its conversation. "New work" sits at the bottom.
struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var updates: UpdateChecker
    @State private var tab: BoardColumn = .ask
    @State private var pickedInitialTab = false
    @State private var killing: SessionInfo?
    @State private var removing: SessionInfo?
    @State private var banner: String?

    var body: some View {
        let board = store.board
        let cards = board[tab] ?? []
        VStack(spacing: 0) {
            header(board)
            ScrollView {
                LazyVStack(spacing: 10) {
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
                    } else if store.sessions.isEmpty && store.pendingItems.isEmpty && tab != .done {
                        emptyState
                    } else if cards.isEmpty {
                        Text(tab.emptyText)
                            .font(.aigo(.callout))
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        ForEach(cards) { card in
                            cardView(card)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .animation(.easeInOut(duration: 0.25), value: cards.map { $0.id })
            }
            .refreshable {
                await store.refresh()
            }
            newWorkButton
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle("Board")
        .onAppear { pickInitialTab(board) }
        .onChange(of: store.hasSnapshot) { _, _ in pickInitialTab(store.board) }
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

    /// Opens on Needs you when something waits, else on the busiest column.
    private func pickInitialTab(_ board: [BoardColumn: [BoardCard]]) {
        guard !pickedInitialTab, store.hasSnapshot else { return }
        pickedInitialTab = true
        tab = BoardColumn.allCases.first { !(board[$0] ?? []).isEmpty } ?? .ask
    }

    // MARK: - Header

    private func header(_ board: [BoardColumn: [BoardCard]]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AigoWordmark(size: 17)
                Spacer(minLength: 8)
                HostSwitcher()
                    .layoutPriority(1)
                iconButton("magnifyingglass", label: "Search") {
                    store.showSearch = true
                }
                iconButton("gearshape", label: "Settings") {
                    store.path.append(.settings)
                }
            }
            Text(headline(board))
                .font(.aigo(.title, .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.isHeader)
            tabs(board)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Theme.bg)
    }

    private func headline(_ board: [BoardColumn: [BoardCard]]) -> String {
        if store.activeHost == nil { return "Pair your PC to get started." }
        if !store.hasSnapshot {
            return store.connectionProblem != nil ? "Can't reach \(store.hostLabel)" : "Connecting to \(store.hostLabel)…"
        }
        let ask = board[.ask]?.count ?? 0
        let work = board[.work]?.count ?? 0
        return (ask > 0 ? "\(ask) need you" : "All clear") + " · \(work) working"
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 36, height: 36)
                .background(Theme.softWhite, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func tabs(_ board: [BoardColumn: [BoardCard]]) -> some View {
        HStack(spacing: 6) {
            ForEach(BoardColumn.allCases) { col in
                let count = board[col]?.count ?? 0
                let on = col == tab
                let alert = col == .ask && count > 0
                Button {
                    Haptics.selection()
                    withAnimation(.easeInOut(duration: 0.15)) { tab = col }
                } label: {
                    VStack(spacing: 2) {
                        Text("\(count)")
                            .font(.aigo(size: 15, .semibold))
                            .foregroundStyle(alert ? Theme.coral : (on ? Theme.bg : Theme.text))
                            .contentTransition(.numericText())
                        Text(col.label)
                            .font(.aigo(size: 11))
                            .foregroundStyle(on ? Theme.bg : Theme.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(on ? Theme.text : Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(on ? Color.clear : (alert ? Color(aigoHex: 0x5A3A30) : Theme.line), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(col.label), \(count)"))
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func cardView(_ card: BoardCard) -> some View {
        if let item = card.item {
            AttentionCard(item: item, session: card.session)
                .contextMenu { if let s = card.session { contextButtons(s) } }
        } else if let s = card.session {
            SessionCard(session: s, column: card.column, onError: { banner = $0 })
                .contextMenu { contextButtons(s) }
        } else if let e = card.external {
            ExternalCard(session: e, column: card.column)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(Theme.lime).frame(width: 8, height: 8)
                Text("Ready when you are")
                    .font(.aigo(.caption, .semibold))
                    .foregroundStyle(Theme.lime)
            }
            Text("Nothing is running on \(store.hostLabel).")
                .font(.aigo(.title3, .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Start an agent in one of your projects. Its progress shows up here, and anything it needs from you lands in Needs you.")
                .font(.aigo(.footnote))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Haptics.tap()
                store.openNewWork(agent: NewWorkView.terminalChoice)
            } label: {
                Label("Open a terminal", systemImage: "terminal")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(store.client == nil)
        }
        .padding(12)
        .aigoCard()
    }

    private var newWorkButton: some View {
        Button {
            Haptics.tap()
            store.openNewWork()
        } label: {
            Text("New work")
        }
        .buttonStyle(SoftButtonStyle(tint: Theme.lime, minHeight: 46))
        .disabled(store.client == nil)
        .accessibilityLabel(Text("Start new work"))
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.bg.ignoresSafeArea(edges: .bottom))
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
