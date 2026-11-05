import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showNewWork = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(store.statusSentence)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                if case .offline(let reason) = store.connection {
                    InlineBanner(text: "Can't reach \(store.hostLabel): \(reason) Retrying…")
                }

                let pending = store.pendingItems
                if !pending.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Needs you", count: pending.count)
                        ForEach(pending) { item in
                            AttentionCard(item: item)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .opacity.combined(with: .move(edge: .trailing))
                                ))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "Everyone", count: store.sessions.isEmpty ? nil : store.sessions.count)
                    if store.sessions.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 0) {
                            ForEach(store.sortedSessions) { session in
                                NavigationLink(value: AppRoute.session(session.id)) {
                                    SessionRow(session: session)
                                }
                                .buttonStyle(.plain)
                                Rectangle()
                                    .fill(Theme.line)
                                    .frame(height: 1)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.25), value: store.pendingItems.map { $0.id })
        }
        .background(Theme.bg.ignoresSafeArea())
        .refreshable {
            await store.refresh()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Wordmark()
            }
            ToolbarItem(placement: .principal) {
                HostBadge()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.settings) {
                    Image(systemName: "gearshape")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(Text("Settings"))
                Button {
                    showNewWork = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(Text("Start new work"))
                .disabled(store.client == nil)
            }
        }
        .sheet(isPresented: $showNewWork) {
            NewWorkView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No sessions on \(store.hostLabel) yet.")
                .foregroundStyle(Theme.secondary)
            Button {
                showNewWork = true
            } label: {
                Label("Start new work", systemImage: "plus")
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(store.client == nil)
        }
        .padding(.vertical, 12)
    }
}
