import Foundation

// MARK: - Model

/// How a node in a directory tree differs between the original and the modified snapshot.
public enum NodeStatus: String, Codable, Sendable, CaseIterable {
    case unchanged, created, deleted, modified, renamed, moved
}

/// One modification that happened to a node (a node can have many: edited, renamed, edited again, ...).
public struct NodeChange: Equatable, Sendable {
    public let kind: ChangeKind
    public let observedAt: Date
    public let detail: String
}

/// One node of a visualised directory tree. The root node has `id == ""`.
public struct TreeNode: Identifiable, Equatable, Sendable {
    public let id: String            // relative path; "" for the root
    public let name: String
    public let isDirectory: Bool
    public let status: NodeStatus
    public let size: Int64?
    /// Human-readable explanation of the change ("renamed from a.txt", "size 10 → 20 bytes", ...).
    public let note: String?
    /// A ghost node does not exist in this tree's snapshot; it is drawn only to show a change
    /// (for example a file that was deleted, shown dashed in the modified tree).
    public let isGhost: Bool
    /// Every modification recorded for this item since the baseline, oldest first.
    public let history: [NodeChange]
    public let children: [TreeNode]
    /// Number of nodes anywhere beneath this one.
    public let descendantCount: Int
    /// Number of changed nodes anywhere beneath this one.
    public let changedDescendants: Int

    public var path: String { id }
    /// True when this node itself was touched (net change or any recorded modification).
    public var isTouched: Bool { status != .unchanged || !history.isEmpty }
    public var hasChange: Bool { isTouched || changedDescendants > 0 }
}

public struct TreeTotals: Equatable, Sendable {
    public let files: Int
    public let directories: Int
    public let bytes: Int64
}

public struct SummaryEntry: Identifiable, Equatable, Sendable {
    public let event: ChangeEvent
    public let detail: String
    /// True for a rename/move that is only a consequence of an ancestor folder being renamed/moved.
    public let isImplied: Bool
    public var id: String {
        // Unique per modification: an item edited several times has several entries with the same kind and path.
        "\(event.kind.rawValue)|\(event.oldPath ?? "")|\(event.path)|\(event.observedAt.timeIntervalSince1970)|\(event.previousSize ?? -1)|\(event.currentSize ?? -1)"
    }
}

public struct ChangeSummary: Equatable, Sendable {
    public let entries: [SummaryEntry]
    public let counts: [ChangeKind: Int]
    /// Number of distinct files/folders that were touched (an item modified three times counts once).
    public let itemCount: Int
    public let impliedCount: Int
    public let before: TreeTotals
    public let after: TreeTotals
    public var total: Int { counts.values.reduce(0, +) }
    public var byteDelta: Int64 { after.bytes - before.bytes }
}

/// The original tree, the modified tree and the summary for one monitored directory.
public struct RootDiff: Identifiable, Equatable, Sendable {
    public let rootPath: String
    public let rootName: String
    public let baselineTakenAt: Date
    public let currentTakenAt: Date
    public let original: TreeNode
    public let modified: TreeNode
    public let summary: ChangeSummary
    /// Metrics of both trees side by side (nodes, depth, levels, branching, similarity, ...).
    public let comparison: TreeComparison
    public var id: String { rootPath }
    /// Changes only when the baseline changes (not on live refreshes), so view state such as
    /// expanded folders survives live updates and resets when a new comparison starts.
    public var token: String { "\(rootPath)|\(baselineTakenAt.timeIntervalSince1970)" }
}

// MARK: - Builder

public enum DirectoryTreeDiff {
    /// - Parameter history: every modification recorded since the baseline (several per item are possible).
    ///   When nil, the net difference between the two snapshots is used as the history.
    public static func build(rootPath: String, baseline: Snapshot, current: Snapshot,
                             history: [ChangeEvent]? = nil) -> RootDiff {
        let netEvents = SnapshotComparator.compare(baseline, current)
        let log = (history ?? netEvents).sorted {
            $0.observedAt != $1.observedAt ? $0.observedAt < $1.observedAt : $0.path < $1.path
        }
        let rootName = displayName(forRootPath: rootPath)

        // Net status of each path in the modified tree decides the colour; the history decides what is listed.
        var newSide: [String: ChangeEvent] = [:]   // create / modify / rename / move, keyed by the NEW path
        for event in netEvents {
            switch event.kind {
            case .delete:
                break
            case .create, .modify, .rename, .move:
                newSide[event.path] = event
            }
        }

        // Index the history so every node can collect all of its modifications.
        var byFileID: [String: [ChangeEvent]] = [:]
        var byPath: [String: [ChangeEvent]] = [:]
        for event in log {
            byFileID[event.fileID, default: []].append(event)
            byPath[event.path, default: []].append(event)
            if let old = event.oldPath { byPath[old, default: []].append(event) }
        }
        func changes(fileID: String?, path: String) -> [NodeChange] {
            var seen = Set<String>()
            var collected: [ChangeEvent] = []
            let candidates = (fileID.flatMap { byFileID[$0] } ?? []) + (byPath[path] ?? [])
            for event in candidates {
                let key = "\(event.kind.rawValue)|\(event.oldPath ?? "")|\(event.path)|\(event.observedAt.timeIntervalSince1970)"
                if seen.insert(key).inserted { collected.append(event) }
            }
            collected.sort { $0.observedAt != $1.observedAt ? $0.observedAt < $1.observedAt : $0.path < $1.path }
            return collected.map { NodeChange(kind: $0.kind, observedAt: $0.observedAt, detail: describe($0)) }
        }

        // Original tree: the baseline structure only. It carries no change marks, notes or history,
        // so it always shows exactly what was there when monitoring began.
        var originalEntries: [Entry] = []
        for record in baseline.files.values {
            originalEntries.append(Entry(path: record.path, isDirectory: record.isDirectory,
                                         size: record.isDirectory ? nil : record.size,
                                         status: .unchanged, note: nil, ghost: false, history: []))
        }

        // Modified tree: everything that exists now, plus ghosts for deleted items.
        var modifiedEntries: [Entry] = []
        for record in current.files.values {
            var status = NodeStatus.unchanged
            var note: String?
            if let event = newSide[record.path] {
                switch event.kind {
                case .create: status = .created; note = describe(event)
                case .modify: status = .modified; note = describe(event)
                case .rename: status = .renamed; note = describe(event)
                case .move: status = .moved; note = describe(event)
                case .delete: break
                }
            }
            modifiedEntries.append(Entry(path: record.path, isDirectory: record.isDirectory,
                                         size: record.isDirectory ? nil : record.size,
                                         status: status, note: note, ghost: false,
                                         history: changes(fileID: record.fileID, path: record.path)))
        }
        // Items deleted at any point (including ones created and deleted again) appear as dashed ghosts,
        // unless a different file now occupies the same path (its history already lists the deletion).
        var ghostPaths = Set<String>()
        for event in log where event.kind == .delete && current.files[event.path] == nil {
            guard ghostPaths.insert(event.path).inserted else { continue }
            let itemChanges = changes(fileID: event.fileID, path: event.path)
            let createdDuringMonitoring = itemChanges.contains { $0.kind == .create }
            modifiedEntries.append(Entry(path: event.path, isDirectory: event.nodeKind == .directory,
                                         size: event.previousSize, status: .deleted,
                                         note: createdDuringMonitoring
                                             ? "created and deleted during monitoring"
                                             : "deleted (not present in the latest snapshot)",
                                         ghost: true, history: itemChanges))
        }

        let originalTree = assemble(rootName: rootName, entries: originalEntries)
        let modifiedTree = assemble(rootName: rootName, entries: modifiedEntries)
        let summary = summarize(events: log, baseline: baseline, current: current)
        return RootDiff(
            rootPath: rootPath,
            rootName: rootName,
            baselineTakenAt: baseline.takenAt,
            currentTakenAt: current.takenAt,
            original: originalTree,
            modified: modifiedTree,
            summary: summary,
            comparison: TreeComparison.make(original: originalTree, modified: modifiedTree,
                                            counts: summary.counts, touchedItems: summary.itemCount)
        )
    }

    // MARK: Summary

    static func summarize(events: [ChangeEvent], baseline: Snapshot, current: Snapshot) -> ChangeSummary {
        var moveByPath: [String: ChangeEvent] = [:]
        for event in events where event.kind == .rename || event.kind == .move { moveByPath[event.path] = event }

        var entries: [SummaryEntry] = []
        var counts: [ChangeKind: Int] = [:]
        var implied = 0
        var items = Set<String>()
        for event in events {
            var isImplied = false
            if (event.kind == .rename || event.kind == .move), let old = event.oldPath,
               let parentEvent = moveByPath[SnapshotComparator.parentPath(event.path)],
               parentEvent.oldPath == SnapshotComparator.parentPath(old) {
                isImplied = true
            }
            entries.append(SummaryEntry(event: event, detail: describe(event), isImplied: isImplied))
            if isImplied { implied += 1 } else { counts[event.kind, default: 0] += 1; items.insert(event.fileID) }
        }
        // Group every modification of the same item together, oldest first.
        entries.sort {
            $0.event.path != $1.event.path ? $0.event.path < $1.event.path : $0.event.observedAt < $1.event.observedAt
        }
        return ChangeSummary(entries: entries, counts: counts, itemCount: items.count, impliedCount: implied,
                             before: totals(baseline), after: totals(current))
    }

    static func totals(_ snapshot: Snapshot) -> TreeTotals {
        var files = 0, directories = 0
        var bytes: Int64 = 0
        for record in snapshot.files.values {
            if record.isDirectory { directories += 1 } else { files += 1; bytes += record.size }
        }
        return TreeTotals(files: files, directories: directories, bytes: bytes)
    }

    public static func describe(_ event: ChangeEvent) -> String {
        switch event.kind {
        case .create:
            return "created" + (event.nodeKind == .file ? " — \(formatBytes(event.currentSize ?? 0))" : "")
        case .delete:
            return "deleted" + (event.nodeKind == .file ? " — was \(formatBytes(event.previousSize ?? 0))" : "")
        case .modify:
            var parts: [String] = []
            if let previous = event.previousSize, let now = event.currentSize, previous != now {
                let delta = now - previous
                parts.append("size \(formatBytes(previous)) → \(formatBytes(now)) (\(delta >= 0 ? "+" : "-")\(formatBytes(abs(delta))))")
            }
            if let kind = event.contentChangeKind, kind != .metadataOnly {
                switch kind {
                case .likelyEncrypted:
                    parts.append("likely encrypted")
                case .appended:
                    parts.append("appended to")
                case .truncated:
                    parts.append("truncated")
                case .contentRewritten:
                    parts.append("content changed")
                case .metadataOnly:
                    break
                }
                if let before = event.previousEntropy, let after = event.currentEntropy {
                    parts.append("entropy \(String(format: "%.1f", before)) → \(String(format: "%.1f", after)) bits/byte")
                }
            } else if event.contentChanged {
                parts.append("content changed")
            }
            return parts.isEmpty ? "metadata changed" : parts.joined(separator: ", ")
        case .rename:
            return "renamed from \(event.oldPath ?? "?")"
        case .move:
            return "moved from \(event.oldPath ?? "?")"
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func displayName(forRootPath path: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        if last.hasPrefix("ChangeLink-Demo-") { return "Demo Files" }
        return last.isEmpty ? path : last
    }

    // MARK: Tree assembly

    private struct Entry {
        let path: String
        let isDirectory: Bool
        let size: Int64?
        let status: NodeStatus
        let note: String?
        let ghost: Bool
        let history: [NodeChange]
    }

    private final class Builder {
        let name: String
        let path: String
        var isDirectory: Bool
        var status: NodeStatus = .unchanged
        var size: Int64?
        var note: String?
        var isGhost = false
        var history: [NodeChange] = []
        var children: [String: Builder] = [:]
        init(name: String, path: String, isDirectory: Bool) {
            self.name = name; self.path = path; self.isDirectory = isDirectory
        }
    }

    private static func assemble(rootName: String, entries: [Entry]) -> TreeNode {
        let root = Builder(name: rootName, path: "", isDirectory: true)
        for entry in entries {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var node = root
            var prefix = ""
            for (index, component) in components.enumerated() {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                let isLast = index == components.count - 1
                let child: Builder
                if let existing = node.children[component] {
                    child = existing
                } else {
                    child = Builder(name: component, path: prefix, isDirectory: !isLast || entry.isDirectory)
                    if !isLast && entry.ghost {
                        // A folder that exists only to hold a deleted item (it was since moved, renamed or
                        // deleted) is itself a ghost; otherwise it would look like a real folder.
                        child.isGhost = true
                        child.status = .deleted
                        child.note = "no longer at this path (moved, renamed or deleted)"
                    }
                    node.children[component] = child
                }
                if isLast {
                    child.isDirectory = entry.isDirectory
                    child.status = entry.status
                    child.size = entry.size
                    child.note = entry.note
                    child.isGhost = entry.ghost
                    child.history = entry.history
                } else {
                    child.isDirectory = true     // a parent of anything is a folder
                }
                node = child
            }
        }
        return finalize(root)
    }

    private static func finalize(_ builder: Builder) -> TreeNode {
        let kids = builder.children.values.map(finalize).sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        var descendants = 0
        var changed = 0
        for kid in kids {
            descendants += kid.descendantCount + 1
            changed += kid.changedDescendants + (kid.isTouched ? 1 : 0)
        }
        return TreeNode(id: builder.path, name: builder.name, isDirectory: builder.isDirectory,
                        status: builder.status, size: builder.size, note: builder.note,
                        isGhost: builder.isGhost, history: builder.history, children: kids,
                        descendantCount: descendants, changedDescendants: changed)
    }
}
