import SwiftUI

struct NewWorkView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    /// Agent to preselect ("codex", "claude", … or `terminalChoice`).
    var preferredAgent: String? = nil

    static let terminalChoice = "__terminal__"

    @State private var choice = ""
    @State private var folder = ""
    @State private var recent: [RecentDir] = []
    @State private var firstMessage = ""
    @State private var askBeforeRunning = true
    @State private var busy = false
    @State private var error: String?

    private var isTerminal: Bool { choice == NewWorkView.terminalChoice }

    var body: some View {
        NavigationStack {
            Form {
                Section("Who") {
                    if store.agents.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Looking for agents on \(store.hostLabel)…")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                    ForEach(store.agents) { agent in
                        choiceRow(id: agent.id,
                                  title: agent.displayName,
                                  detail: agent.installed ? nil : "Not installed on this PC",
                                  enabled: agent.installed)
                    }
                    choiceRow(id: NewWorkView.terminalChoice, title: "Terminal", detail: "A plain shell", enabled: true)
                }
                .listRowBackground(Theme.surface)

                Section {
                    TextField("C:\\Users\\you\\project", text: $folder)
                        .font(Theme.mono)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .frame(minHeight: 44)
                    ForEach(recent.prefix(8)) { dir in
                        Button {
                            folder = dir.path
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folderName(dir.path))
                                        .foregroundStyle(Theme.text)
                                    Text(dir.path)
                                        .font(Theme.monoSmall)
                                        .foregroundStyle(Theme.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                if dir.path == folder {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.lime)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                    }
                } header: {
                    Text("Folder")
                } footer: {
                    Text("Leave empty to start in your home folder.")
                }
                .listRowBackground(Theme.surface)

                if !isTerminal {
                    Section("First message (optional)") {
                        TextField("What should it do?", text: $firstMessage, axis: .vertical)
                            .lineLimit(2...6)
                    }
                    .listRowBackground(Theme.surface)
                }

                if choice == "codex" {
                    Section {
                        Toggle("Ask before running commands", isOn: $askBeforeRunning)
                            .tint(Theme.lime)
                    } footer: {
                        Text("Codex asks for approval before commands that need it, and its sandbox stays limited to the folder. Approvals then show up on Home.")
                    }
                    .listRowBackground(Theme.surface)
                }

                if let error = error {
                    Section {
                        Text(error)
                            .foregroundStyle(Theme.coral)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("New work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Start") { start() }
                            .fontWeight(.bold)
                            .disabled(choice.isEmpty || store.client == nil)
                    }
                }
            }
            .task {
                await load()
            }
        }
    }

    private func choiceRow(id: String, title: String, detail: String?, enabled: Bool) -> some View {
        Button {
            Haptics.selection()
            choice = id
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(choice == id ? Theme.lime : Color.clear)
                    .overlay(Circle().strokeBorder(choice == id ? Theme.lime : Theme.idle, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(enabled ? Theme.text : Theme.secondary)
                    if let detail = detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                Spacer()
                if choice == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.lime)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
    }

    private func load() async {
        if store.agents.isEmpty {
            await store.loadAgents()
        }
        if choice.isEmpty, let wanted = preferredAgent {
            if wanted == NewWorkView.terminalChoice || store.agents.contains(where: { $0.id == wanted && $0.installed }) {
                choice = wanted
            }
        }
        if choice.isEmpty {
            let preferred = ["codex", "claude", "opencode", "pi"]
            let installed = store.agents.filter { $0.installed }
            if let first = preferred.first(where: { id in installed.contains { $0.id == id } }) {
                choice = first
            } else if let any = installed.first {
                choice = any.id
            } else {
                choice = NewWorkView.terminalChoice
            }
        }
        recent = await store.recentDirs()
        if folder.isEmpty, let first = recent.first {
            folder = first.path
        }
    }

    private func start() {
        error = nil
        busy = true
        let cwd = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        var request: [String: Any] = [:]
        if !cwd.isEmpty {
            request["cwd"] = cwd
        }
        if isTerminal {
            request["kind"] = "shell"
        } else {
            request["kind"] = "agent"
            request["agent"] = choice
            var launch: [String: Any] = [:]
            let prompt = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                launch["prompt"] = prompt
            }
            if choice == "codex" && askBeforeRunning {
                launch["extraArgs"] = ["--ask-for-approval", "on-request", "--sandbox", "workspace-write"]
            }
            request["launch"] = launch
        }
        Task {
            do {
                let info = try await store.createSession(request)
                busy = false
                Haptics.success()
                dismiss()
                store.path.append(.session(info.id))
            } catch {
                busy = false
                Haptics.error()
                self.error = APIError.describe(error)
            }
        }
    }
}
