import SwiftUI
import UIKit

/// One row of the Sessions list: a /search item and the id the workspace
/// knows it by (the conversation key when it has one).
struct SessionsRow: Identifiable, Equatable {
    let wsId: String
    let item: SearchItem
    var id: String { wsId }
}

struct SessionsGroup: Identifiable {
    let id: String
    let name: String
    let rows: [SessionsRow]
    /// The workspace section, for user-made groups.
    var sectionId: String? = nil
}

/// Sessions (host API §7l, PhoneSessions mockup): Pinned cards, the user's
/// sections, one group per project folder with two or more sessions, then
/// Recent. Long-press a session to pin, rename, move to a section, close or
/// remove it. The organisation is shared with the desktop through the
/// host's workspace; which groups are collapsed stays on this device.
struct SessionsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [SearchItem] = []
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var banner: String?
    @State private var recentShown = 25
    @State private var opening: String?
    @AppStorage("sessionsCollapsed") private var collapsedRaw = ""

    @State private var renaming: SessionsRow?
    @State private var renameText = ""
    @State private var newSectionFor: SessionsRow?
    @State private var newSectionName = ""
    @State private var closing: SessionsRow?

    private static let pageSize = 200

    var body: some View {
        let built = build()
        VStack(spacing: 0) {
            header(pinned: built.pinned)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let banner {
                        InlineBanner(text: banner) { self.banner = nil }
                    }
                    if !loadedOnce && items.isEmpty {
                        SkeletonRows(count: 4)
                    } else if built.pinned.isEmpty && built.groups.allSatisfy({ $0.rows.isEmpty && $0.sectionId == nil }) {
                        Text("No sessions yet.")
                            .font(.aigo(.footnote))
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(built.groups) { group in
                        groupView(group)
                    }
                    if nextOffset != nil {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            HStack(spacing: 8) {
                                if loading { ProgressView().controlSize(.small).tint(Theme.secondary) }
                                Text("Load older sessions")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(loading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .refreshable { await reload() }
            Text("Long-press a session: pin · move to section · rename · close")
                .font(.aigo(.caption2))
                .foregroundStyle(Theme.idle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Sessions")
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if !loadedOnce { await reload() }
        }
        .onChange(of: store.clientGeneration) { _, _ in
            Task { await reload() }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { row in
            TextField("Name", text: $renameText)
            Button("Save") {
                let name = String(renameText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                ops([["op": "rename", "id": row.wsId, "name": name]])
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Shown on every device. Leave it empty for the session's own title.")
        }
        .alert("New section", isPresented: Binding(get: { newSectionFor != nil }, set: { if !$0 { newSectionFor = nil } }),
               presenting: newSectionFor) { row in
            TextField("Section name", text: $newSectionName)
            Button("Create") {
                let name = String(newSectionName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                guard !name.isEmpty else { return }
                let sid = SessionsView.newSectionId()
                ops([["op": "section.add", "section": sid, "name": name],
                     ["op": "move", "id": row.wsId, "section": sid]])
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The session moves into it.")
        }
        .confirmationDialog("Close this session?",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible, presenting: closing) { row in
            Button("Close \(title(row))", role: .destructive) {
                if let sid = liveSessionId(row.item) {
                    Task {
                        if let err = await store.kill(sid) { banner = err }
                    }
                }
            }
        } message: { _ in
            Text("The process on your PC is stopped. You can continue the conversation later.")
        }
    }

    // MARK: - Header

    private func header(pinned: [SessionsRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 40, height: 40)
                        .background(Theme.softWhite, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Back to the board"))
                Text("Sessions")
                    .font(.aigo(.title3))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Button {
                    store.showSearch = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .font(.aigo(.footnote))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 40)
                        .background(Theme.softWhite, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if !pinned.isEmpty {
                groupHeader(id: "pinned", name: "PINNED", count: pinned.count)
                if !isCollapsed("pinned") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pinned) { row in
                                pinnedCard(row)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func pinnedCard(_ row: SessionsRow) -> some View {
        Button {
            open(row)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    dot(row.item)
                    Text(title(row))
                        .font(.aigo(.footnote))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if opening == row.id {
                        ProgressView().controlSize(.mini).tint(Theme.lime)
                    }
                }
                Text(shortMeta(row.item))
                    .font(.aigo(.caption2))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(width: 140, alignment: .leading)
            .aigoCard(border: Color(aigoHex: 0x2A2D31), fill: Theme.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu(row, pinned: true, section: nil) }
    }

    // MARK: - Groups

    private func groupHeader(id: String, name: String, count: Int) -> some View {
        Button {
            Haptics.selection()
            toggle(id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed(id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                Text(name)
                    .font(.aigo(.caption))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(count)")
                    .font(.aigo(.caption))
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 4)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(name), \(count) sessions, \(isCollapsed(id) ? "collapsed" : "expanded")"))
    }

    @ViewBuilder
    private func groupView(_ group: SessionsGroup) -> some View {
        let isRecent = group.id == "recent"
        let rows = isRecent ? Array(group.rows.prefix(recentShown)) : group.rows
        VStack(alignment: .leading, spacing: 4) {
            groupHeader(id: group.id, name: group.name, count: group.rows.count)
                .contextMenu {
                    if let sid = group.sectionId {
                        Button(role: .destructive) {
                            ops([["op": "section.remove", "section": sid]])
                        } label: {
                            Label("Remove section", systemImage: "folder.badge.minus")
                        }
                    }
                }
            if !isCollapsed(group.id) {
                if group.rows.isEmpty && group.sectionId != nil {
                    Text("Empty. Long-press a session to move it here.")
                        .font(.aigo(.caption2))
                        .foregroundStyle(Theme.idle)
                        .padding(.horizontal, 10)
                }
                ForEach(rows) { row in
                    rowView(row, section: group.sectionId)
                }
                if isRecent && group.rows.count > recentShown {
                    Button("+\(group.rows.count - recentShown) more") {
                        recentShown += 50
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func rowView(_ row: SessionsRow, section: String?) -> some View {
        let pinned = isPinned(row)
        return HStack(spacing: 8) {
            dot(row.item)
            Button {
                open(row)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(row))
                        .font(.aigo(.callout))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(meta(row.item))
                        .font(.aigo(.caption2))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if opening == row.id {
                ProgressView().controlSize(.small).tint(Theme.lime)
            }
            Button {
                ops([["op": pinned ? "unpin" : "pin", "id": row.wsId]])
            } label: {
                Image(systemName: pinned ? "star.fill" : "star")
                    .font(.system(size: 16))
                    .foregroundStyle(pinned ? Theme.lime : Color(aigoHex: 0x4A4F55))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(pinned ? "Unpin" : "Pin"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .aigoCard(border: Color(aigoHex: 0x23262A), fill: Theme.surface)
        .contextMenu { menu(row, pinned: pinned, section: section) }
    }

    @ViewBuilder
    private func menu(_ row: SessionsRow, pinned: Bool, section: String?) -> some View {
        Button {
            open(row)
        } label: {
            Label("Open", systemImage: "arrow.up.forward.square")
        }
        Button {
            ops([["op": pinned ? "unpin" : "pin", "id": row.wsId]])
        } label: {
            Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "star.slash" : "star")
        }
        Button {
            renameText = names[row.wsId] ?? names[row.item.workspaceKey] ?? ""
            renaming = row
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Menu {
            let current = section ?? sectionOf(row)
            ForEach(store.workspace?.sections ?? []) { sec in
                Button {
                    ops([["op": "move", "id": row.wsId, "section": sec.id]])
                } label: {
                    if sec.id == current {
                        Label(sec.title, systemImage: "checkmark")
                    } else {
                        Text(sec.title)
                    }
                }
            }
            Button {
                newSectionName = ""
                newSectionFor = row
            } label: {
                Label("New section…", systemImage: "folder.badge.plus")
            }
            if current != nil {
                Button {
                    ops([["op": "move", "id": row.wsId, "section": ""]])
                } label: {
                    Label("Out of the section", systemImage: "arrow.uturn.left")
                }
            }
        } label: {
            Label("Move to section", systemImage: "folder")
        }
        if liveSessionId(row.item) != nil {
            Button(role: .destructive) {
                closing = row
            } label: {
                Label("Close…", systemImage: "xmark.octagon")
            }
        }
        Button(role: .destructive) {
            ops([["op": "hide", "id": row.wsId]])
        } label: {
            Label("Remove from list", systemImage: "eye.slash")
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func dot(_ item: SearchItem) -> some View {
        if let sid = liveSessionId(item), let s = store.session(id: sid) {
            StatusDot(status: s.status, size: 8)
        } else if let col = BoardColumn(rawValue: item.board ?? ""), col != .done {
            Circle().fill(col.color).frame(width: 8, height: 8)
        } else {
            Circle().strokeBorder(Theme.idle, lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }

    private var names: [String: String] { store.workspace?.names ?? [:] }

    private func title(_ row: SessionsRow) -> String {
        for k in [row.wsId, row.item.workspaceKey, row.item.id] {
            if let n = names[k], !n.isEmpty { return n }
        }
        if let t = row.item.title, !t.isEmpty { return t }
        if let p = row.item.lastPrompt, !p.isEmpty { return p }
        return AgentNames.display(row.item.harness ?? row.item.agent)
    }

    private func harness(_ item: SearchItem) -> String {
        item.harness.map { AgentNames.display($0) } ?? store.agentName(item.agent)
    }

    private func shortMeta(_ item: SearchItem) -> String {
        let age = Age.short(AigoDate.parse(item.lastActivity))
        return age.isEmpty ? harness(item) : "\(harness(item)) · \(age)"
    }

    private func meta(_ item: SearchItem) -> String {
        var parts = [harness(item)]
        let place = (item.project ?? "").isEmpty ? folderName(item.cwd) : item.project!
        if !place.isEmpty { parts.append(place) }
        if store.hosts.count > 1 { parts.append(store.hostLabel) }
        if let live = store.liveLabel(item.live), item.live?.`where` == "outside" { parts.append(live) }
        let age = Age.short(AigoDate.parse(item.lastActivity))
        if !age.isEmpty { parts.append(age) }
        return parts.joined(separator: " · ")
    }

    /// The running Aigo session behind a row, if any.
    private func liveSessionId(_ item: SearchItem) -> String? {
        if (item.kind ?? "session") == "session", let s = store.session(id: item.id), s.isRunning { return s.id }
        if item.live?.`where` == "aigo", let sid = item.live?.sessionId, !sid.isEmpty,
           store.session(id: sid)?.isRunning ?? false {
            return sid
        }
        return nil
    }

    private func isPinned(_ row: SessionsRow) -> Bool {
        let pinned = Set(store.workspace?.pinned ?? [])
        return pinned.contains(row.wsId) || pinned.contains(row.item.workspaceKey) || pinned.contains(row.item.id)
    }

    private func sectionOf(_ row: SessionsRow) -> String? {
        for sec in store.workspace?.sections ?? [] {
            let ids = Set(sec.items ?? [])
            if ids.contains(row.wsId) || ids.contains(row.item.workspaceKey) || ids.contains(row.item.id) {
                return sec.id
            }
        }
        return nil
    }

    // MARK: - Collapsed groups (per device)

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: "\n").map(String.init))
    }

    private func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

    private func toggle(_ id: String) {
        var c = collapsed
        if c.contains(id) { c.remove(id) } else { c.insert(id) }
        withAnimation(.easeInOut(duration: 0.15)) {
            collapsedRaw = c.sorted().joined(separator: "\n")
        }
    }

    // MARK: - Grouping

    private func build() -> (pinned: [SessionsRow], groups: [SessionsGroup]) {
        let doc = store.workspace ?? WorkspaceDoc()
        var byKey: [String: SearchItem] = [:]
        for it in items where it.helper != true {
            if byKey[it.id] == nil { byKey[it.id] = it }
            if byKey[it.workspaceKey] == nil { byKey[it.workspaceKey] = it }
        }
        func lookup(_ id: String) -> SearchItem? { store.workspaceItems[id] ?? byKey[id] }

        var used = Set<String>()
        func mark(_ id: String, _ it: SearchItem) {
            used.insert(id)
            used.insert(it.id)
            used.insert(it.workspaceKey)
        }

        let pinnedIds = doc.pinned ?? []
        let pinnedSet = Set(pinnedIds)
        var pinned: [SessionsRow] = []
        for id in pinnedIds {
            guard let it = lookup(id) else { continue }
            mark(id, it)
            pinned.append(SessionsRow(wsId: id, item: it))
        }

        var groups: [SessionsGroup] = []
        for sec in doc.sections ?? [] {
            var rows: [SessionsRow] = []
            for id in sec.items ?? [] {
                guard let it = lookup(id) else { continue }
                mark(id, it)
                // Pinned wins; unpinned, it shows in its section again.
                if pinnedSet.contains(id) || pinnedSet.contains(it.workspaceKey) || pinnedSet.contains(it.id) { continue }
                rows.append(SessionsRow(wsId: id, item: it))
            }
            groups.append(SessionsGroup(id: "s:\(sec.id)", name: sec.title, rows: rows, sectionId: sec.id))
        }

        let hidden = doc.hidden ?? [:]
        func isHidden(_ it: SearchItem) -> Bool {
            for k in [it.id, it.workspaceKey] {
                guard let raw = hidden[k] else { continue }
                // Shown again only when used after it was removed.
                if let h = AigoDate.parse(raw), let last = AigoDate.parse(it.lastActivity), last > h { continue }
                return true
            }
            return false
        }

        var seen = Set<String>()
        let rest = items.filter { it in
            it.helper != true && !used.contains(it.id) && !used.contains(it.workspaceKey) && !isHidden(it)
                && seen.insert(it.workspaceKey).inserted
        }
        let recency: (SearchItem) -> Date = { AigoDate.parse($0.lastActivity) ?? .distantPast }
        let byCwd = Dictionary(grouping: rest) { ($0.cwd ?? "").lowercased() }
        var projects: [(Date, SessionsGroup)] = []
        var recent: [SearchItem] = []
        for (cwd, list) in byCwd {
            if !cwd.isEmpty && list.count >= 2 {
                let sorted = list.sorted { recency($0) > recency($1) }
                let first = sorted[0]
                let name = (first.project ?? "").isEmpty ? folderName(first.cwd) : first.project!
                projects.append((recency(first),
                                 SessionsGroup(id: "p:\(cwd)", name: name,
                                               rows: sorted.map { SessionsRow(wsId: $0.workspaceKey, item: $0) })))
            } else {
                recent.append(contentsOf: list)
            }
        }
        groups.append(contentsOf: projects.sorted { $0.0 > $1.0 }.map { $0.1 })
        let recentRows = recent.sorted { recency($0) > recency($1) }.map { SessionsRow(wsId: $0.workspaceKey, item: $0) }
        groups.append(SessionsGroup(id: "recent", name: "Recent", rows: recentRows))
        return (pinned, groups)
    }

    // MARK: - Loading

    private func reload() async {
        guard let c = store.client else { return }
        loading = true
        await store.loadWorkspace()
        do {
            let page = try await c.searchPage("", limit: SessionsView.pageSize, offset: 0)
            items = page.items ?? []
            nextOffset = page.nextOffset
        } catch {
            banner = c.problem(for: error).message
        }
        loadedOnce = true
        loading = false
    }

    private func loadMore() async {
        guard let c = store.client, let offset = nextOffset, !loading else { return }
        loading = true
        do {
            let page = try await c.searchPage("", limit: SessionsView.pageSize, offset: offset)
            let known = Set(items.map { $0.id })
            items.append(contentsOf: (page.items ?? []).filter { !known.contains($0.id) })
            nextOffset = page.nextOffset
        } catch {
            banner = c.problem(for: error).message
        }
        loading = false
    }

    // MARK: - Actions

    private func ops(_ list: [[String: Any]]) {
        Task {
            if let err = await store.workspaceOps(list) {
                Haptics.error()
                withAnimation { banner = err }
            }
        }
    }

    /// Running Aigo session → open it; otherwise Continue (§7j). Running in
    /// another window → the read-only view with the Continue choices.
    private func open(_ row: SessionsRow) {
        let item = row.item
        if let sid = liveSessionId(item) {
            store.openSession(sid)
            return
        }
        guard store.canContinue, item.resumable == true else {
            store.open(item)
            return
        }
        guard opening == nil else { return }
        opening = row.id
        Task {
            let outcome = await store.continueSession(item.id)
            opening = nil
            switch outcome {
            case .opened:
                break
            case .runningElsewhere(let busy):
                store.rememberConflict(item.id, busy)
                store.openReadOnly(item)
            case .failed(let msg):
                Haptics.error()
                withAnimation { banner = msg }
            }
        }
    }

    static func newSectionId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "s-" + String((0..<10).map { _ in chars.randomElement()! })
    }
}
