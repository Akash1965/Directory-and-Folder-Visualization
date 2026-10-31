using System;
using System.Collections.Generic;
using System.Linq;

namespace ChangeLinkCore
{
    /// <summary>One formatting rule for every timestamp the app shows: local time, millisecond precision.</summary>
    public static class ChangeStamp
    {
        public static string Text(DateTime date) => date.ToString("yyyy-MM-dd HH:mm:ss.fff");
    }

    /// <summary>
    /// Structural measurements of one directory tree. Ghost nodes (items drawn only to show a
    /// deletion) are ignored, so the numbers describe the folder as it really was or is. A direct
    /// port of the macOS build's <c>TreeMetrics.measure</c>; the root is level 0 and counts as a
    /// node but not as a file or a folder.
    /// </summary>
    public sealed class TreeMetrics
    {
        public int Nodes { get; init; }
        public int Files { get; init; }
        public int Directories { get; init; }
        public int Leaves { get; init; }
        public int Height { get; init; }
        public double AverageDepth { get; init; }
        public List<int> Levels { get; init; } = new();
        public int MaxWidth { get; init; }
        public int WidestLevel { get; init; }
        public int MaxFanOut { get; init; }
        public double AverageBranching { get; init; }
        public long Bytes { get; init; }
        public double AverageFileSize { get; init; }

        public static TreeMetrics Measure(TreeNode root)
        {
            var levels = new List<int>();
            int files = 0, directories = 0, leaves = 0;
            int internalNodes = 0, childEdges = 0, maxFan = 0;
            long depthSum = 0;
            long bytes = 0;

            var stack = new Stack<(TreeNode node, int depth)>();
            stack.Push((root, 0));
            while (stack.Count > 0)
            {
                var (node, depth) = stack.Pop();
                while (levels.Count <= depth) levels.Add(0);
                levels[depth]++;

                if (depth > 0)
                {
                    depthSum += depth;
                    if (node.IsDirectory) directories++;
                    else { files++; bytes += node.Size ?? 0; }
                }

                var kids = node.Children.Where(c => !c.IsGhost).ToList();
                if (kids.Count == 0) leaves++;
                else { internalNodes++; childEdges += kids.Count; maxFan = Math.Max(maxFan, kids.Count); }

                foreach (var kid in kids) stack.Push((kid, depth + 1));
            }

            int nodes = levels.Sum();
            int widest = 0;
            for (int depth = 0; depth < levels.Count; depth++)
                if (levels[depth] > levels[widest]) widest = depth;

            return new TreeMetrics
            {
                Nodes = nodes,
                Files = files,
                Directories = directories,
                Leaves = leaves,
                Height = Math.Max(levels.Count - 1, 0),
                AverageDepth = nodes > 1 ? (double)depthSum / (nodes - 1) : 0,
                Levels = levels,
                MaxWidth = levels.Count > 0 ? levels.Max() : 0,
                WidestLevel = widest,
                MaxFanOut = maxFan,
                AverageBranching = internalNodes > 0 ? (double)childEdges / internalNodes : 0,
                Bytes = bytes,
                AverageFileSize = files > 0 ? (double)bytes / files : 0
            };
        }
    }

    public sealed class LevelRow
    {
        public int Depth { get; init; }
        public int Original { get; init; }
        public int Modified { get; init; }
        public int Delta => Modified - Original;
    }

    /// <summary>Side-by-side comparison of the Original and Modified trees. A direct port of the
    /// macOS build's <c>TreeComparison.make</c>.</summary>
    public sealed class TreeComparison
    {
        public TreeMetrics Original { get; init; } = null!;
        public TreeMetrics Modified { get; init; } = null!;
        public List<LevelRow> LevelRows { get; init; } = new();
        public int CommonPaths { get; init; }
        public int UnionPaths { get; init; }
        /// <summary>Jaccard similarity of the two path sets: |A n B| / |A u B|, 1.0 for identical structure.</summary>
        public double PathSimilarity { get; init; }
        /// <summary>Created + deleted + renamed + moved. A renamed/moved folder counts as one
        /// operation because its subtree travels with it -- a cheaper approximation to exact
        /// tree edit distance, suited to a live summary.</summary>
        public int StructuralOperations { get; init; }
        public int CreatedCount { get; init; }
        public int DeletedCount { get; init; }
        public int RenamedCount { get; init; }
        public int MovedCount { get; init; }
        public int ContentModifications { get; init; }
        public double TouchedRatio { get; init; }
        /// <summary>Depth of the deepest item that was changed in either tree; -1 when nothing changed.</summary>
        public int DeepestChangeDepth { get; init; }

        public static TreeComparison Make(TreeNode original, TreeNode modified, Dictionary<ChangeKind, int> counts, int touchedItems)
        {
            var before = TreeMetrics.Measure(original);
            var after = TreeMetrics.Measure(modified);

            var rows = new List<LevelRow>();
            int maxLevels = Math.Max(before.Levels.Count, after.Levels.Count);
            for (int depth = 0; depth < maxLevels; depth++)
            {
                rows.Add(new LevelRow
                {
                    Depth = depth,
                    Original = depth < before.Levels.Count ? before.Levels[depth] : 0,
                    Modified = depth < after.Levels.Count ? after.Levels[depth] : 0
                });
            }

            var a = RealPaths(original);
            var b = RealPaths(modified);
            int common = a.Intersect(b).Count();
            int union = a.Union(b).Count();

            int created = counts.GetValueOrDefault(ChangeKind.Create);
            int deleted = counts.GetValueOrDefault(ChangeKind.Delete);
            int renamed = counts.GetValueOrDefault(ChangeKind.Rename);
            int moved = counts.GetValueOrDefault(ChangeKind.Move);
            int larger = Math.Max(a.Count, b.Count);

            int deepest = -1;
            foreach (var tree in new[] { original, modified })
                deepest = Math.Max(deepest, DeepestTouched(tree, 0));

            return new TreeComparison
            {
                Original = before,
                Modified = after,
                LevelRows = rows,
                CommonPaths = common,
                UnionPaths = union,
                PathSimilarity = union == 0 ? 1 : (double)common / union,
                StructuralOperations = created + deleted + renamed + moved,
                CreatedCount = created,
                DeletedCount = deleted,
                RenamedCount = renamed,
                MovedCount = moved,
                ContentModifications = counts.GetValueOrDefault(ChangeKind.Modify),
                TouchedRatio = larger == 0 ? 0 : (double)touchedItems / larger,
                DeepestChangeDepth = deepest
            };
        }

        private static HashSet<string> RealPaths(TreeNode root)
        {
            var result = new HashSet<string>();
            var stack = new Stack<TreeNode>(root.Children.Where(c => !c.IsGhost));
            while (stack.Count > 0)
            {
                var node = stack.Pop();
                result.Add(node.Id);
                foreach (var child in node.Children.Where(c => !c.IsGhost)) stack.Push(child);
            }
            return result;
        }

        private static int DeepestTouched(TreeNode node, int depth)
        {
            int best = (depth > 0 && node.IsTouched) ? depth : -1;
            foreach (var child in node.Children) best = Math.Max(best, DeepestTouched(child, depth + 1));
            return best;
        }
    }
}
