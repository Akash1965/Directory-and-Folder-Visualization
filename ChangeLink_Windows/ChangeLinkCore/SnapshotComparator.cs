using System;
using System.Collections.Generic;
using System.Linq;

namespace ChangeLinkCore
{
    /// <summary>
    /// Compares two snapshots of the same root and produces a sorted list of change events.
    /// A direct port of the macOS build's <c>SnapshotComparator.compare</c> (Algorithm 2 in the
    /// report): a rename or move is recognised only when the old path with the same file ID has
    /// really disappeared, so a new hard link (same ID, old path still present) is reported as a
    /// creation, and a directory's own modification time changing alone (because a child changed)
    /// is ignored.
    /// </summary>
    public static class SnapshotComparator
    {
        public static string ParentPath(string path)
        {
            int slash = path.LastIndexOf('/');
            return slash < 0 ? "" : path.Substring(0, slash);
        }

        public static List<ChangeEvent> Compare(Snapshot oldSnapshot, Snapshot newSnapshot)
        {
            var result = new List<ChangeEvent>();

            // Several old paths can share one file ID (hard links), so keep every candidate.
            var oldByID = oldSnapshot.Files.Values
                .GroupBy(r => r.FileId)
                .ToDictionary(g => g.Key, g => g.OrderBy(r => r.Path).ToList());
            var consumedOldPaths = new HashSet<string>();

            foreach (var p in newSnapshot.Files.Keys.OrderBy(x => x, StringComparer.Ordinal))
            {
                var r = newSnapshot.Files[p];
                var nodeKind = r.IsDirectory ? NodeKind.Directory : NodeKind.File;

                if (oldSnapshot.Files.TryGetValue(p, out var prior))
                {
                    if (prior.Equals(r)) continue;
                    // A directory's own mtime changes whenever its children change; reported on the children instead.
                    if (prior.IsDirectory && r.IsDirectory && prior.FileId == r.FileId) continue;

                    result.Add(new ChangeEvent(
                        ChangeKind.Modify, p, r.FileId, nodeKind,
                        previousSize: prior.Size, currentSize: r.Size,
                        contentChanged: prior.ContentHash != r.ContentHash));
                }
                else
                {
                    // Only an old path that has really vanished can be the source of a rename/move.
                    // A still-present path with the same ID is a hard link, so this is a new file.
                    FileRecord? source = null;
                    if (oldByID.TryGetValue(r.FileId, out var candidates))
                    {
                        source = candidates.FirstOrDefault(c => !newSnapshot.Files.ContainsKey(c.Path) && !consumedOldPaths.Contains(c.Path));
                    }

                    if (source != null)
                    {
                        consumedOldPaths.Add(source.Path);
                        bool sameDir = ParentPath(source.Path) == ParentPath(p);
                        result.Add(new ChangeEvent(
                            sameDir ? ChangeKind.Rename : ChangeKind.Move, p, r.FileId, nodeKind,
                            oldPath: source.Path, previousSize: source.Size, currentSize: r.Size,
                            contentChanged: source.ContentHash != r.ContentHash));
                    }
                    else
                    {
                        result.Add(new ChangeEvent(
                            ChangeKind.Create, p, r.FileId, nodeKind,
                            currentSize: r.Size, contentChanged: r.ContentHash != null));
                    }
                }
            }

            foreach (var kv in oldSnapshot.Files)
            {
                if (newSnapshot.Files.ContainsKey(kv.Key) || consumedOldPaths.Contains(kv.Key)) continue;
                var r = kv.Value;
                result.Add(new ChangeEvent(
                    ChangeKind.Delete, kv.Key, r.FileId, r.IsDirectory ? NodeKind.Directory : NodeKind.File,
                    previousSize: r.Size));
            }

            return result
                .OrderBy(e => e.Path, StringComparer.Ordinal)
                .ThenBy(e => (int)e.Kind)
                .ToList();
        }
    }
}
