import SwiftUI
import ChangeLinkCore
#if os(macOS)
import AppKit
#endif

@MainActor
final class MonitorModel: ObservableObject {
    @Published var roots: [URL] = []
    @Published var events: [ChangeEvent] = []
    @Published var isRunning = false
    @Published var interval: TimeInterval = 120
    @Published var intervalMinutes = "2"
    @Published var lastSnapshot: Date?
    @Published var snapshotCount = 0
    @Published var nextSnapshot: Date?
    @Published var statusMessage = "Add a directory to begin."
    @Published var currentSnapshots: [String: Snapshot] = [:]

    private var watchers: [String: PollingWatcher] = [:]

    func addRoot() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Monitor"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !roots.contains(url) { roots.append(url) }
        statusMessage = "\(roots.count) monitored root(s)"
        #endif
    }

    func removeRoot(_ root: URL) {
        watchers[root.path]?.stop()
        watchers[root.path] = nil
        roots.removeAll { $0 == root }
        statusMessage = "\(roots.count) monitored root(s)"
    }

    func toggleMonitoring() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !roots.isEmpty else {
            statusMessage = "Select at least one directory first."
            return
        }
        stop()
        guard let minutes = Double(intervalMinutes.trimmingCharacters(in: .whitespacesAndNewlines)),
              minutes > 0, minutes.isFinite else {
            statusMessage = "Enter a snapshot interval greater than zero minutes."
            return
        }
        interval = minutes * 60
        isRunning = true
        snapshotCount = 0
        nextSnapshot = Date().addingTimeInterval(interval)
        statusMessage = "Monitoring active. First snapshot establishes the baseline."
        for root in roots {
            currentSnapshots[root.path] = Snapshotter.take(root: root, hashContents: true)
            let watcher = PollingWatcher()
            watchers[root.path] = watcher
            do {
                try watcher.start(root: root, interval: interval) { [weak self] changes in
                Task { @MainActor in
                    guard let self else { return }
                    self.events.insert(contentsOf: changes, at: 0)
                    self.currentSnapshots[root.path] = Snapshotter.take(root: root, hashContents: true)
                    self.lastSnapshot = Date()
                    self.snapshotCount += 1
                    self.nextSnapshot = Date().addingTimeInterval(self.interval)
                    self.statusMessage = changes.isEmpty
                        ? "Snapshot \(self.snapshotCount) complete — no changes detected."
                        : "Snapshot \(self.snapshotCount) complete — \(changes.count) change(s) detected."
                }
            }
            } catch {
                statusMessage = "Could not monitor \(root.path): \(error.localizedDescription)"
                watcher.stop()
                watchers[root.path] = nil
            }
        }
    }

    func stop() {
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
        isRunning = false
        nextSnapshot = nil
        if roots.isEmpty { statusMessage = "Add a directory to begin." }
    }

    func takeSnapshotNow() {
        guard !roots.isEmpty else { return }
        statusMessage = "Snapshot requested. The next comparison will use the captured baseline."
        stop()
        start()
    }
}

@main
struct ChangeLinkApp: App {
    @StateObject private var model = MonitorModel()
    var body: some Scene {
        WindowGroup { DashboardView(model: model) }
    }
}

struct TreeRow: Identifiable {
    let id: String
    let name: String
    let path: String
    let depth: Int
    let kind: ChangeKind?
    let isDirectory: Bool
    let size: Int64?
    let statusText: String?
}

struct DashboardView: View {
    @ObservedObject var model: MonitorModel
    @State private var selectedKind: ChangeKind?

    private var filteredEvents: [ChangeEvent] {
        model.events.filter { selectedKind == nil || $0.kind == selectedKind }
    }

    private var treeRows: [TreeRow] {
        var rows: [String: TreeRow] = [:]
        let eventsByPath = Dictionary(filteredEvents.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for (rootPath, snapshot) in model.currentSnapshots {
            let rootName = URL(fileURLWithPath: rootPath).lastPathComponent
            let rootRow = TreeRow(id: rootName, name: rootName, path: rootName, depth: 0,
                                  kind: nil, isDirectory: true, size: nil, statusText: nil)
            rows[rootName] = rootRow
            for record in snapshot.files.values {
                let components = ([rootName] + record.path.split(separator: "/").map(String.init))
                let event = eventsByPath[record.path]
                for index in components.indices {
                    let path = components[0...index].joined(separator: "/")
                    let isLeaf = index == components.count - 1
                    let existing = rows[path]
                    rows[path] = TreeRow(
                        id: path,
                        name: components[index],
                        path: path,
                        depth: index,
                        kind: isLeaf ? event?.kind : existing?.kind,
                        isDirectory: !isLeaf || record.isDirectory,
                        size: isLeaf ? record.size : existing?.size,
                        statusText: isLeaf ? event.map(changeSummary) : existing?.statusText
                    )
                }
            }
        }
        for event in filteredEvents where event.kind == .delete {
            let components = event.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            for index in components.indices {
                let path = components[0...index].joined(separator: "/")
                let isLeaf = index == components.count - 1
                if rows[path] == nil {
                    rows[path] = TreeRow(
                    id: path,
                    name: components[index],
                    path: path,
                    depth: index,
                    kind: isLeaf ? event.kind : nil,
                    isDirectory: !isLeaf || event.nodeKind == .directory,
                    size: isLeaf ? event.previousSize : nil,
                    statusText: isLeaf ? changeSummary(event) : nil
                    )
                }
            }
        }
        return rows.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("Monitoring") {
                    Label(model.isRunning ? "ACTIVE" : "STOPPED",
                          systemImage: model.isRunning ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(model.isRunning ? .green : .secondary)
                    ForEach(model.roots, id: \.path) { root in
                        HStack {
                            Label(root.path, systemImage: "folder")
                                .lineLimit(1)
                            Spacer()
                            Button("Remove") { model.removeRoot(root) }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Directory…", action: model.addRoot)
                    HStack {
                        Text("Snapshot every")
                        TextField("minutes", text: $model.intervalMinutes)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 82)
                        Text("minutes")
                    }
                    Text("Any positive duration is accepted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(model.isRunning ? "Stop Monitoring" : "Start Monitoring",
                           action: model.toggleMonitoring)
                    .buttonStyle(.borderedProminent)
                    Button("Take Snapshot Now", action: model.takeSnapshotNow)
                }
                Section("Timeline") {
                    Picker("Filter", selection: $selectedKind) {
                        Text("All").tag(ChangeKind?.none)
                        ForEach(ChangeKind.allCases, id: \.self) {
                            Text($0.rawValue.capitalized).tag(Optional($0))
                        }
                    }
                    .pickerStyle(.menu)
                    ForEach(filteredEvents, id: \.path) { event in
                        NavigationLink {
                            ChangeDetailView(event: event)
                        } label: {
                            Label(event.path, systemImage: icon(for: event.kind))
                                .badge(event.kind.rawValue.uppercased())
                        }
                    }
                }
                Section("Change tree") {
                    if treeRows.isEmpty {
                        Text("No changes in the selected filter.")
                                .foregroundStyle(.secondary)
                    } else {
                        ForEach(treeRows) { row in
                                HStack(spacing: 6) {
                                    Text(String(repeating: "  ", count: row.depth))
                                    Image(systemName: row.isDirectory ? "folder.fill" : "doc.fill")
                                        .foregroundStyle(color(for: row.kind))
                                    Text(row.name)
                                    Spacer()
                                    if let kind = row.kind {
                                        Text(kind.rawValue.uppercased())
                                            .font(.caption2.bold())
                                            .foregroundStyle(color(for: kind))
                                    }
                                    if let status = row.statusText {
                                        Text(status).font(.caption2).foregroundStyle(color(for: row.kind))
                                    }
                                }
                                .help(row.path)
                        }
                    }
                }
            }
            .navigationTitle("Change-Link")
            .frame(minWidth: 360)
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                Text("Historical directory-tree monitoring")
                    .font(.title2.bold())
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    Label("\(model.snapshotCount) completed", systemImage: "camera")
                    if let last = model.lastSnapshot {
                        Label("Last \(last.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                    }
                    if let next = model.nextSnapshot {
                        Label("Next \(next.formatted(date: .omitted, time: .shortened))", systemImage: "forward")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                Text("Overview + detail")
                    .font(.headline)
                Text("Snapshot columns use the Change-Link semantics: blue = exists, white = not yet observed, red = previously existed and is now absent. Select a change to inspect its evidence.")
                    .foregroundStyle(.secondary)
                TreeLegend()
                if !treeRows.isEmpty {
                    Divider()
                    Text("Changed directory tree")
                        .font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(treeRows) { row in
                                HStack(spacing: 8) {
                                    Text(String(repeating: "    ", count: row.depth))
                                    Image(systemName: row.isDirectory ? "folder.fill" : "doc.fill")
                                    Text(row.name)
                                    Spacer()
                                    Text((row.kind?.rawValue ?? "context").uppercased())
                                        .font(.caption.bold())
                                    if let status = row.statusText {
                                        Text(status).font(.caption2)
                                    }
                                }
                                .foregroundStyle(color(for: row.kind))
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding()
        }
    }

    private func icon(for kind: ChangeKind) -> String {
        switch kind {
        case .create: return "plus.circle"
        case .delete: return "minus.circle"
        case .modify: return "asterisk.circle"
        case .rename, .move: return "arrow.left.arrow.right.circle"
        }
    }

    private func color(for kind: ChangeKind?) -> Color {
        switch kind {
        case .create: return .green
        case .delete: return .red
        case .modify: return .orange
        case .rename, .move: return .purple
        case nil: return .primary
        }
    }

    private func changeSummary(_ event: ChangeEvent) -> String {
        var details: [String] = []
        if let previous = event.previousSize, let current = event.currentSize, previous != current {
            let delta = current - previous
            details.append("size \(previous) → \(current) bytes (\(delta >= 0 ? "+" : "")\(delta))")
        } else if let current = event.currentSize, event.kind == .create {
            details.append("size \(current) bytes")
        }
        if event.contentChanged { details.append("content changed") }
        if details.isEmpty { return event.kind.rawValue.uppercased() }
        return details.joined(separator: ", ")
    }
}

struct TreeLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            legend("Created", .green)
            legend("Deleted", .red)
            legend("Modified", .orange)
            legend("Moved/Renamed", .purple)
            legend("Context", .primary)
        }
        .font(.caption)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        Label(title, systemImage: "square.fill").foregroundStyle(color)
    }
}

struct ChangeDetailView: View {
    let event: ChangeEvent
    var body: some View {
        Form {
            Section("Change") {
                LabeledContent("Type", value: event.kind.rawValue.capitalized)
                LabeledContent("Path", value: event.path)
                if let oldPath = event.oldPath {
                    LabeledContent("Previous path", value: oldPath)
                }
                if let previousSize = event.previousSize {
                    LabeledContent("Previous size", value: "\(previousSize) bytes")
                }
                if let currentSize = event.currentSize {
                    LabeledContent("Current size", value: "\(currentSize) bytes")
                }
                LabeledContent("Content changed", value: event.contentChanged ? "Yes (hash/metadata evidence)" : "No or not applicable")
                LabeledContent("Stable file ID", value: event.fileID)
                LabeledContent("Observed", value: event.observedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("Attribution") {
                Text("UNKNOWN")
                    .font(.headline)
                Text("Filesystem snapshots and FSEvents establish that the filesystem changed, but do not prove which user or process caused it. No attribution is inferred.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
