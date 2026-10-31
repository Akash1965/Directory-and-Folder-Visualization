using System.Windows.Media;
using ChangeLinkCore;

namespace ChangeLinkApp
{
    /// <summary>Colour and glyph for each node status, so a change is never shown by colour
    /// alone -- a direct port of the macOS build's <c>NodeStatus</c> styling extension.</summary>
    public static class NodeStatusStyle
    {
        public static Color Color(NodeStatus status) => status switch
        {
            NodeStatus.Created => Color.FromRgb(46, 199, 94),
            NodeStatus.Deleted => Color.FromRgb(245, 69, 77),
            NodeStatus.Modified => Color.FromRgb(255, 145, 36),
            NodeStatus.Renamed => Color.FromRgb(201, 79, 230),
            NodeStatus.Moved => Color.FromRgb(201, 79, 230),
            NodeStatus.Unchanged => Colors.Gray,
            _ => Colors.Gray
        };

        public static string Symbol(NodeStatus status) => status switch
        {
            NodeStatus.Created => "+",
            NodeStatus.Deleted => "–",
            NodeStatus.Modified => "~",
            NodeStatus.Renamed => "R",
            NodeStatus.Moved => "M",
            _ => ""
        };

        public static readonly Color PlainFill = Color.FromRgb(204, 227, 250); // light blue
    }
}
