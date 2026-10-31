import SwiftUI
import AppKit
import ChangeLinkCore

private enum SnapshotCaptureResult: Sendable {
    case success(Snapshot)
    case failure(String)
}

enum IntervalUnit: String, CaseIterable, Identifiable {
    case seconds = "Seconds", minutes = "Minutes", hours = "Hours"
    var id: String { rawValue }
    var multiplier: Double {
        switch self {
        case .seconds: return 1
        case .minutes: return 60
        case .hours: return 3600
        }
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var roots: [URL] = []
    @Published var events: [ChangeEvent] = []
    @Published var isRunning = false
    @Published var interval: TimeInterval = 120
    @Published var intervalValue = "2"
    @Published var intervalUnit: IntervalUnit = .minutes
    @Published var intervalError: String?
    /// Re-scan as soon as the filesystem reports a change, so the trees update inside the interval.
    @Published var liveUpdates = true
    @Published var lastSnapshot: Date?
    @Published var snapshotCount = 0
    @Published var nextSnapshot: Date?
    @Published var statusMessage = "Add a directory to begin."
    @Published var currentSnapshots: [String: Snapshot] = [:]
    /// First snapshot of each root in this monitoring session: the "original" tree.
    @Published var baselineSnapshots: [String: Snapshot] = [:]
    /// Original-vs-modified trees and summary per root path.
    @Published var diffs: [String: RootDiff] = [:]
    /// Every modification observed since each root's baseline (an item can appear many times).
    private var changeLog: [String: [ChangeEvent]] = [:]
    @Published private(set) var isSnapshotInProgress = false

    private var monitoringTask: Task<Void, Never>?
    private var activeIntervalText = "2 minutes"
    private var demoRootPaths: Set<String> = []
    private let liveTrigger = FSEventsTrigger()
    private var liveRefreshScheduled = false

    func addRoot() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Monitor"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !roots.contains(where: { $0.path == url.path }) { roots.append(url) }
        statusMessage = "\(roots.count) monitored root(s)"
        if isRunning {
            refreshLiveWatching()
            Task { await captureSnapshots() }
        }
        #endif
    }

    func removeRoot(_ root: URL) {
        currentSnapshots[root.path] = nil
        baselineSnapshots[root.path] = nil
        diffs[root.path] = nil
        changeLog[root.path] = nil
        demoRootPaths.remove(root.path)
        roots.removeAll { $0 == root }
        statusMessage = "\(roots.count) monitored root(s)"
        if roots.isEmpty {
            stop()
        } else {
            refreshLiveWatching()
        }
    }

    func toggleMonitoring() {
        isRunning ? stop() : start()
    }

    func start() {
        let actualRoots = roots.filter { !demoRootPaths.contains($0.path) }
        let hadDemoRoots = actualRoots.count != roots.count
        if hadDemoRoots {
            roots = actualRoots
            demoRootPaths.removeAll()
            currentSnapshots = currentSnapshots.filter { entry in
                actualRoots.contains { $0.path == entry.key }
            }
            baselineSnapshots = baselineSnapshots.filter { entry in
                actualRoots.contains { $0.path == entry.key }
            }
            diffs = diffs.filter { entry in
                actualRoots.contains { $0.path == entry.key }
            }
            changeLog = changeLog.filter { entry in
                actualRoots.contains { $0.path == entry.key }
            }
            events.removeAll()
            snapshotCount = 0
            lastSnapshot = nil
        }
        guard !roots.isEmpty else {
            statusMessage = hadDemoRoots
                ? "Demo output is test data. Add a real directory before starting monitoring."
                : "Select at least one directory first."
            return
        }
        guard let seconds = parsedInterval() else {
            statusMessage = intervalError ?? "Enter a valid interval."
            return
        }
        stop()
        interval = seconds
        activeIntervalText = intervalText
        isRunning = true
        snapshotCount = 0
        events.removeAll()
        currentSnapshots.removeAll()
        baselineSnapshots.removeAll()
        diffs.removeAll()
        changeLog.removeAll()
        lastSnapshot = nil
        statusMessage = "Capturing baseline snapshot…"
        monitoringTask = makeMonitoringLoop(captureFirst: true)
        refreshLiveWatching()
    }

    /// (Re)starts the filesystem watcher for the current roots. Safe to call at any time.
    func refreshLiveWatching() {
        liveTrigger.stop()
        guard isRunning, liveUpdates, !roots.isEmpty else { return }
        let started = liveTrigger.start(paths: roots.map { $0.path }, latency: 0.5) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleLiveRefresh() }
        }
        if !started {
            statusMessage = "Live updates are unavailable for these folders; trees refresh at each interval."
        }
    }

    /// Coalesces bursts of filesystem events into one rescan.
    private func scheduleLiveRefresh() {
        guard isRunning, liveUpdates, !liveRefreshScheduled else { return }
        liveRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            // Cleared before scanning so events that arrive during the scan schedule another refresh.
            self.liveRefreshScheduled = false
            guard self.isRunning, self.liveUpdates else { return }
            await self.captureSnapshots(live: true)
        }
    }

    /// The repeating schedule. It reads `interval` before every sleep, so a new value takes effect immediately
    /// when the loop is replaced by `applyInterval()`.
    private func makeMonitoringLoop(captureFirst: Bool) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if captureFirst { await self.captureSnapshots() }
            while self.isRunning && !Task.isCancelled {
                self.nextSnapshot = Date().addingTimeInterval(self.interval)
                do {
                    let nanoseconds = max(1, UInt64(self.interval * 1_000_000_000))
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    break
                }
                guard self.isRunning && !Task.isCancelled else { break }
                await self.captureSnapshots()
            }
        }
    }

    private var intervalText: String {
        let trimmed = intervalValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = intervalUnit.rawValue.lowercased()
        return "\(trimmed) \(unit)"
    }

    /// Validates the interval fields and returns the duration in seconds (sets `intervalError` on failure).
    private func parsedInterval() -> TimeInterval? {
        let trimmed = intervalValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, value > 0 else {
            intervalError = "Enter a positive number."
            return nil
        }
        let seconds = value * intervalUnit.multiplier
        guard seconds >= 1 else {
            intervalError = "The interval must be at least 1 second."
            return nil
        }
        guard seconds <= 365 * 24 * 3600 else {
            intervalError = "The interval must be at most 365 days."
            return nil
        }
        intervalError = nil
        return seconds
    }

    /// Applies the interval fields. While monitoring, the schedule is replaced immediately; baselines are kept.
    func applyInterval() {
        guard let seconds = parsedInterval() else { return }
        interval = seconds
        activeIntervalText = intervalText
        guard isRunning else {
            statusMessage = "Snapshot interval set to \(intervalText)."
            return
        }
        monitoringTask?.cancel()
        monitoringTask = makeMonitoringLoop(captureFirst: false)
        statusMessage = "Interval changed to \(intervalText). The next snapshot follows on the new schedule."
    }

    func stop() {
        liveTrigger.stop()
        monitoringTask?.cancel()
        monitoringTask = nil
        isRunning = false
        nextSnapshot = nil
        statusMessage = roots.isEmpty ? "Add a directory to begin." : "Monitoring stopped."
    }

    func takeSnapshotNow() {
        guard !roots.isEmpty else {
            statusMessage = "Select at least one directory before taking a snapshot."
            return
        }
        guard !isSnapshotInProgress else {
            statusMessage = "A snapshot is already in progress."
            return
        }
        Task { await captureSnapshots() }
    }

    private func captureSnapshots(live: Bool = false) async {
        while isSnapshotInProgress {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }
        guard !roots.isEmpty, !Task.isCancelled else { return }
        isSnapshotInProgress = true
        defer { isSnapshotInProgress = false }

        let scanRoots = roots
        let oldSnapshots = currentSnapshots
        if !live { statusMessage = "Scanning \(scanRoots.count) root(s)…" }
        let capturedSnapshots = await Task.detached(priority: .utility) {
            Dictionary(scanRoots.map { root -> (String, SnapshotCaptureResult) in
                do {
                    return (root.path, .success(try Snapshotter.takeValidated(root: root, hashContents: true,
                                                                       reusingHashesFrom: live ? oldSnapshots[root.path] : nil)))
                } catch {
                    return (root.path, .failure(error.localizedDescription))
                }
            }, uniquingKeysWith: { first, _ in first })
        }.value
        guard !Task.isCancelled else { return }

        var changes: [ChangeEvent] = []
        var baselineCount = 0
        var failures: [String] = []
        var updatedPaths: [String] = []
        for root in scanRoots where roots.contains(root) {
            guard let result = capturedSnapshots[root.path] else { continue }
            let current: Snapshot
            switch result {
            case .success(let snapshot):
                current = snapshot
            case .failure(let error):
                failures.append("\(root.lastPathComponent): \(error)")
                continue
            }
            if let previous = oldSnapshots[root.path] {
                let rootChanges = SnapshotComparator.compare(previous, current)
                changes.append(contentsOf: rootChanges)
                // Keep every modification, so an item edited several times is listed several times.
                changeLog[root.path, default: []].append(contentsOf: rootChanges)
            } else {
                baselineCount += 1
                changeLog[root.path] = []
            }
            currentSnapshots[root.path] = current
            if baselineSnapshots[root.path] == nil { baselineSnapshots[root.path] = current }
            updatedPaths.append(root.path)
        }
        guard !capturedSnapshots.isEmpty else {
            statusMessage = "No snapshots could be collected."
            return
        }

        if !changes.isEmpty {
            events.insert(contentsOf: changes.sorted { $0.path < $1.path }, at: 0)
        }
        let successfulCount = capturedSnapshots.values.filter {
            if case .success = $0 { return true } else { return false }
        }.count
        guard successfulCount > 0 else {
            statusMessage = "Snapshot failed: \(failures.joined(separator: "; ")). Previous snapshots were kept; no deletions were inferred."
            return
        }
        await rebuildDiffs(for: updatedPaths)
        if live && failures.isEmpty {
            lastSnapshot = Date()
            let total = updatedPaths.reduce(0) { $0 + (diffs[$1]?.summary.total ?? 0) }
            statusMessage = total == 0
                ? "Live — no changes since the baseline."
                : "Live — \(total) change(s) since the baseline (updated \(Date().formatted(date: .omitted, time: .standard)))."
            return
        }
        snapshotCount += 1
        lastSnapshot = Date()
        if !failures.isEmpty {
            statusMessage = "Snapshot incomplete — \(failures.joined(separator: "; ")). Previous snapshots were kept for failed roots."
        } else if baselineCount == scanRoots.count {
            statusMessage = "Baseline captured for \(baselineCount) root(s). Monitoring every \(activeIntervalText)."
        } else if changes.isEmpty {
            statusMessage = "Snapshot \(snapshotCount) complete — no changes detected."
        } else {
            statusMessage = "Snapshot \(snapshotCount) complete — \(changes.count) change(s) detected."
        }
    }

    /// Builds the original/modified trees off the main thread (they can be large).
    private func rebuildDiffs(for paths: [String]) async {
        let jobs: [(String, Snapshot, Snapshot, [ChangeEvent])] = paths.compactMap { path in
            guard let baseline = baselineSnapshots[path], let current = currentSnapshots[path] else { return nil }
            return (path, baseline, current, changeLog[path] ?? [])
        }
        guard !jobs.isEmpty else { return }
        let built: [(String, RootDiff)] = await Task.detached(priority: .utility) {
            jobs.map { job in
                (job.0, DirectoryTreeDiff.build(rootPath: job.0, baseline: job.1, current: job.2, history: job.3))
            }
        }.value
        for (path, diff) in built where roots.contains(where: { $0.path == path }) {
            diffs[path] = diff
        }
    }

    /// Makes the latest snapshot the new "original" so only future changes are shown.
    func resetBaseline() {
        guard !currentSnapshots.isEmpty, !isSnapshotInProgress else { return }
        baselineSnapshots = currentSnapshots
        changeLog.removeAll()
        statusMessage = "Baseline reset to the latest snapshot."
        Task { await rebuildDiffs(for: Array(currentSnapshots.keys)) }
    }

    func loadDemoScenario() {
        stop()
        demoRootPaths.removeAll()
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ChangeLink-Demo-\(UUID().uuidString)", isDirectory: true)
            let projects = root.appendingPathComponent("Documents/Projects", isDirectory: true)
            let reports = root.appendingPathComponent("Documents/Reports", isDirectory: true)
            let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try Data("Project plan: draft with design tasks, milestones, and notes.\n".utf8)
                .write(to: projects.appendingPathComponent("plan.txt"))
            try Data("Status: in progress; reviewed on Monday.\n".utf8)
                .write(to: reports.appendingPathComponent("status.txt"))
            try Data(repeating: 0x41, count: 8192)
                .write(to: downloads.appendingPathComponent("old-cache.bin"))
            try Data("Meeting notes, first draft.\n".utf8)
                .write(to: reports.appendingPathComponent("notes.txt"))
            try Data("Installer payload.\n".utf8)
                .write(to: downloads.appendingPathComponent("installer.pkg"))

            let baseline = try Snapshotter.takeValidated(root: root, hashContents: true)
            try Data("Encrypted-looking test bytes.\n".utf8)
                .write(to: projects.appendingPathComponent("plan.txt"))
            try Data("Status: complete.\n".utf8)
                .write(to: reports.appendingPathComponent("status.txt"))
            let newFolder = projects.appendingPathComponent("New Feature", isDirectory: true)
            try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
            try Data("Created after the baseline.\n".utf8)
                .write(to: newFolder.appendingPathComponent("README.md"))
            try FileManager.default.removeItem(at: downloads.appendingPathComponent("old-cache.bin"))
            try FileManager.default.moveItem(at: reports.appendingPathComponent("notes.txt"),
                                             to: reports.appendingPathComponent("notes-final.txt"))
            try FileManager.default.moveItem(at: downloads.appendingPathComponent("installer.pkg"),
                                             to: projects.appendingPathComponent("installer.pkg"))

            let current = try Snapshotter.takeValidated(root: root, hashContents: true)
            let detected = SnapshotComparator.compare(baseline, current)
            roots = [root]
            demoRootPaths = [root.path]
            events = detected
            currentSnapshots = [root.path: current]
            baselineSnapshots = [root.path: baseline]
            changeLog = [root.path: detected]
            diffs = [root.path: DirectoryTreeDiff.build(rootPath: root.path, baseline: baseline,
                                                        current: current, history: detected)]
            lastSnapshot = current.takenAt
            snapshotCount = 2
            nextSnapshot = nil
            statusMessage = "Demo test data: compared 2 local filesystem snapshots; detected \(detected.count) changes."
        } catch {
            statusMessage = "Could not create demo snapshots: \(error.localizedDescription)"
        }
    }
}

/// `swift run` launches the executable without an app bundle, so macOS treats it as a background tool:
/// its window never becomes the key window and text fields cannot receive keyboard input.
/// Promoting it to a regular app and activating it fixes typing.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}

struct ChangeLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = MonitorModel()
    var body: some Scene {
        WindowGroup {
            DashboardView(model: model)
                .frame(minWidth: 1250, minHeight: 800)
        }
        .defaultSize(width: 1370, height: 850)
    }
}

struct DashboardView: View {
    @ObservedObject var model: MonitorModel
    @State private var selectedKind: ChangeKind?
    @State private var selectedEvent: ChangeEvent?
    @State private var showSummary = true

    private var filteredEvents: [ChangeEvent] {
        timelineEvents.filter { selectedKind == nil || $0.kind == selectedKind }
    }

    /// Every change since the baseline, kept current by live updates (same data as the trees and summary).
    private var timelineEvents: [ChangeEvent] {
        orderedDiffs.flatMap { diff in
            diff.summary.entries.filter { !$0.isImplied }.map { $0.event }
        }
    }

    /// Diffs in the same order as the monitored roots.
    private var orderedDiffs: [RootDiff] {
        model.roots.compactMap { model.diffs[$0.path] }
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
                            Label(root.lastPathComponent.hasPrefix("ChangeLink-Demo-") ? "Demo Files" : root.path,
                                  systemImage: "folder")
                                .lineLimit(1)
                                .help(root.path)
                            Spacer()
                            Button("Remove") { model.removeRoot(root) }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Directory…", action: model.addRoot)
                    Button("Load Demo Output", action: model.loadDemoScenario)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Snapshot interval")
                        HStack {
                            TextField("value", text: $model.intervalValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .onSubmit { model.applyInterval() }
                            Picker("Unit", selection: $model.intervalUnit) {
                                ForEach(IntervalUnit.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                            Button("Apply") { model.applyInterval() }
                        }
                        if let error = model.intervalError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        } else {
                            Text(model.isRunning ? "Changes apply immediately while monitoring." : "Used when monitoring starts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: model.intervalUnit) { _ in model.applyInterval() }
                    Toggle("Live updates", isOn: $model.liveUpdates)
                        .help("Update the trees as soon as files change, without waiting for the interval.")
                        .onChange(of: model.liveUpdates) { _ in model.refreshLiveWatching() }
                    Button(model.isRunning ? "Stop Monitoring" : "Start Monitoring",
                           action: model.toggleMonitoring)
                    .buttonStyle(.borderedProminent)
                    Button(model.isSnapshotInProgress ? "Snapshot in Progress…" : "Take Snapshot Now",
                           action: model.takeSnapshotNow)
                        .disabled(model.isSnapshotInProgress)
                    Button("Set Latest as New Baseline", action: model.resetBaseline)
                        .disabled(model.currentSnapshots.isEmpty || model.isSnapshotInProgress)
                        .help("Use the latest snapshot as the Original tree; only later changes will be shown.")
                }
                Section("Changes since baseline") {
                    Picker("Filter", selection: $selectedKind) {
                        Text("All").tag(ChangeKind?.none)
                        ForEach(ChangeKind.allCases, id: \.self) {
                            Text($0.rawValue.capitalized).tag(Optional($0))
                        }
                    }
                    .pickerStyle(.menu)
                    if filteredEvents.isEmpty {
                        Text("No changes recorded.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(filteredEvents.enumerated()), id: \.offset) { _, event in
                        Button {
                            selectedEvent = event
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(color(for: event.kind))
                                    .frame(width: 8, height: 8)
                                Image(systemName: icon(for: event.kind))
                                    .foregroundStyle(color(for: event.kind))
                                Text(event.path)
                                    .layoutPriority(1)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(color(for: event.kind))
                                Spacer(minLength: 4)
                                changeBadge(event.kind.rawValue.uppercased(), kind: event.kind)
                            }
                            .contentShape(Rectangle())
                            .help("\(event.kind.rawValue.capitalized): \(event.path)")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Change-Link")
            .frame(minWidth: 360)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Historical directory-tree monitoring")
                    .font(.title2.bold())
                HStack(spacing: 8) {
                    if model.isSnapshotInProgress {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.statusMessage)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
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
                TreeLegend()
                    .help("Left tree: the directory at the baseline. Right tree: the same directory now. Click any folder node to expand or collapse it in both trees.")
                Divider()
                if orderedDiffs.isEmpty {
                    Spacer()
                    Text("Add a directory and start monitoring (or load the demo output) to see its original and modified trees side by side.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(orderedDiffs) { diff in
                                RootDiffSection(diff: diff)
                                    .id(diff.token)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
                HStack {
                    Divider()
                    Button(showSummary ? "Hide summary" : "Show summary") { showSummary.toggle() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .fixedSize()
                    Divider()
                }
                .frame(height: 16)
                if showSummary {
                    SummaryPanel(diffs: orderedDiffs, selectedEvent: $selectedEvent)
                        .frame(height: 200)
                }
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
        guard let kind else { return .primary }
        return kind.nodeStatus.color
    }

    private func changeBadge(_ title: String, kind: ChangeKind) -> some View {
        Text(title)
            .font(.caption2.bold())
            .foregroundStyle(color(for: kind))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color(for: kind).opacity(0.14), in: Capsule())
    }
}

struct TreeLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            legend("Created", .green)
            legend("Deleted", .red)
            legend("Modified", .orange)
            legend("Moved/Renamed", .purple)
            legend("Unchanged", .gray)
            Text("dashed = not present on this side")
                .foregroundStyle(.secondary)
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
                if let changeKind = event.contentChangeKind, changeKind != .metadataOnly {
                    LabeledContent("Modification type") {
                        Text(changeKind.label.capitalized)
                            .foregroundStyle(changeKind == .likelyEncrypted ? .red : .primary)
                            .fontWeight(changeKind == .likelyEncrypted ? .bold : .regular)
                    }
                    if let before = event.previousEntropy, let after = event.currentEntropy {
                        LabeledContent("Entropy (bits/byte)", value: String(format: "%.2f → %.2f", before, after))
                    }
                }
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

// Explicit entry point: this target has several source files, so SwiftPM treats main.swift as top-level code.
ChangeLinkApp.main()
