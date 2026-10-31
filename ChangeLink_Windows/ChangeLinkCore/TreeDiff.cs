using System;
using System.Collections.Generic;
using System.Linq;

namespace ChangeLinkCore
{
    /// <summary>Visual/semantic status of one node in the Modified tree (the Original tree never
    /// uses anything but <see cref="Unchanged"/> -- it shows the baseline structure only).</summary>
    public enum NodeStatus
    {
        Unchanged,
        Created,
        Deleted,
        Modified,
        Renamed,
        Moved
    }

    /// <summary>One historical modification of a single node, as shown in its history list / popover.</summary>
    public sealed class NodeChange
    {
        public ChangeKind Kind { get; }
        public DateTime ObservedAt { get; }
        public string Detail { get; }

        public NodeChange(ChangeKind kind, DateTime observedAt, string detail)
        {
            Kind = kind;
            ObservedAt = observedAt;
            Detail = detail;
        }
    }

    /// <summary>One node of the Original or Modified tree.</summary>
    public sealed class TreeNode
    {
        /// <summary>Relative path below the monitored root ("" for the root itself).</summary>
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public bool IsDirectory { get; set; }
        public long? Size { get; set; }
        public NodeStatus Status { get; set; } = NodeStatus.Unchanged;
        /// <summary>Drawn with a dashed outline: the item no longer exists at this path.</summary>
        public bool IsGhost { get; set; }
        public string? Note { get; set; }
        public List<NodeChange> History { get; set; } = new();
        public List<TreeNode> Children { get; set; } = new();
        /// <summary>Number of descendants (inclusive of self) that are not <see cref="NodeStatus.Unchanged"/>.</summary>
        public int ChangedDescendants { get; set; }
        public bool IsTouched => Status != NodeStatus.Unchanged || History.Count > 0;
    }

    public sealed class SummaryEntry
    {
        public ChangeEvent Event { get; }
        public string Detail { get; }
        public bool IsImplied { get; }

        public SummaryEntry(ChangeEvent @event, string detail, bool isImplied)
        {
            Event = @event;
            Detail = detail;
            IsImplied = isImplied;
        }
    }

    public sealed class TreeTotals
    {
        public int Files { get; init; }
        public int Directories { get; init; }
        public long Bytes { get; init; }
    }

    /// <summary>Counts, per-kind entries and totals shown in the summary panel. Built from the
    /// full accumulated change log for a root, not just the latest baseline/current diff, so a
    /// file modified three times keeps three separate entries.</summary>
    public sealed class ChangeSummary
    {
        public List<SummaryEntry> Entries { get; }
        public Dictionary<ChangeKind, int> Counts { get; }
        public int ItemCount { get; }
        public int ImpliedCount { get; }
        public TreeTotals Before { get; }
        public TreeTotals After { get; }

        public long ByteDelta => After.Bytes - Before.Bytes;
        public int Total => Counts.Values.Sum();

        public ChangeSummary(List<SummaryEntry> entries, Dictionary<ChangeKind, int> counts, int itemCount, int impliedCount, TreeTotals before, TreeTotals after)
        {
            Entries = entries;
            Counts = counts;
            ItemCount = itemCount;
            ImpliedCount = impliedCount;
            Before = before;
            After = after;
        }

        /// <summary>Every modification of one kind, oldest first.</summary>
        public List<SummaryEntry> EntriesOf(ChangeKind kind, bool includeImplied)
        {
            return Entries
                .Where(e => e.Event.Kind == kind && (includeImplied || !e.IsImplied))
                .OrderBy(e => e.Event.ObservedAt)
                .ThenBy(e => e.Event.Path, StringComparer.Ordinal)
                .ToList();
        }
    }

    public sealed class RootDiff
    {
        public string RootName { get; init; } = "";
        public string RootPath { get; init; } = "";
        public TreeNode Original { get; init; } = null!;
        public TreeNode Modified { get; init; } = null!;
        public ChangeSummary Summary { get; init; } = null!;
        public TreeComparison Comparison { get; init; } = null!;
        public DateTime BaselineTakenAt { get; init; }
        public DateTime CurrentTakenAt { get; init; }
    }

    /// <summary>
    /// Builds the Original and Modified trees and the change summary for one monitored root.
    /// A direct port of the macOS build's <c>DirectoryTreeDiff</c> (Algorithm 3 in the report):
    /// the Original tree always shows the baseline structure with no change marks; the Modified
    /// tree shows every current item's net status plus a ghost node for anything deleted since
    /// the baseline; every node's history is pulled from the whole accumulated change log, not
    /// just the latest scan-to-scan diff.
    /// </summary>
    public static class DirectoryTreeDiff
    {
        private readonly struct Entry
        {
            public readonly string Path;
            public readonly bool IsDirectory;
            public readonly long? Size;
            public readonly NodeStatus Status;
            public readonly List<NodeChange> History;
            public readonly bool IsGhost;

            public Entry(string path, bool isDirectory, long? size, NodeStatus status, List<NodeChange> history, bool isGhost)
            {
                Path = path; IsDirectory = isDirectory; Size = size; Status = status; History = history; IsGhost = isGhost;
            }
        }

        public static RootDiff Build(
            string rootPath, Snapshot baseline, Snapshot current, List<ChangeEvent> changeLog,
            DateTime baselineTakenAt, DateTime currentTakenAt)
        {
            var netEvents = SnapshotComparator.Compare(baseline, current);
            var netStatusByNewPath = new Dictionary<string, NodeStatus>();
            var netDeletes = new List<ChangeEvent>();
            foreach (var e in netEvents)
            {
                switch (e.Kind)
                {
                    case ChangeKind.Create: netStatusByNewPath[e.Path] = NodeStatus.Created; break;
                    case ChangeKind.Modify: netStatusByNewPath[e.Path] = NodeStatus.Modified; break;
                    case ChangeKind.Rename: netStatusByNewPath[e.Path] = NodeStatus.Renamed; break;
                    case ChangeKind.Move: netStatusByNewPath[e.Path] = NodeStatus.Moved; break;
                    case ChangeKind.Delete: netDeletes.Add(e); break;
                }
            }

            // --- History index over the FULL accumulated change log for this root ---
            var byFileId = new Dictionary<string, List<ChangeEvent>>();
            var byPath = new Dictionary<string, List<ChangeEvent>>();
            foreach (var e in changeLog)
            {
                AddTo(byFileId, e.FileId, e);
                AddTo(byPath, e.Path, e);
                if (e.OldPath != null) AddTo(byPath, e.OldPath, e);
            }

            List<NodeChange> History(string fileId, string path)
            {
                var seen = new HashSet<string>();
                var collected = new List<ChangeEvent>();
                var candidates = (byFileId.TryGetValue(fileId, out var a) ? a : new List<ChangeEvent>())
                    .Concat(byPath.TryGetValue(path, out var b) ? b : new List<ChangeEvent>());
                foreach (var e in candidates)
                {
                    var key = $"{e.Kind}|{e.OldPath ?? ""}|{e.Path}|{e.ObservedAt.Ticks}";
                    if (seen.Add(key)) collected.Add(e);
                }
                collected.Sort((x, y) => x.ObservedAt != y.ObservedAt
                    ? x.ObservedAt.CompareTo(y.ObservedAt)
                    : string.CompareOrdinal(x.Path, y.Path));
                return collected.Select(e => new NodeChange(e.Kind, e.ObservedAt, Describe(e))).ToList();
            }

            // --- Original tree: baseline structure only, no change marks ---
            var originalEntries = baseline.Files.Select(kv => new Entry(kv.Key, kv.Value.IsDirectory, kv.Value.IsDirectory ? null : kv.Value.Size,
                NodeStatus.Unchanged, new List<NodeChange>(), false)).ToList();
            var rootName = string.IsNullOrEmpty(rootPath) ? "/" : System.IO.Path.GetFileName(rootPath.TrimEnd('/', '\\'));
            var originalRoot = Assemble(rootName, originalEntries, explicitPaths: null);

            // --- Modified tree: current items with net status + ghost nodes for deletions ---
            var explicitPaths = new HashSet<string>();
            var modifiedEntries = new List<Entry>();
            foreach (var kv in current.Files)
            {
                var path = kv.Key; var rec = kv.Value;
                var status = netStatusByNewPath.TryGetValue(path, out var s) ? s : NodeStatus.Unchanged;
                modifiedEntries.Add(new Entry(path, rec.IsDirectory, rec.IsDirectory ? null : rec.Size, status, History(rec.FileId, path), false));
                explicitPaths.Add(path);
            }
            foreach (var del in netDeletes)
            {
                if (current.Files.ContainsKey(del.Path)) continue; // shouldn't happen, but be safe
                modifiedEntries.Add(new Entry(del.Path, del.NodeKind == NodeKind.Directory, del.PreviousSize,
                    NodeStatus.Deleted, History(del.FileId, del.Path), true));
                explicitPaths.Add(del.Path);
            }
            var modifiedRoot = Assemble(rootName, modifiedEntries, explicitPaths);

            // --- Summary over the whole accumulated change log ---
            var moveByNewPath = new Dictionary<string, ChangeEvent>();
            foreach (var e in changeLog)
                if (e.Kind == ChangeKind.Rename || e.Kind == ChangeKind.Move) moveByNewPath[e.Path] = e;

            var entries = new List<SummaryEntry>();
            var counts = new Dictionary<ChangeKind, int>();
            int implied = 0;
            var items = new HashSet<string>();
            foreach (var e in changeLog)
            {
                bool isImplied = false;
                if ((e.Kind == ChangeKind.Rename || e.Kind == ChangeKind.Move) && e.OldPath != null &&
                    moveByNewPath.TryGetValue(SnapshotComparator.ParentPath(e.Path), out var parentEvent) &&
                    parentEvent.OldPath == SnapshotComparator.ParentPath(e.OldPath))
                {
                    isImplied = true;
                }
                entries.Add(new SummaryEntry(e, Describe(e), isImplied));
                if (isImplied) implied++;
                else { counts[e.Kind] = counts.GetValueOrDefault(e.Kind) + 1; items.Add(e.FileId); }
            }
            entries.Sort((x, y) => x.Event.Path != y.Event.Path
                ? string.CompareOrdinal(x.Event.Path, y.Event.Path)
                : x.Event.ObservedAt.CompareTo(y.Event.ObservedAt));

            var summary = new ChangeSummary(entries, counts, items.Count, implied, Totals(baseline), Totals(current));
            var comparison = TreeComparison.Make(originalRoot, modifiedRoot, counts, items.Count);

            return new RootDiff
            {
                RootName = rootName,
                RootPath = rootPath,
                Original = originalRoot,
                Modified = modifiedRoot,
                Summary = summary,
                Comparison = comparison,
                BaselineTakenAt = baselineTakenAt,
                CurrentTakenAt = currentTakenAt
            };
        }

        private static TreeTotals Totals(Snapshot snapshot)
        {
            int files = 0, dirs = 0; long bytes = 0;
            foreach (var r in snapshot.Files.Values)
            {
                if (r.IsDirectory) dirs++;
                else { files++; bytes += r.Size; }
            }
            return new TreeTotals { Files = files, Directories = dirs, Bytes = bytes };
        }

        private static void AddTo(Dictionary<string, List<ChangeEvent>> map, string key, ChangeEvent e)
        {
            if (!map.TryGetValue(key, out var list)) { list = new List<ChangeEvent>(); map[key] = list; }
            list.Add(e);
        }

        /// <summary>
        /// Builds a tree from a flat list of (path, metadata) entries, creating intermediate
        /// folder nodes as needed. When <paramref name="explicitPaths"/> is given (the Modified
        /// tree only), any folder node synthesized purely to hold a later-deleted/renamed/moved
        /// descendant -- i.e. a path that is not itself in <paramref name="explicitPaths"/> -- is
        /// marked as a ghost too, so a phantom solid folder never appears for a path that no
        /// longer really exists.
        /// </summary>
        private static TreeNode Assemble(string rootName, List<Entry> entries, HashSet<string>? explicitPaths)
        {
            var root = new TreeNode { Id = "", Name = rootName, IsDirectory = true, Status = NodeStatus.Unchanged };
            var byId = new Dictionary<string, TreeNode> { [""] = root };

            TreeNode EnsureFolder(string path)
            {
                if (byId.TryGetValue(path, out var existing)) return existing;
                string parent = SnapshotComparator.ParentPath(path);
                var parentNode = EnsureFolder(parent);
                var node = new TreeNode { Id = path, Name = System.IO.Path.GetFileName(path), IsDirectory = true, Status = NodeStatus.Unchanged };
                parentNode.Children.Add(node);
                byId[path] = node;
                return node;
            }

            foreach (var entry in entries.OrderBy(e => e.Path, StringComparer.Ordinal))
            {
                string parent = SnapshotComparator.ParentPath(entry.Path);
                var parentNode = EnsureFolder(parent);
                var node = byId.TryGetValue(entry.Path, out var pre) ? pre : new TreeNode { Id = entry.Path, Name = System.IO.Path.GetFileName(entry.Path) };
                node.IsDirectory = entry.IsDirectory;
                node.Size = entry.Size;
                node.Status = entry.Status;
                node.History = entry.History;
                node.IsGhost = entry.IsGhost;
                if (!byId.ContainsKey(entry.Path)) { parentNode.Children.Add(node); byId[entry.Path] = node; }
            }

            if (explicitPaths != null)
            {
                foreach (var kv in byId)
                {
                    if (kv.Key.Length == 0) continue; // root
                    if (kv.Value.IsDirectory && !explicitPaths.Contains(kv.Key) && !kv.Value.IsGhost)
                    {
                        kv.Value.IsGhost = true;
                        kv.Value.Status = NodeStatus.Deleted;
                        kv.Value.Note = "no longer at this path (moved, renamed or deleted)";
                    }
                }
            }

            // Sort children (folders first, then natural order) and roll up ChangedDescendants bottom-up.
            void Finish(TreeNode node)
            {
                node.Children.Sort((a, b) =>
                {
                    if (a.IsDirectory != b.IsDirectory) return a.IsDirectory ? -1 : 1;
                    return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
                });
                int changed = node.IsTouched ? 1 : 0;
                foreach (var child in node.Children) { Finish(child); changed += child.ChangedDescendants; }
                node.ChangedDescendants = changed;
            }
            Finish(root);

            return root;
        }

        /// <summary>Human-readable detail text for one change event, including its modification-type
        /// classification and before/after entropy when available.</summary>
        public static string Describe(ChangeEvent e)
        {
            var parts = new List<string>();
            switch (e.Kind)
            {
                case ChangeKind.Create:
                    parts.Add($"created, {e.CurrentSize ?? 0} bytes");
                    break;
                case ChangeKind.Delete:
                    parts.Add($"deleted, was {e.PreviousSize ?? 0} bytes");
                    break;
                case ChangeKind.Rename:
                    parts.Add($"renamed from {e.OldPath}");
                    break;
                case ChangeKind.Move:
                    parts.Add($"moved from {e.OldPath}");
                    break;
                case ChangeKind.Modify:
                    if (e.PreviousSize is long ps && e.CurrentSize is long cs)
                    {
                        long delta = cs - ps;
                        parts.Add($"size {ps} -> {cs} bytes ({(delta >= 0 ? "+" : "")}{delta})");
                    }
                    break;
            }

            if (e.ContentChangeKind is ContentChangeKind k && k != ContentChangeKind.MetadataOnly)
            {
                parts.Add(k switch
                {
                    ContentChangeKind.LikelyEncrypted => "likely encrypted",
                    ContentChangeKind.Appended => "appended to",
                    ContentChangeKind.Truncated => "truncated",
                    ContentChangeKind.ContentRewritten => "content changed",
                    _ => k.Label()
                });
                if (e.PreviousEntropy is double be && e.CurrentEntropy is double ae)
                    parts.Add($"entropy {be:F1} → {ae:F1} bits/byte");
            }
            else if (e.ContentChanged)
            {
                parts.Add("content changed");
            }

            return string.Join(", ", parts);
        }
    }
}
