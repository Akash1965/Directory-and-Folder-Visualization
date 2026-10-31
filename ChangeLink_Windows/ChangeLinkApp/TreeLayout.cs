using System;
using System.Collections.Generic;
using System.Windows;
using ChangeLinkCore;

namespace ChangeLinkApp
{
    public sealed class LaidOutNode
    {
        public TreeNode Node { get; }
        public double Cx { get; }
        public double Cy { get; }
        public LaidOutNode(TreeNode node, double cx, double cy) { Node = node; Cx = cx; Cy = cy; }
    }

    public sealed class LaidOutEdge
    {
        public string Id { get; }
        public Point From { get; }
        public Point To { get; }
        public NodeStatus Status { get; }
        public bool Dashed { get; }
        public LaidOutEdge(string id, Point from, Point to, NodeStatus status, bool dashed)
        {
            Id = id; From = from; To = to; Status = status; Dashed = dashed;
        }
    }

    public sealed class TreeLayoutResult
    {
        public List<LaidOutNode> Nodes { get; } = new();
        public List<LaidOutEdge> Edges { get; } = new();
        public Size Size { get; set; }
    }

    /// <summary>
    /// Pure top-to-bottom tidy-tree geometry: a parent is centred above its first and last
    /// *visible* child, every leaf of the visible tree gets its own column, and only expanded
    /// folders show their children. A direct port of the macOS build's <c>TreeLayout</c> enum
    /// (Algorithm 4 in the report), so the same constants produce the same canvas.
    /// </summary>
    public static class TreeLayout
    {
        public const double CircleDiameter = 52;
        public const double LabelHeight = 32;
        public const double SlotWidth = 104;
        public const double LevelHeight = 116;
        public const double Margin = 16;
        public static double CellHeight => CircleDiameter + 4 + LabelHeight;

        /// <summary>Scale that fits the whole tree into the viewport (never enlarged past 100%,
        /// never shrunk below 35%).</summary>
        public static double FitScale(Size content, Size viewport)
        {
            if (content.Width <= 0 || content.Height <= 0 || viewport.Width <= 0 || viewport.Height <= 0) return 1;
            return Math.Max(0.35, Math.Min(1, Math.Min(viewport.Width / content.Width, viewport.Height / content.Height)));
        }

        public static TreeLayoutResult Layout(TreeNode root, HashSet<string> expanded)
        {
            var result = new TreeLayoutResult();
            double nextColumn = 0;
            int maxDepth = 0;

            double Place(TreeNode node, int depth)
            {
                maxDepth = Math.Max(maxDepth, depth);
                double cy = Margin + depth * LevelHeight + CircleDiameter / 2;
                var visibleChildren = (node.IsDirectory && expanded.Contains(node.Id)) ? node.Children : new List<TreeNode>();
                double cx;
                if (visibleChildren.Count == 0)
                {
                    cx = Margin + nextColumn * SlotWidth + SlotWidth / 2;
                    nextColumn += 1;
                    result.Nodes.Add(new LaidOutNode(node, cx, cy));
                }
                else
                {
                    var childXs = new List<double>();
                    foreach (var child in visibleChildren) childXs.Add(Place(child, depth + 1));
                    cx = (childXs[0] + childXs[^1]) / 2;
                    result.Nodes.Add(new LaidOutNode(node, cx, cy));
                    for (int i = 0; i < visibleChildren.Count; i++)
                    {
                        var child = visibleChildren[i];
                        result.Edges.Add(new LaidOutEdge(
                            node.Id + "→" + child.Id,
                            new Point(cx, cy),
                            new Point(childXs[i], cy + LevelHeight),
                            child.Status, child.IsGhost));
                    }
                }
                return cx;
            }

            Place(root, 0);
            result.Size = new Size(
                Margin * 2 + Math.Max(nextColumn, 1) * SlotWidth,
                Margin * 2 + maxDepth * LevelHeight + CellHeight);
            return result;
        }

        /// <summary>Root plus every folder that contains a change, so all changes are visible
        /// when the tree first appears.</summary>
        public static HashSet<string> DefaultExpanded(TreeNode root)
        {
            var ids = new HashSet<string> { root.Id };
            void Visit(TreeNode node)
            {
                if (node.IsDirectory && node.ChangedDescendants > 0) ids.Add(node.Id);
                foreach (var child in node.Children) Visit(child);
            }
            Visit(root);
            return ids;
        }

        public static HashSet<string> AllDirectories(TreeNode root)
        {
            var ids = new HashSet<string>();
            void Visit(TreeNode node)
            {
                if (node.IsDirectory && node.Children.Count > 0) ids.Add(node.Id);
                foreach (var child in node.Children) Visit(child);
            }
            Visit(root);
            return ids;
        }
    }
}
