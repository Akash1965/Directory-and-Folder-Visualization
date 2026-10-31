import Foundation

// MARK: - Timestamps

/// One formatting rule for every timestamp the app shows: local time with millisecond precision.
public enum ChangeStamp {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func text(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

// MARK: - Per-tree metrics

/// Structural measurements of one directory tree. Ghost nodes (items drawn only to show a deletion)
/// are ignored, so the numbers describe the folder as it really was or is.
/// The root folder is level 0 and counts as a node, but not as a file or a folder.
public struct TreeMetrics: Equatable, Sendable {
    public let nodes: Int              // every node including the root
    public let files: Int
    public let directories: Int        // sub-folders only (the root is not counted)
    public let leaves: Int             // nodes without children (files and empty folders)
    public let height: Int             // depth of the deepest node, root = 0
    public let averageDepth: Double    // mean depth of all nodes except the root
    public let levels: [Int]           // levels[d] = number of nodes at depth d
    public let maxWidth: Int           // size of the widest level
    public let widestLevel: Int        // depth at which that widest level sits
    public let maxFanOut: Int          // most children of any single node
    public let averageBranching: Double // mean number of children of nodes that have children
    public let bytes: Int64
    public let averageFileSize: Double

    public static func measure(_ root: TreeNode) -> TreeMetrics {
        var levels: [Int] = []
        var files = 0, directories = 0, leaves = 0
        var internalNodes = 0, childEdges = 0, maxFan = 0
        var depthSum = 0
        var bytes: Int64 = 0

        var stack: [(node: TreeNode, depth: Int)] = [(root, 0)]
        while let item = stack.popLast() {
            let node = item.node
            let depth = item.depth
            if levels.count <= depth { levels.append(0) }
            levels[depth] += 1

            if depth > 0 {
                depthSum += depth
                if node.isDirectory {
                    directories += 1
                } else {
                    files += 1
                    bytes += node.size ?? 0
                }
            }
            let kids = node.children.filter { !$0.isGhost }
            if kids.isEmpty {
                leaves += 1
            } else {
                internalNodes += 1
                childEdges += kids.count
                maxFan = max(maxFan, kids.count)
            }
            for kid in kids { stack.append((kid, depth + 1)) }
        }

        let nodes = levels.reduce(0, +)
        var widest = 0
        for (depth, count) in levels.enumerated() where count > levels[widest] { widest = depth }
        return TreeMetrics(
            nodes: nodes, files: files, directories: directories, leaves: leaves,
            height: max(levels.count - 1, 0),
            averageDepth: nodes > 1 ? Double(depthSum) / Double(nodes - 1) : 0,
            levels: levels,
            maxWidth: levels.max() ?? 0,
            widestLevel: widest,
            maxFanOut: maxFan,
            averageBranching: internalNodes > 0 ? Double(childEdges) / Double(internalNodes) : 0,
            bytes: bytes,
            averageFileSize: files > 0 ? Double(bytes) / Double(files) : 0)
    }
}

// MARK: - Comparison of the two trees

public struct LevelRow: Equatable, Sendable, Identifiable {
    public let depth: Int
    public let original: Int
    public let modified: Int
    public var delta: Int { modified - original }
    public var id: Int { depth }
}

/// Side-by-side comparison of the original and the modified tree.
public struct TreeComparison: Equatable, Sendable {
    public let original: TreeMetrics
    public let modified: TreeMetrics
    /// Nodes per level in both trees, so level-by-level growth or shrinkage is visible.
    public let levelRows: [LevelRow]
    /// Paths present in both trees / in either tree (root excluded).
    public let commonPaths: Int
    public let unionPaths: Int
    /// Jaccard similarity of the two path sets: |A ∩ B| / |A ∪ B|, 1.0 for identical structure.
    public let pathSimilarity: Double
    /// Structural edit operations: created + deleted + renamed + moved. A renamed or moved folder counts as
    /// one operation because its subtree travels with it. Exact tree edit distance (Zhang and Shasha, 1989)
    /// has no move operation and is expensive on large trees, so this operation count is used instead.
    public let structuralOperations: Int
    public let createdCount: Int
    public let deletedCount: Int
    public let renamedCount: Int
    public let movedCount: Int
    /// Items whose content or metadata changed (the "modify" events).
    public let contentModifications: Int
    /// Distinct items touched, as a share of the larger tree (root excluded).
    public let touchedRatio: Double
    /// Depth of the deepest item that was changed in either tree; -1 when nothing changed.
    public let deepestChangeDepth: Int

    public static func make(original: TreeNode, modified: TreeNode,
                            counts: [ChangeKind: Int], touchedItems: Int) -> TreeComparison {
        let before = TreeMetrics.measure(original)
        let after = TreeMetrics.measure(modified)

        var rows: [LevelRow] = []
        for depth in 0..<max(before.levels.count, after.levels.count) {
            rows.append(LevelRow(depth: depth,
                                 original: depth < before.levels.count ? before.levels[depth] : 0,
                                 modified: depth < after.levels.count ? after.levels[depth] : 0))
        }

        let a = realPaths(original)
        let b = realPaths(modified)
        let common = a.intersection(b).count
        let union = a.union(b).count

        let created = counts[.create] ?? 0
        let deleted = counts[.delete] ?? 0
        let renamed = counts[.rename] ?? 0
        let moved = counts[.move] ?? 0
        let larger = max(a.count, b.count)

        var deepest = -1
        for tree in [original, modified] {
            deepest = max(deepest, deepestTouched(tree, depth: 0))
        }

        return TreeComparison(
            original: before, modified: after, levelRows: rows,
            commonPaths: common, unionPaths: union,
            pathSimilarity: union == 0 ? 1 : Double(common) / Double(union),
            structuralOperations: created + deleted + renamed + moved,
            createdCount: created, deletedCount: deleted, renamedCount: renamed, movedCount: moved,
            contentModifications: counts[.modify] ?? 0,
            touchedRatio: larger == 0 ? 0 : Double(touchedItems) / Double(larger),
            deepestChangeDepth: deepest)
    }

    private static func realPaths(_ root: TreeNode) -> Set<String> {
        var result = Set<String>()
        var stack = root.children.filter { !$0.isGhost }
        while let node = stack.popLast() {
            result.insert(node.id)
            stack.append(contentsOf: node.children.filter { !$0.isGhost })
        }
        return result
    }

    private static func deepestTouched(_ node: TreeNode, depth: Int) -> Int {
        var best = (depth > 0 && node.isTouched) ? depth : -1
        for child in node.children { best = max(best, deepestTouched(child, depth: depth + 1)) }
        return best
    }
}

// MARK: - Summary helpers

extension ChangeSummary {
    /// Every modification of one kind, oldest first.
    public func entries(of kind: ChangeKind, includeImplied: Bool) -> [SummaryEntry] {
        entries
            .filter { $0.event.kind == kind && (includeImplied || !$0.isImplied) }
            .sorted {
                $0.event.observedAt != $1.event.observedAt
                    ? $0.event.observedAt < $1.event.observedAt
                    : $0.event.path < $1.event.path
            }
    }
}
