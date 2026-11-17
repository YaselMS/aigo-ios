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

/// Sessions (host API §7l, round 3): organisation only. Pinned, the user's
/// sections, one group per project folder with two or more sessions, then
/// Recent. One-line rows with a status dot; a chevron opens the session's
/// own sub-agents and tasks (`children`). Long-press a session to pin,
/// rename, move, mark reviewed, stop, close, kill or remove it; Select picks
/// several for Stop / Kill / Mark reviewed / Move. The organisation is shared
/// with the desktop; collapsed groups stay on this device.
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
    /// Rows showing their sub-agents and tasks.
    @State private var expanded: Set<String> = []

    @State private var selecting = false
    @State private var selected: Set<String> = []

    @State private var renaming: SessionsRow?
    @State private var renameText = ""
    /// Workspace ids to move into the new section (empty: just create it).
    @State private var newSectionMove: [String]?
    @State private var newSectionName = ""
    @State private var renamingSection: WorkspaceSection?
    @State private var sectionNameText = ""
    @State private var closing: SessionsRow?
    /// Aigo session ids waiting for the Kill confirmation.
    @State private var killing: [String]?

    private static let pageSize = 200

    var body: some View {
        let built = build()
        let byId = SessionsView.index(built)
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let banner {
                        InlineBanner(text: banner) { self.banner = nil }
                            .padding(.bottom, 8)
                    }
                    if !loadedOnce && items.isEmpty {
                        SkeletonRows(count: 4)
                    } else if built.pinned.isEmpty && built.groups.allSatisfy({ $0.rows.isEmpty && $0.sectionId == nil }) {
                        Text("No sessions yet.")
                            .font(.aigo(.footnote))
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    if !built.pinned.isEmpty {
                        groupView(SessionsGroup(id: "pinned", name: "Pinned", rows: built.pinned))
                    }
                    ForEach(built.groups) { group in
                        groupView(group)
                    }
                    if nextOffset != nil {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            HStack(spacing: 8) {
                                if loading { ProgressView().controlSize(.small).tint(Theme.muted) }
                                Text("Load older sessions")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(loading)
                        .padding(.top, 12)
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .refreshable { await reload() }
            if selecting {
                selectionBar(byId)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Sessions")
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeInOut(duration: 0.2), value: selecting)
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
        .alert("New section", isPresented: Binding(get: { newSectionMove != nil }, set: { if !$0 { newSectionMove = nil } }),
               presenting: newSectionMove) { move in
            TextField("Section name", text: $newSectionName)
            Button("Create") {
                let name = String(newSectionName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                guard !name.isEmpty else { return }
                let sid = SessionsView.newSectionId()
                var list: [[String: Any]] = [["op": "section.add", "section": sid, "name": name]]
                list += move.map { ["op": "move", "id": $0, "section": sid] }
                ops(list)
                endSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: { move in
            Text(move.isEmpty ? "Shown on every device." : (move.count == 1 ? "The session moves into it." : "The \(move.count) sessions move into it."))
        }
        .alert("Rename section", isPresented: Binding(get: { renamingSection != nil }, set: { if !$0 { renamingSection = nil } }),
               presenting: renamingSection) { sec in
            TextField("Section name", text: $sectionNameText)
            Button("Save") {
                let name = String(sectionNameText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                guard !name.isEmpty else { return }
                ops([["op": "section.rename", "section": sec.id, "name": name]])
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Close this session?",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible, presenting: closing) { row in
            Button("Close \(title(row))", role: .destructive) {
                if let sid = liveSessionId(row.item) {
                    act { await store.close(sid) }
                }
            }
        } message: { _ in
            Text("The agent is asked to stop, then its process on your PC ends. You can continue the conversation later.")
        }
        .confirmationDialog(killTitle,
                            isPresented: Binding(get: { killing != nil }, set: { if !$0 { killing = nil } }),
                            titleVisibility: .visible, presenting: killing) { ids in
            Button(ids.count == 1 ? "Kill" : "Kill \(ids.count) sessions", role: .destructive) {
                Haptics.warning()
                act { await store.killAll(ids) }
                endSelection()
            }
        } message: { _ in
            Text("The processes end at once, with everything they started. You can continue the conversations later.")
        }
    }

    private var killTitle: String {
        let n = killing?.count ?? 0
        return n == 1 ? "Kill this session?" : "Kill \(n) sessions?"
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 2) {
            QuietIconButton(symbol: "chevron.left", label: "Back to Home", tint: Theme.text2) {
                dismiss()
            }
            Text(selecting ? (selected.isEmpty ? "Select sessions" : "\(selected.count) selected") : "Sessions")
                .font(.aigo(.headline))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if !selecting {
                QuietIconButton(symbol: "magnifyingglass", label: "Search") {
                    store.showSearch = true
                }
                QuietIconButton(symbol: "folder.badge.plus", label: "New section") {
                    newSectionName = ""
                    newSectionMove = []
                }
            }
            Button(selecting ? "Done" : "Select") {
                Haptics.selection()
                if selecting { endSelection() } else { selecting = true }
            }
            .font(.aigo(.callout, .medium))
            .foregroundStyle(Theme.accentText)
            .buttonStyle(QuietPressStyle())
            .frame(minWidth: 56, minHeight: 40)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    // MARK: - Groups

    private func groupHeader(_ group: SessionsGroup) -> some View {
        let isOff = isCollapsed(group.id)
        return Button {
            Haptics.selection()
            toggle(group.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: Theme.iconWeight))
                    .rotationEffect(.degrees(isOff ? 0 : 90))
                    .frame(width: 14)
                if group.id == "pinned" {
                    Image(systemName: "pin")
                        .font(.system(size: 11, weight: Theme.iconWeight))
                } else if group.sectionId == nil && group.id != "recent" {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: Theme.iconWeight))
                }
                Text(group.name)
                    .font(.aigo(.footnote, .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isOff && !group.rows.isEmpty {
                    Text("\(group.rows.count)")
                        .font(.aigo(.caption))
                        .foregroundStyle(Theme.faint)
                }
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 6)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(group.name), \(group.rows.count) sessions, \(isOff ? "collapsed" : "expanded")"))
    }

    @ViewBuilder
    private func groupView(_ group: SessionsGroup) -> some View {
        let isRecent = group.id == "recent"
        let rows = isRecent ? Array(group.rows.prefix(recentShown)) : group.rows
        VStack(alignment: .leading, spacing: 0) {
            groupHeader(group)
                .contextMenu { groupMenu(group) }
            if !isCollapsed(group.id) {
                if group.rows.isEmpty && group.sectionId != nil {
                    Text("Empty. Long-press a session to move it here.")
                        .font(.aigo(.caption))
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, 26)
                        .padding(.bottom, 6)
                }
                ForEach(rows) { row in
                    rowView(row, section: group.sectionId)
                }
                if isRecent && group.rows.count > recentShown {
                    Button("+\(group.rows.count - recentShown) more") {
                        recentShown += 50
                    }
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.muted)
                    .buttonStyle(.plain)
                    .padding(.leading, 26)
                    .frame(minHeight: 36)
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func groupMenu(_ group: SessionsGroup) -> some View {
        let live = group.rows.compactMap { liveSessionId($0.item) }
        if !group.rows.isEmpty {
            Button {
                selecting = true
                selected.formUnion(group.rows.map { $0.wsId })
            } label: {
                Label("Select all here", systemImage: "checkmark.circle")
            }
        }
        if !live.isEmpty {
            Button {
                act { await store.stopAll(live) }
            } label: {
                Label(group.sectionId != nil ? "Stop everything in this section" : "Stop everything here",
                      systemImage: "stop")
            }
        }
        if let sid = group.sectionId, let sec = store.workspace?.sections?.first(where: { $0.id == sid }) {
            Button {
                sectionNameText = sec.title
                renamingSection = sec
            } label: {
                Label("Rename section…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                ops([["op": "section.remove", "section": sid]])
            } label: {
                Label("Remove section", systemImage: "folder.badge.minus")
            }
        }
        Button {
            newSectionName = ""
            newSectionMove = []
        } label: {
            Label("New section…", systemImage: "folder.badge.plus")
        }
    }

    // MARK: - Rows

    private func rowView(_ row: SessionsRow, section: String?) -> some View {
        let pinned = isPinned(row)
        let children = childrenOf(row)
        let isOpen = expanded.contains(row.id) && !children.isEmpty
        let isSelected = selected.contains(row.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: Theme.iconWeight))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.faint)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }
                Button {
                    Haptics.selection()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: Theme.iconWeight))
                        .foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 22, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(children.isEmpty ? 0 : 1)
                .disabled(children.isEmpty)
                .accessibilityLabel(Text(isOpen ? "Hide sub-agents and tasks" : "Show sub-agents and tasks"))
                .accessibilityHidden(children.isEmpty)
                dot(row.item)
                Text(title(row))
                    .font(.aigo(.callout))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(harness(row.item))
                    .font(.aigo(.caption))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if opening == row.id {
                    ProgressView().controlSize(.small).tint(Theme.muted)
                } else if !isOpen && !children.isEmpty {
                    let active = children.filter { $0.status == "working" || $0.status == "pending" }.count
                    if active > 0 {
                        Text("\(active)")
                            .font(.aigo(.caption))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            .padding(.trailing, 8)
            .frame(minHeight: 40)
            .background(isSelected ? Theme.sel : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                if selecting {
                    Haptics.selection()
                    if isSelected { selected.remove(row.id) } else { selected.insert(row.id) }
                } else {
                    open(row)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .contextMenu { menu(row, pinned: pinned, section: section) }
            if isOpen {
                ForEach(children) { child in
                    childRow(child, parent: row)
                }
                .transition(.opacity)
            }
        }
    }

    private func childRow(_ child: SessionChild, parent: SessionsRow) -> some View {
        Button {
            if !selecting { open(parent) }
        } label: {
            HStack(spacing: 8) {
                ChildGlyph(status: child.status)
                Text(child.displayTitle)
                    .font(.aigo(.footnote))
                    .foregroundStyle(child.status == "done" ? Theme.muted : Theme.text2)
                    .lineLimit(1)
                Text(child.isSubagent ? "agent" : "task")
                    .font(.aigo(.caption2))
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 4)
            }
            .padding(.leading, selecting ? 72 : 44)
            .padding(.trailing, 8)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietPressStyle())
        .accessibilityLabel(Text("\(child.isSubagent ? "Sub-agent" : "Task"): \(child.displayTitle), \(child.status ?? "pending")"))
    }

    @ViewBuilder
    private func menu(_ row: SessionsRow, pinned: Bool, section: String?) -> some View {
        let live = liveSessionId(row.item)
        Button {
            open(row)
        } label: {
            Label("Open", systemImage: "arrow.up.right")
        }
        Button {
            ops([["op": pinned ? "unpin" : "pin", "id": row.wsId]])
        } label: {
            Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
        }
        Button {
            renameText = names[row.wsId] ?? names[row.item.workspaceKey] ?? ""
            renaming = row
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        moveMenu(ids: [row.wsId], current: section ?? sectionOf(row))
        if let sid = aigoSessionId(row.item), let s = store.session(id: sid), store.column(of: s) == .review {
            Button {
                act { await store.markSeen(sid) }
            } label: {
                Label("Mark reviewed", systemImage: "checkmark")
            }
        }
        if let live {
            Button {
                act { await store.stop(live) }
            } label: {
                Label("Stop", systemImage: "stop")
            }
            Button(role: .destructive) {
                closing = row
            } label: {
                Label("Close…", systemImage: "xmark.circle")
            }
            Button(role: .destructive) {
                killing = [live]
            } label: {
                Label("Kill…", systemImage: "xmark.octagon")
            }
        }
        Button {
            selecting = true
            selected.insert(row.wsId)
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
        Button(role: .destructive) {
            ops([["op": "hide", "id": row.wsId]])
        } label: {
            Label("Remove from list", systemImage: "eye.slash")
        }
    }

    /// Move to section ▸ (the sections, New section…, out of the section).
    @ViewBuilder
    private func moveMenu(ids: [String], current: String?) -> some View {
        Menu {
            ForEach(store.workspace?.sections ?? []) { sec in
                Button {
                    ops(ids.map { ["op": "move", "id": $0, "section": sec.id] })
                    endSelection()
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
                newSectionMove = ids
            } label: {
                Label("New section…", systemImage: "folder.badge.plus")
            }
            if current != nil || ids.count > 1 {
                Button {
                    ops(ids.map { ["op": "move", "id": $0, "section": ""] })
                    endSelection()
                } label: {
                    Label("Out of the section", systemImage: "arrow.uturn.left")
                }
            }
        } label: {
            Label("Move to section", systemImage: "folder")
        }
    }

    // MARK: - Select mode

    private func selectionBar(_ byId: [String: SessionsRow]) -> some View {
        let rows = selected.compactMap { byId[$0] }
        let live = rows.compactMap { liveSessionId($0.item) }
        let review = rows.compactMap { r -> String? in
            guard let sid = aigoSessionId(r.item), let s = store.session(id: sid), store.column(of: s) == .review else { return nil }
            return sid
        }
        return HStack(spacing: 6) {
            Button {
                act { await store.stopAll(live) }
                endSelection()
            } label: {
                Label("Stop", systemImage: "stop")
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(live.isEmpty)
            Button {
                act { await store.markSeenAll(review) }
                endSelection()
            } label: {
                Label("Reviewed", systemImage: "checkmark")
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(review.isEmpty)
            moveMenu(ids: rows.map { $0.wsId }, current: nil)
                .font(.aigo(.footnote, .medium))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .disabled(rows.isEmpty)
            Spacer(minLength: 0)
            Button {
                killing = live
            } label: {
                Label("Kill", systemImage: "xmark.octagon")
            }
            .buttonStyle(ChipButtonStyle(tint: Theme.danger))
            .disabled(live.isEmpty)
        }
        .labelStyle(.titleOnly)
        .frame(maxWidth: 760)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.panel.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private func endSelection() {
        selecting = false
        selected = []
    }

    // MARK: - Pieces

    @ViewBuilder
    private func dot(_ item: SearchItem) -> some View {
        if let sid = aigoSessionId(item), let s = store.session(id: sid), s.isRunning {
            StatusDot(status: s.status, size: 7)
        } else if let col = BoardColumn(rawValue: item.board ?? ""), col != .done {
            Circle().fill(col.color).frame(width: 7, height: 7)
        } else {
            Circle().strokeBorder(Theme.faint, lineWidth: 1.2).frame(width: 7, height: 7)
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

    /// The running Aigo session behind a row, if any.
    private func liveSessionId(_ item: SearchItem) -> String? {
        if (item.kind ?? "session") == "session", let s = store.session(id: item.id), s.isRunning { return s.id }
        if item.live?.`where` == "aigo", let sid = item.live?.sessionId, !sid.isEmpty,
           store.session(id: sid)?.isRunning ?? false {
            return sid
        }
        return nil
    }

    /// The Aigo session behind a row (running or not), if the app knows it.
    private func aigoSessionId(_ item: SearchItem) -> String? {
        if (item.kind ?? "session") == "session", store.session(id: item.id) != nil { return item.id }
        if let sid = item.live?.sessionId, !sid.isEmpty, store.session(id: sid) != nil { return sid }
        return nil
    }

    /// Sub-agents and tasks of the row's Aigo session (host API §2 `children`).
    private func childrenOf(_ row: SessionsRow) -> [SessionChild] {
        guard let sid = aigoSessionId(row.item) else { return [] }
        return store.session(id: sid)?.children ?? []
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

    static func index(_ built: (pinned: [SessionsRow], groups: [SessionsGroup])) -> [String: SessionsRow] {
        var out: [String: SessionsRow] = [:]
        for r in built.pinned { out[r.wsId] = r }
        for g in built.groups {
            for r in g.rows where out[r.wsId] == nil { out[r.wsId] = r }
        }
        return out
    }

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
        guard !list.isEmpty else { return }
        Task {
            if let err = await store.workspaceOps(list) {
                Haptics.error()
                withAnimation { banner = err }
            }
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
