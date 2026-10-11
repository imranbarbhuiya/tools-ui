import AppKit
import SwiftUI

struct PortlessRoutesView: View {
    @Bindable var monitor: PortlessMonitor
    @State private var search = ""
    @State private var selected: PortlessEntry.ID?
    @State private var pendingStop: PortlessEntry?
    @State private var pendingAliasRemoval: PortlessEntry?
    @State private var confirmPrune = false

    private var rows: [PortlessEntry] {
        guard !search.isEmpty else { return monitor.entries }
        return monitor.entries.filter {
            $0.route.hostname.localizedCaseInsensitiveContains(search) ||
            $0.workingDirectory.localizedCaseInsensitiveContains(search) ||
            $0.command.localizedCaseInsensitiveContains(search) ||
            String($0.route.port).contains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Portless services")
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Text("Routes started by Portless, including other terminals and agents")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(monitor.entries.count) routes")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.bar)
            Divider()
            if let error = monitor.error {
                Text(error).foregroundStyle(.red).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            if monitor.updatedAt == nil {
                ContentUnavailableView("Reading Portless routes…", systemImage: "network")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("No Portless routes", systemImage: "checkmark.circle", description: Text(search.isEmpty ? "Start a service with portless to see it here." : "Try a different search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $selected) {
                    TableColumn("Service") { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.route.hostname).fontWeight(.semibold)
                            Text(entry.status).font(.caption).foregroundStyle(entry.status == "Orphaned" ? .orange : .secondary)
                        }
                    }.width(min: 170, ideal: 220)
                    TableColumn("URL") { entry in
                        Button(entry.url) {
                            if let url = URL(string: entry.url) { NSWorkspace.shared.open(url) }
                        }
                            .buttonStyle(.link)
                    }.width(min: 210, ideal: 270)
                    TableColumn("App port") { entry in Text(String(entry.route.port)).monospacedDigit() }.width(min: 70, ideal: 90)
                    TableColumn("Project folder") { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.folderName).fontWeight(.medium)
                            Text(entry.workingDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(entry.workingDirectory)
                        }
                    }.width(min: 160, ideal: 240)
                    TableColumn("Owner") { entry in
                        Text(entry.route.isAlias ? "Static alias" : "PID \(entry.route.pid)")
                            .font(.callout.monospaced())
                    }.width(min: 100, ideal: 120)
                    TableColumn("") { entry in
                        Button {
                            if entry.route.isAlias { pendingAliasRemoval = entry }
                            else { pendingStop = entry }
                        } label: { Image(systemName: "stop.circle") }
                            .buttonStyle(.borderless)
                            .help(entry.route.isAlias ? "Remove alias" : "Stop Portless service")
                            .disabled(!entry.route.isAlias && !entry.isOwnerAlive)
                    }.width(32)
                }
                .contextMenu(forSelectionType: PortlessEntry.ID.self) { ids in
                    if let id = ids.first, let entry = rows.first(where: { $0.id == id }) {
                        Button("Copy URL") { copy(entry.url) }
                        if !entry.workingDirectory.isEmpty { Button("Copy project folder") { copy(entry.workingDirectory) } }
                        Divider()
                        if entry.route.isAlias {
                            Button("Remove alias…", role: .destructive) { pendingAliasRemoval = entry }
                        } else if entry.isOwnerAlive {
                            Button("Stop service…", role: .destructive) { pendingStop = entry }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Service, folder, or port")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Prune orphans…", systemImage: "leaf") { confirmPrune = true }
                    .disabled(monitor.isPruning)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await monitor.refresh() } }
                    .disabled(monitor.isRefreshing)
            }
        }
        .task {
            await monitor.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await monitor.refresh()
            }
        }
        .confirmationDialog("Stop \(pendingStop?.route.hostname ?? "service")?", isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }), presenting: pendingStop) { entry in
            Button("Stop Portless PID \(entry.route.pid)", role: .destructive) {
                pendingStop = nil
                Task { await monitor.stop(entry) }
            }
        } message: { entry in
            Text("Portless will stop this service and remove its routes. \(entry.command)")
        }
        .confirmationDialog("Remove \(pendingAliasRemoval?.route.hostname ?? "alias")?", isPresented: Binding(get: { pendingAliasRemoval != nil }, set: { if !$0 { pendingAliasRemoval = nil } }), presenting: pendingAliasRemoval) { entry in
            Button("Remove alias", role: .destructive) {
                pendingAliasRemoval = nil
                Task { await monitor.removeAlias(entry) }
            }
        } message: { _ in
            Text("This removes the Portless route. The service on the underlying port keeps running.")
        }
        .confirmationDialog("Prune orphaned Portless servers?", isPresented: $confirmPrune) {
            Button("Prune orphans", role: .destructive) { Task { await monitor.prune() } }
        } message: {
            Text("Portless will stop dev servers whose owning CLI process has exited and remove their stale routes.")
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
