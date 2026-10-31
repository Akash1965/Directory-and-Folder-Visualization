import SwiftUI
import ChangeLinkCore

// MARK: - Styling

extension NodeStatus {
    var color: Color {
        switch self {
        case .created: return Color(red: 0.18, green: 0.78, blue: 0.37)
        case .deleted: return Color(red: 0.96, green: 0.27, blue: 0.30)
        case .modified: return Color(red: 1.00, green: 0.57, blue: 0.14)
        case .renamed, .moved: return Color(red: 0.79, green: 0.31, blue: 0.90)
        case .unchanged: return Color.gray
        }
    }

    /// A glyph so status is not conveyed by colour alone.
    var symbol: String {
        switch self {
        case .created: return "+"
        case .deleted: return "–"
        case .modified: return "~"
        case .renamed: return "R"
        case .moved: return "M"
        case .unchanged: return ""
        }
    }
}

extension ChangeKind {
    var nodeStatus: NodeStatus {
        switch self {
        case .create: return .created
        case .delete: return .deleted
        case .modify: return .modified
        case .rename: return .renamed
        case .move: return .moved
        }
    }
}

// MARK: - Layout (pure geometry, top-to-bottom tidy tree like a classic binary-tree diagram)

struct LaidOutNode: Identifiable {
    let node: TreeNode
    let cx: CGFloat      // circle centre
    let cy: CGFloat
    var id: String { node.id }
}

struct LaidOutEdge: Identifiable {
    let id: String
    let from: CGPoint    // parent circle centre
    let to: CGPoint      // child circle centre
    let status: NodeStatus
    let dashed: Bool
}

struct TreeLayoutResult {
    var nodes: [LaidOutNode] = []
    var edges: [LaidOutEdge] = []
    var size: CGSize = .zero
}

enum TreeLayout {
    static let circleDiameter: CGFloat = 52
    static let labelHeight: CGFloat = 32
    static let slotWidth: CGFloat = 104       // horizontal room per leaf
    static let levelHeight: CGFloat = 116     // vertical distance between levels
    static let margin: CGFloat = 16
    static var cellHeight: CGFloat { circleDiameter + 4 + labelHeight }

    /// Scale that makes the whole tree fit the viewport (never enlarged beyond 100%, never below 35%).
    static func fitScale(content: CGSize, viewport: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return max(0.35, min(1, viewport.width / content.width, viewport.height / content.height))
    }

    /// Only directories whose id is in `expanded` show their children.
    static func layout(root: TreeNode, expanded: Set<String>) -> TreeLayoutResult {
        var result = TreeLayoutResult()
        var nextColumn: CGFloat = 0
        var maxDepth = 0

        func place(_ node: TreeNode, depth: Int) -> CGFloat {
            maxDepth = max(maxDepth, depth)
            let cy = margin + CGFloat(depth) * levelHeight + circleDiameter / 2
            let visibleChildren = (node.isDirectory && expanded.contains(node.id)) ? node.children : []
            let cx: CGFloat
            if visibleChildren.isEmpty {
                cx = margin + nextColumn * slotWidth + slotWidth / 2
                nextColumn += 1
                result.nodes.append(LaidOutNode(node: node, cx: cx, cy: cy))
            } else {
                var childXs: [CGFloat] = []
                for child in visibleChildren { childXs.append(place(child, depth: depth + 1)) }
                cx = ((childXs.first ?? 0) + (childXs.last ?? 0)) / 2
                result.nodes.append(LaidOutNode(node: node, cx: cx, cy: cy))
                for (child, childX) in zip(visibleChildren, childXs) {
                    result.edges.append(LaidOutEdge(
                        id: node.id + "→" + child.id,
                        from: CGPoint(x: cx, y: cy),
                        to: CGPoint(x: childX, y: cy + levelHeight),
                        status: child.status,
                        dashed: child.isGhost))
                }
            }
            return cx
        }

        _ = place(root, depth: 0)
        result.size = CGSize(
            width: margin * 2 + max(nextColumn, 1) * slotWidth,
            height: margin * 2 + CGFloat(maxDepth) * levelHeight + cellHeight)
        return result
    }

    /// Root plus every folder that contains a change, so all changes are visible when the tree first appears.
    static func defaultExpanded(_ root: TreeNode) -> Set<String> {
        var ids: Set<String> = [root.id]
        func visit(_ node: TreeNode) {
            if node.isDirectory && node.changedDescendants > 0 { ids.insert(node.id) }
            node.children.forEach(visit)
        }
        visit(root)
        return ids
    }

    static func allDirectories(_ root: TreeNode) -> Set<String> {
        var ids: Set<String> = []
        func visit(_ node: TreeNode) {
            if node.isDirectory && !node.children.isEmpty { ids.insert(node.id) }
            node.children.forEach(visit)
        }
        visit(root)
        return ids
    }
}

// MARK: - Node view (circle with the name underneath)

struct TreeNodeCell: View {
    let node: TreeNode
    let isExpanded: Bool
    @State private var showHistory = false

    private static let plainFill = Color(red: 0.80, green: 0.89, blue: 0.98)   // light blue, as in the reference diagram
    private static let ink = Color(red: 0.10, green: 0.12, blue: 0.18)

    private var isChanged: Bool { node.status != .unchanged }
    private var canExpand: Bool { node.isDirectory && !node.children.isEmpty }
    private var fill: Color { isChanged ? node.status.color.opacity(0.35) : TreeNodeCell.plainFill }
    private var outline: Color { isChanged ? node.status.color : TreeNodeCell.ink }

    private var tooltip: String {
        var lines = [node.id.isEmpty ? node.name : node.id]
        if node.history.count > 1 {
            lines.append("\(node.history.count) modifications:")
            for change in node.history { lines.append("• " + TreeNodeCell.timeText(change.observedAt) + "  " + change.detail) }
        } else if let note = node.note {
            lines.append(note)
        }
        if let size = node.size, node.note == nil && node.history.isEmpty { lines.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if node.isDirectory && node.changedDescendants > 0 { lines.append("\(node.changedDescendants) change(s) inside") }
        if canExpand { lines.append(isExpanded ? "Click to collapse" : "Click to expand") }
        return lines.joined(separator: "\n")
    }

    static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(fill)
                Circle().strokeBorder(outline,
                                      style: StrokeStyle(lineWidth: isChanged ? 3 : 2.2,
                                                         dash: node.isGhost ? [5, 3] : []))
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(TreeNodeCell.ink.opacity(0.75))
            }
            .frame(width: TreeLayout.circleDiameter, height: TreeLayout.circleDiameter)
            .overlay(alignment: .topTrailing) {
                if isChanged {
                    Text(node.status.symbol)
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(node.status.color))
                        .offset(x: 6, y: -6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !node.history.isEmpty {
                    Text("×\(node.history.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(Capsule().fill(Color(red: 0.20, green: 0.35, blue: 0.80)))
                        .offset(x: -8, y: 6)
                        .onTapGesture { showHistory = true }
                        .help("Click to list every modification of this item")
                        .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                            NodeHistoryView(name: node.name.isEmpty ? "/" : node.name, history: node.history)
                        }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if canExpand && !isExpanded {
                    Text("+\(node.descendantCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(Capsule().fill(Color.gray))
                        .offset(x: 8, y: 6)
                }
            }
            Text(node.name)
                .font(.system(size: 11, weight: isChanged ? .bold : .regular))
                .strikethrough(node.status == .deleted)
                .foregroundStyle(isChanged ? node.status.color : Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: TreeLayout.slotWidth - 8, height: TreeLayout.labelHeight, alignment: .top)
        }
        .frame(width: TreeLayout.slotWidth, height: TreeLayout.cellHeight, alignment: .top)
        .opacity(node.isGhost ? 0.8 : 1)
        .contentShape(Rectangle())
        .help(tooltip)
    }
}

struct NodeHistoryView: View {
    let name: String
    let history: [NodeChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(name) — \(history.count) modification(s)").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(history.enumerated()), id: \.offset) { index, change in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                            Text(change.kind.rawValue.uppercased())
                                .font(.caption2.bold())
                                .frame(width: 62)
                                .padding(.vertical, 2)
                                .foregroundStyle(change.kind.nodeStatus.color)
                                .background(change.kind.nodeStatus.color.opacity(0.16), in: Capsule())
                            Text(TreeNodeCell.timeText(change.observedAt)).font(.caption).foregroundStyle(.secondary)
                            Text(change.detail).font(.caption)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 380, maxWidth: 520, maxHeight: 320)
    }
}

// MARK: - One tree (nodes + edges), expandable at every node

struct TreePane: View {
    let title: String
    let subtitle: String
    let root: TreeNode
    /// Expansion state is owned by the parent so the Original and Modified trees stay in sync.
    let expanded: Set<String>
    let onToggle: (TreeNode) -> Void
    let onExpandAll: () -> Void
    let onCollapseAll: () -> Void

    /// nil = fit the whole tree into the pane; otherwise a manual zoom factor.
    @State private var manualZoom: CGFloat?
    @State private var lastFit: CGFloat = 1

    private func currentScale() -> CGFloat {
        manualZoom ?? lastFit
    }
    private func zoomIn() { manualZoom = min(1.6, currentScale() * 1.25) }
    private func zoomOut() { manualZoom = max(0.3, currentScale() * 0.8) }

    var body: some View {
        let currentExpanded = expanded
        let layout = TreeLayout.layout(root: root, expanded: currentExpanded)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.borderless).help("Zoom out")
                Button("Fit") { manualZoom = nil }
                    .buttonStyle(.borderless).help("Fit the whole tree into this pane")
                Button { zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.borderless).help("Zoom in")
                Button("Expand all", action: onExpandAll)
                    .buttonStyle(.borderless)
                Button("Collapse all", action: onCollapseAll)
                    .buttonStyle(.borderless)
            }
            GeometryReader { proxy in
              let fit = TreeLayout.fitScale(content: layout.size, viewport: proxy.size)
              let scale = manualZoom ?? fit
              ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        let radius = TreeLayout.circleDiameter / 2
                        for edge in layout.edges {
                            let dx = edge.to.x - edge.from.x
                            let dy = edge.to.y - edge.from.y
                            let length = max((dx * dx + dy * dy).squareRoot(), 1)
                            let ux = dx / length
                            let uy = dy / length
                            var path = Path()
                            path.move(to: CGPoint(x: edge.from.x + ux * radius, y: edge.from.y + uy * radius))
                            path.addLine(to: CGPoint(x: edge.to.x - ux * radius, y: edge.to.y - uy * radius))
                            let colour: Color = edge.status == .unchanged
                                ? Color.primary.opacity(0.75)
                                : edge.status.color
                            context.stroke(path, with: .color(colour),
                                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round,
                                                              dash: edge.dashed ? [6, 4] : []))
                        }
                    }
                    .frame(width: layout.size.width, height: layout.size.height)

                    ForEach(layout.nodes) { laidOut in
                        TreeNodeCell(node: laidOut.node, isExpanded: currentExpanded.contains(laidOut.node.id))
                            .position(x: laidOut.cx,
                                      y: laidOut.cy - TreeLayout.circleDiameter / 2 + TreeLayout.cellHeight / 2)
                            .onTapGesture { onToggle(laidOut.node) }
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
              }
              .onAppear { lastFit = fit }
              .onChange(of: fit) { _ in lastFit = fit }
            }
            .frame(height: 400)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Original | Modified for one directory

struct RootDiffSection: View {
    let diff: RootDiff

    /// nil means "default": the root plus every folder containing a change, in either tree.
    @State private var expandedOverride: Set<String>?

    private var expanded: Set<String> {
        expandedOverride ?? TreeLayout.defaultExpanded(diff.original).union(TreeLayout.defaultExpanded(diff.modified))
    }

    /// Clicking a node in either tree expands or collapses the node with the same path in both trees.
    private func toggle(_ node: TreeNode) {
        guard node.isDirectory && !node.children.isEmpty else { return }
        var set = expanded
        if set.contains(node.id) { set.remove(node.id) } else { set.insert(node.id) }
        expandedOverride = set
    }

    private func expandAll() {
        expandedOverride = TreeLayout.allDirectories(diff.original).union(TreeLayout.allDirectories(diff.modified))
    }

    private func collapseAll() {
        expandedOverride = [diff.original.id]
    }

    private func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                Text(diff.rootName).font(.title3.bold())
                Text(diff.rootPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(diff.summary.total == 0 ? "No changes" : "\(diff.summary.total) change(s)")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((diff.summary.total == 0 ? Color.gray : Color.accentColor).opacity(0.15), in: Capsule())
            }
            HStack(alignment: .top, spacing: 10) {
                TreePane(title: "Original", subtitle: "Baseline · \(stamp(diff.baselineTakenAt))", root: diff.original,
                         expanded: expanded, onToggle: toggle, onExpandAll: expandAll, onCollapseAll: collapseAll)
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 150)
                TreePane(title: "Modified", subtitle: "After interval · \(stamp(diff.currentTakenAt))", root: diff.modified,
                         expanded: expanded, onToggle: toggle, onExpandAll: expandAll, onCollapseAll: collapseAll)
            }
        }
    }
}

// MARK: - Summary of all changes

struct SummaryPanel: View {
    let diffs: [RootDiff]
    @Binding var selectedEvent: ChangeEvent?
    @State private var showImplied = false

    private var totals: [ChangeKind: Int] {
        var result: [ChangeKind: Int] = [:]
        for diff in diffs { for (kind, count) in diff.summary.counts { result[kind, default: 0] += count } }
        return result
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    var body: some View {
        let totalCount = totals.values.reduce(0, +)
        let impliedTotal = diffs.reduce(0) { $0 + $1.summary.impliedCount }
        let itemTotal = diffs.reduce(0) { $0 + $1.summary.itemCount }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Summary of changes").font(.title2.bold())
                Text("\(totalCount) modification(s) on \(itemTotal) item(s)").font(.body.bold()).foregroundStyle(.secondary)
                Spacer()
                ForEach(ChangeKind.allCases, id: \.self) { kind in
                    let n = totals[kind] ?? 0
                    Text("\(kind.rawValue.capitalized) \(n)")
                        .font(.body.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(kind.nodeStatus.color)
                        .background(kind.nodeStatus.color.opacity(n == 0 ? 0.05 : 0.16), in: Capsule())
                        .opacity(n == 0 ? 0.5 : 1)
                }
            }
            if impliedTotal > 0 {
                Toggle("Also list \(impliedTotal) item(s) that only moved because their parent folder moved",
                       isOn: $showImplied)
                    .font(.callout)
                    .toggleStyle(.checkbox)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let event = selectedEvent {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Selected change").font(.title3.bold())
                                    Spacer()
                                    Button("Close") { selectedEvent = nil }.buttonStyle(.borderless)
                                }
                                ChangeDetailView(event: event)
                                    .frame(height: 230)
                            }
                        }
                    }
                    if diffs.isEmpty {
                        Text("Nothing to summarise yet.").foregroundStyle(.secondary)
                    }
                    ForEach(diffs) { diff in
                        RootSummaryView(diff: diff, showImplied: showImplied, selectedEvent: $selectedEvent)
                            .padding(.bottom, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}


// MARK: - Summary of one monitored folder

struct MetricRow: Identifiable {
    let id: String          // metric name
    let original: String
    let modified: String
    let delta: String
}

struct RootSummaryView: View {
    let diff: RootDiff
    let showImplied: Bool
    @Binding var selectedEvent: ChangeEvent?
    @State private var collapsed: Set<ChangeKind> = []

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    private func signedInt(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
    private func signedDouble(_ value: Double) -> String { String(format: "%+.2f", value) }
    private func signedBytes(_ value: Int64) -> String { (value >= 0 ? "+" : "-") + bytes(abs(value)) }
    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    private func title(_ kind: ChangeKind) -> String {
        switch kind {
        case .create: return "Created"
        case .delete: return "Deleted"
        case .modify: return "Modified"
        case .rename: return "Renamed"
        case .move: return "Moved"
        }
    }

    private var metricRows: [MetricRow] {
        let o = diff.comparison.original
        let m = diff.comparison.modified
        func whole(_ name: String, _ a: Int, _ b: Int) -> MetricRow {
            MetricRow(id: name, original: "\(a)", modified: "\(b)", delta: signedInt(b - a))
        }
        func fraction(_ name: String, _ a: Double, _ b: Double) -> MetricRow {
            MetricRow(id: name, original: String(format: "%.2f", a), modified: String(format: "%.2f", b), delta: signedDouble(b - a))
        }
        return [
            whole("Total nodes (incl. root)", o.nodes, m.nodes),
            whole("Files", o.files, m.files),
            whole("Folders", o.directories, m.directories),
            whole("Leaf nodes", o.leaves, m.leaves),
            whole("Depth (height, root = 0)", o.height, m.height),
            fraction("Average node depth", o.averageDepth, m.averageDepth),
            whole("Widest level (nodes)", o.maxWidth, m.maxWidth),
            whole("Widest level (at depth)", o.widestLevel, m.widestLevel),
            whole("Max fan-out", o.maxFanOut, m.maxFanOut),
            fraction("Average branching factor", o.averageBranching, m.averageBranching),
            MetricRow(id: "Total file size", original: bytes(o.bytes), modified: bytes(m.bytes), delta: signedBytes(m.bytes - o.bytes)),
            MetricRow(id: "Average file size", original: bytes(Int64(o.averageFileSize)), modified: bytes(Int64(m.averageFileSize)),
                      delta: signedBytes(Int64(m.averageFileSize) - Int64(o.averageFileSize)))
        ]
    }

    private func expandedBinding(_ kind: ChangeKind) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(kind) },
                set: { open in
                    if open { collapsed.remove(kind) } else { collapsed.insert(kind) }
                })
    }

    var body: some View {
        let summary = diff.summary
        let comparison = diff.comparison
        VStack(alignment: .leading, spacing: 8) {
            Text("\(diff.rootName)  ·  \(diff.rootPath)")
                .font(.title3.bold())
                .lineLimit(1)
                .truncationMode(.middle)

            // Original versus now.
            GroupBox {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Originally (baseline \(ChangeStamp.text(diff.baselineTakenAt))): \(summary.before.files) files and \(summary.before.directories) folders, \(bytes(summary.before.bytes))")
                    Text("Now (\(ChangeStamp.text(diff.currentTakenAt))): \(summary.after.files) files and \(summary.after.directories) folders, \(bytes(summary.after.bytes)) (\(signedBytes(summary.byteDelta)))")
                    Text("During monitoring: \(summary.counts[.create] ?? 0) created, \(summary.counts[.delete] ?? 0) deleted, \(summary.counts[.modify] ?? 0) modified, \(summary.counts[.rename] ?? 0) renamed, \(summary.counts[.move] ?? 0) moved  ·  \(summary.total) modification(s) on \(summary.itemCount) item(s)")
                        .fontWeight(.semibold)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Tree-versus-tree metrics.
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Original tree vs modified tree").font(.body.bold())
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
                        GridRow {
                            Text("Metric").bold()
                            Text("Original").bold().gridColumnAlignment(.trailing)
                            Text("Modified").bold().gridColumnAlignment(.trailing)
                            Text("Change").bold().gridColumnAlignment(.trailing)
                        }
                        Divider()
                        ForEach(metricRows) { row in
                            GridRow {
                                Text(row.id)
                                Text(row.original).monospacedDigit()
                                Text(row.modified).monospacedDigit()
                                Text(row.delta).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.callout)

                    Text("Nodes per level").font(.body.bold()).padding(.top, 4)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
                        GridRow {
                            Text("Level").bold()
                            Text("Original").bold().gridColumnAlignment(.trailing)
                            Text("Modified").bold().gridColumnAlignment(.trailing)
                            Text("Change").bold().gridColumnAlignment(.trailing)
                        }
                        Divider()
                        ForEach(comparison.levelRows) { row in
                            GridRow {
                                Text(row.depth == 0 ? "0 (root)" : "\(row.depth)")
                                Text("\(row.original)").monospacedDigit()
                                Text("\(row.modified)").monospacedDigit()
                                Text(signedInt(row.delta)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.callout)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Path similarity (Jaccard): \(percent(comparison.pathSimilarity)) — \(comparison.commonPaths) paths in common out of \(comparison.unionPaths) in either tree")
                        Text("Structural edit operations: \(comparison.structuralOperations) (\(comparison.createdCount) create, \(comparison.deletedCount) delete, \(comparison.renamedCount) rename, \(comparison.movedCount) move)  ·  content modifications: \(comparison.contentModifications)")
                        Text("Items touched: \(summary.itemCount) (\(percent(comparison.touchedRatio)) of the larger tree)  ·  deepest change at level \(comparison.deepestChangeDepth < 0 ? "none" : String(comparison.deepestChangeDepth))")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Items under each change category, with timestamps.
            ForEach(ChangeKind.allCases, id: \.self) { kind in
                let rows = summary.entries(of: kind, includeImplied: showImplied)
                if !rows.isEmpty {
                    DisclosureGroup(isExpanded: expandedBinding(kind)) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(rows) { entry in
                                Button { selectedEvent = entry.event } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: entry.event.nodeKind == .directory ? "folder" : "doc")
                                            .foregroundStyle(.secondary)
                                        Text(entry.event.path)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .layoutPriority(1)
                                        if let changeKind = entry.event.contentChangeKind, changeKind != .metadataOnly {
                                            Text(changeKind.label.uppercased())
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .foregroundStyle(changeKind == .likelyEncrypted ? .red : .secondary)
                                                .background((changeKind == .likelyEncrypted ? Color.red : Color.gray).opacity(0.15), in: Capsule())
                                            if let before = entry.event.previousEntropy, let after = entry.event.currentEntropy {
                                                Text("H \(String(format: "%.1f", before))→\(String(format: "%.1f", after))")
                                                    .font(.callout.monospacedDigit())
                                                    .foregroundStyle(changeKind == .likelyEncrypted ? .red : .secondary)
                                            }
                                        }
                                        Text(ChangeStamp.text(entry.event.observedAt))
                                            .font(.callout.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Text(entry.detail)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                            }
                        }
                        .padding(.top, 3)
                    } label: {
                        HStack(spacing: 6) {
                            Text(title(kind))
                                .font(.body.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .foregroundStyle(kind.nodeStatus.color)
                                .background(kind.nodeStatus.color.opacity(0.16), in: Capsule())
                            Text("\(rows.count) \(rows.count == 1 ? "entry" : "entries")")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if summary.total == 0 {
                Text("No changes since the baseline.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
