using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using ChangeLinkCore;

namespace ChangeLinkApp
{
    public partial class MainWindow : Window
    {
        private readonly MonitorModel _model = new();
        private readonly Dictionary<string, HashSet<string>> _expandedByRoot = new();
        private double? _originalZoom; // null = fit to the pane's width
        private double? _modifiedZoom;
        private string _filter = "All";

        public MainWindow()
        {
            InitializeComponent();
            RootsList.ItemsSource = _model.Roots;
            _model.DiffsUpdated += () => Dispatcher.Invoke(RefreshAll);
            _model.StatusChanged += msg => Dispatcher.Invoke(() => StatusText.Text = msg);
            BuildLegend();
        }

        // --- Left panel handlers ---

        private void AddDirectoryButton_Click(object sender, RoutedEventArgs e)
        {
            using var dialog = new System.Windows.Forms.FolderBrowserDialog();
            if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
            {
                _model.AddDirectory(dialog.SelectedPath);
            }
        }

        private void RemoveDirectoryButton_Click(object sender, RoutedEventArgs e)
        {
            if (RootsList.SelectedItem is string path) _model.RemoveDirectory(path);
        }

        private void ApplyIntervalButton_Click(object sender, RoutedEventArgs e)
        {
            _model.IntervalValueText = IntervalValueBox.Text;
            _model.IntervalUnit = (IntervalUnit)IntervalUnitBox.SelectedIndex;
            _model.ApplyInterval();
            IntervalErrorText.Text = _model.IntervalError ?? "";
            StatusText.Text = _model.StatusMessage ?? StatusText.Text;
        }

        private void StartStopButton_Click(object sender, RoutedEventArgs e)
        {
            if (_model.IsRunning)
            {
                _model.Stop();
                StartStopButton.Content = "Start Monitoring";
            }
            else
            {
                _model.IntervalValueText = IntervalValueBox.Text;
                _model.IntervalUnit = (IntervalUnit)IntervalUnitBox.SelectedIndex;
                _model.Start();
                IntervalErrorText.Text = _model.IntervalError ?? "";
                if (_model.IsRunning) StartStopButton.Content = "Stop Monitoring";
            }
            StatusText.Text = _model.StatusMessage ?? StatusText.Text;
        }

        private void TakeSnapshotButton_Click(object sender, RoutedEventArgs e) => _model.TakeSnapshotNow();

        private void SetBaselineButton_Click(object sender, RoutedEventArgs e)
        {
            _model.SetLatestAsNewBaseline();
            _expandedByRoot.Clear(); // the baseline changed, so the default expansion is recomputed
        }

        private void LiveUpdatesCheck_Changed(object sender, RoutedEventArgs e)
        {
            _model.LiveUpdates = LiveUpdatesCheck.IsChecked == true;
            _model.RefreshLiveWatching();
        }

        private void FilterBox_Changed(object sender, SelectionChangedEventArgs e)
        {
            if (FilterBox.SelectedItem is ComboBoxItem item && item.Content is string s)
            {
                _filter = s;
                RefreshSummary();
            }
        }

        private void OriginalZoomOut_Click(object sender, RoutedEventArgs e) { _originalZoom = Math.Max(0.3, (_originalZoom ?? 1) * 0.8); RefreshTrees(); }
        private void OriginalZoomIn_Click(object sender, RoutedEventArgs e) { _originalZoom = Math.Min(1.6, (_originalZoom ?? 1) * 1.25); RefreshTrees(); }
        private void OriginalFit_Click(object sender, RoutedEventArgs e) { _originalZoom = null; RefreshTrees(); }
        private void ModifiedZoomOut_Click(object sender, RoutedEventArgs e) { _modifiedZoom = Math.Max(0.3, (_modifiedZoom ?? 1) * 0.8); RefreshTrees(); }
        private void ModifiedZoomIn_Click(object sender, RoutedEventArgs e) { _modifiedZoom = Math.Min(1.6, (_modifiedZoom ?? 1) * 1.25); RefreshTrees(); }
        private void ModifiedFit_Click(object sender, RoutedEventArgs e) { _modifiedZoom = null; RefreshTrees(); }

        private void BuildLegend()
        {
            LegendPanel.Children.Clear();
            void Row(NodeStatus status, string label)
            {
                var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
                panel.Children.Add(new Ellipse { Width = 14, Height = 14, Fill = new SolidColorBrush(NodeStatusStyle.Color(status)), Margin = new Thickness(0, 0, 6, 0) });
                panel.Children.Add(new TextBlock { Text = $"{label} ({NodeStatusStyle.Symbol(status)})", VerticalAlignment = VerticalAlignment.Center, FontSize = 12 });
                LegendPanel.Children.Add(panel);
            }
            Row(NodeStatus.Created, "Created");
            Row(NodeStatus.Deleted, "Deleted (dashed = ghost)");
            Row(NodeStatus.Modified, "Modified");
            Row(NodeStatus.Renamed, "Renamed");
            Row(NodeStatus.Moved, "Moved");
            Row(NodeStatus.Unchanged, "Unchanged");
        }

        // --- Redraw ---

        private void RefreshAll()
        {
            RefreshTrees();
            RefreshSummary();
        }

        private HashSet<string> ExpandedSetFor(RootDiff diff)
        {
            if (!_expandedByRoot.TryGetValue(diff.RootPath, out var set))
            {
                set = TreeLayout.DefaultExpanded(diff.Modified);
                _expandedByRoot[diff.RootPath] = set;
            }
            return set;
        }

        private void RefreshTrees()
        {
            OriginalCanvas.Children.Clear();
            ModifiedCanvas.Children.Clear();
            double oy = 0, my = 0, ow = 0, mw = 0;
            double viewportWidth = Math.Max(OriginalScroll.ViewportWidth, 400);

            foreach (var diff in _model.Diffs)
            {
                var expanded = ExpandedSetFor(diff);
                (oy, var w1) = DrawRootTree(OriginalCanvas, diff, diff.Original, expanded, _originalZoom, viewportWidth, oy, false);
                ow = Math.Max(ow, w1);
                (my, var w2) = DrawRootTree(ModifiedCanvas, diff, diff.Modified, expanded, _modifiedZoom, viewportWidth, my, true);
                mw = Math.Max(mw, w2);
            }
            OriginalCanvas.Width = Math.Max(viewportWidth, ow);
            OriginalCanvas.Height = Math.Max(oy, 50);
            ModifiedCanvas.Width = Math.Max(viewportWidth, mw);
            ModifiedCanvas.Height = Math.Max(my, 50);
        }

        private (double, double) DrawRootTree(Canvas canvas, RootDiff diff, TreeNode root, HashSet<string> expanded, double? manualZoom, double viewportWidth, double yOffset, bool clickable)
        {
            var layout = TreeLayout.Layout(root, expanded);
            double scale = manualZoom ?? TreeLayout.FitScale(layout.Size, new Size(viewportWidth - 16, 10_000));

            var header = new TextBlock { Text = $"{diff.RootName}  ·  {diff.RootPath}", FontWeight = FontWeights.Bold, FontSize = 13 };
            Canvas.SetLeft(header, 8); Canvas.SetTop(header, yOffset);
            canvas.Children.Add(header);
            double top = yOffset + 22;

            // Edges first, so nodes draw on top.
            double r = (TreeLayout.CircleDiameter * scale) / 2;
            foreach (var edge in layout.Edges)
            {
                var from = new Point(edge.From.X * scale, top + edge.From.Y * scale);
                var to = new Point(edge.To.X * scale, top + edge.To.Y * scale);
                double dx = to.X - from.X, dy = to.Y - from.Y;
                double len = Math.Sqrt(dx * dx + dy * dy);
                double ux = len > 0 ? dx / len : 0, uy = len > 0 ? dy / len : 0;
                var line = new Line
                {
                    X1 = from.X + ux * r, Y1 = from.Y + uy * r,
                    X2 = to.X - ux * r, Y2 = to.Y - uy * r,
                    Stroke = new SolidColorBrush(Color.FromRgb(180, 180, 180)),
                    StrokeThickness = 1.5
                };
                if (edge.Dashed) line.StrokeDashArray = new DoubleCollection { 4, 2 };
                canvas.Children.Add(line);
            }

            foreach (var laid in layout.Nodes)
            {
                DrawNode(canvas, diff.RootPath, laid, scale, top, expanded, clickable);
            }

            return (top + layout.Size.Height * scale + 24, layout.Size.Width * scale + 16);
        }

        private void DrawNode(Canvas canvas, string rootPath, LaidOutNode laid, double scale, double top, HashSet<string> expanded, bool clickable)
        {
            var node = laid.Node;
            double d = TreeLayout.CircleDiameter * scale;
            double cx = laid.Cx * scale, cy = top + laid.Cy * scale;

            bool isChanged = node.Status != NodeStatus.Unchanged;
            var fill = isChanged
                ? new SolidColorBrush(NodeStatusStyle.Color(node.Status)) { Opacity = 0.45 }
                : new SolidColorBrush(NodeStatusStyle.PlainFill);

            var ellipse = new Ellipse
            {
                Width = d, Height = d,
                Fill = fill,
                Stroke = Brushes.Black,
                StrokeThickness = 1.2,
                Opacity = node.IsGhost ? 0.8 : 1
            };
            if (node.IsGhost) ellipse.StrokeDashArray = new DoubleCollection { 3, 2 };
            Canvas.SetLeft(ellipse, cx - d / 2);
            Canvas.SetTop(ellipse, cy - d / 2);
            canvas.Children.Add(ellipse);

            if (clickable && node.IsDirectory)
            {
                ellipse.Cursor = System.Windows.Input.Cursors.Hand;
                ellipse.MouseLeftButtonDown += (_, __) =>
                {
                    if (!expanded.Remove(node.Id)) expanded.Add(node.Id);
                    RefreshTrees();
                };
            }

            if (isChanged)
            {
                var symbol = new TextBlock
                {
                    Text = NodeStatusStyle.Symbol(node.Status),
                    FontWeight = FontWeights.Bold,
                    FontSize = Math.Max(9, 13 * scale),
                    Foreground = new SolidColorBrush(NodeStatusStyle.Color(node.Status))
                };
                Canvas.SetLeft(symbol, cx - 4);
                Canvas.SetTop(symbol, cy - 9 * scale);
                canvas.Children.Add(symbol);
            }

            if (node.History.Count > 1)
            {
                var badge = new Border
                {
                    Background = new SolidColorBrush(Color.FromRgb(51, 90, 204)),
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(4, 1, 4, 1),
                    Child = new TextBlock { Text = $"×{node.History.Count}", Foreground = Brushes.White, FontSize = 10 }
                };
                Canvas.SetLeft(badge, cx + d / 2 - 10);
                Canvas.SetTop(badge, cy - d / 2 - 6);
                canvas.Children.Add(badge);
            }

            if (node.IsDirectory && node.Children.Count > 0 && !expanded.Contains(node.Id))
            {
                var hidden = CountDescendants(node);
                var badge = new Border
                {
                    Background = Brushes.LightGray,
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(4, 1, 4, 1),
                    Child = new TextBlock { Text = $"+{hidden}", FontSize = 10 }
                };
                Canvas.SetLeft(badge, cx + d / 2 - 10);
                Canvas.SetTop(badge, cy + d / 2 - 6);
                canvas.Children.Add(badge);
            }

            var label = new TextBlock
            {
                Text = string.IsNullOrEmpty(node.Name) ? "/" : node.Name,
                TextAlignment = TextAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                FontSize = Math.Max(9, 11 * scale),
                Width = TreeLayout.SlotWidth * scale
            };
            Canvas.SetLeft(label, cx - (TreeLayout.SlotWidth * scale) / 2);
            Canvas.SetTop(label, cy + d / 2 + 2);
            canvas.Children.Add(label);
        }

        private static int CountDescendants(TreeNode node)
        {
            int count = 0;
            foreach (var child in node.Children) { count += 1 + CountDescendants(child); }
            return count;
        }

        // --- Summary panel ---

        private void RefreshSummary()
        {
            SummaryPanel.Children.Clear();
            if (_model.Diffs.Count == 0)
            {
                SummaryPanel.Children.Add(new TextBlock { Text = "Nothing to summarise yet.", Foreground = Brushes.Gray });
                return;
            }

            foreach (var diff in _model.Diffs)
            {
                SummaryPanel.Children.Add(BuildRootSummary(diff));
            }
        }

        private UIElement BuildRootSummary(RootDiff diff)
        {
            var box = new StackPanel { Margin = new Thickness(0, 0, 0, 16) };
            box.Children.Add(new TextBlock { Text = $"{diff.RootName}  ·  {diff.RootPath}", FontWeight = FontWeights.Bold, FontSize = 15, Margin = new Thickness(0, 0, 0, 4) });

            var s = diff.Summary;
            box.Children.Add(new TextBlock
            {
                Text = $"Originally (baseline {ChangeStamp.Text(diff.BaselineTakenAt)}): {s.Before.Files} files and {s.Before.Directories} folders, {FormatBytes(s.Before.Bytes)}",
                FontSize = 13
            });
            box.Children.Add(new TextBlock
            {
                Text = $"Now ({ChangeStamp.Text(diff.CurrentTakenAt)}): {s.After.Files} files and {s.After.Directories} folders, {FormatBytes(s.After.Bytes)} ({SignedBytes(s.ByteDelta)})",
                FontSize = 13
            });
            box.Children.Add(new TextBlock
            {
                Text = $"During monitoring: {s.Counts.GetValueOrDefault(ChangeKind.Create)} created, {s.Counts.GetValueOrDefault(ChangeKind.Delete)} deleted, " +
                       $"{s.Counts.GetValueOrDefault(ChangeKind.Modify)} modified, {s.Counts.GetValueOrDefault(ChangeKind.Rename)} renamed, {s.Counts.GetValueOrDefault(ChangeKind.Move)} moved  ·  " +
                       $"{s.Total} modification(s) on {s.ItemCount} item(s)",
                FontWeight = FontWeights.SemiBold,
                FontSize = 13,
                Margin = new Thickness(0, 2, 0, 8)
            });

            box.Children.Add(BuildMetricsGrid(diff.Comparison));
            box.Children.Add(BuildLevelsGrid(diff.Comparison));

            var c = diff.Comparison;
            box.Children.Add(new TextBlock
            {
                Text = $"Path similarity (Jaccard): {c.PathSimilarity * 100:F1}% — {c.CommonPaths} paths in common out of {c.UnionPaths} in either tree",
                FontSize = 12, Foreground = Brushes.DimGray, Margin = new Thickness(0, 6, 0, 0)
            });
            box.Children.Add(new TextBlock
            {
                Text = $"Structural edit operations: {c.StructuralOperations} ({c.CreatedCount} create, {c.DeletedCount} delete, {c.RenamedCount} rename, {c.MovedCount} move)  ·  content modifications: {c.ContentModifications}",
                FontSize = 12, Foreground = Brushes.DimGray
            });
            box.Children.Add(new TextBlock
            {
                Text = $"Items touched: {s.ItemCount} ({c.TouchedRatio * 100:F1}% of the larger tree)  ·  deepest change at level {(c.DeepestChangeDepth < 0 ? "none" : c.DeepestChangeDepth.ToString())}",
                FontSize = 12, Foreground = Brushes.DimGray, Margin = new Thickness(0, 0, 0, 8)
            });

            foreach (var kind in new[] { ChangeKind.Create, ChangeKind.Delete, ChangeKind.Modify, ChangeKind.Rename, ChangeKind.Move })
            {
                if (_filter != "All" && _filter != kind.ToString()) continue;
                var rows = s.EntriesOf(kind, includeImplied: false);
                if (rows.Count == 0) continue;
                box.Children.Add(BuildChangeGroup(kind, rows));
            }

            return new Border { Child = box, BorderBrush = Brushes.LightGray, BorderThickness = new Thickness(0, 0, 0, 1), Padding = new Thickness(0, 0, 0, 8) };
        }

        private static UIElement BuildMetricsGrid(TreeComparison c)
        {
            var grid = new Grid();
            for (int i = 0; i < 4; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());

            (string, int, int)[] whole =
            {
                ("Total nodes (incl. root)", c.Original.Nodes, c.Modified.Nodes),
                ("Files", c.Original.Files, c.Modified.Files),
                ("Folders", c.Original.Directories, c.Modified.Directories),
                ("Leaf nodes", c.Original.Leaves, c.Modified.Leaves),
                ("Depth (height, root = 0)", c.Original.Height, c.Modified.Height),
                ("Widest level (nodes)", c.Original.MaxWidth, c.Modified.MaxWidth),
                ("Widest level (at depth)", c.Original.WidestLevel, c.Modified.WidestLevel),
                ("Max fan-out", c.Original.MaxFanOut, c.Modified.MaxFanOut)
            };
            (string, double, double)[] fraction =
            {
                ("Average node depth", c.Original.AverageDepth, c.Modified.AverageDepth),
                ("Average branching factor", c.Original.AverageBranching, c.Modified.AverageBranching)
            };

            int row = 0;
            void AddHeader()
            {
                grid.RowDefinitions.Add(new RowDefinition());
                AddCell(grid, row, 0, "Metric", bold: true);
                AddCell(grid, row, 1, "Original", bold: true);
                AddCell(grid, row, 2, "Modified", bold: true);
                AddCell(grid, row, 3, "Change", bold: true);
                row++;
            }
            AddHeader();
            foreach (var (name, a, b) in whole)
            {
                grid.RowDefinitions.Add(new RowDefinition());
                AddCell(grid, row, 0, name);
                AddCell(grid, row, 1, a.ToString());
                AddCell(grid, row, 2, b.ToString());
                AddCell(grid, row, 3, Signed(b - a));
                row++;
            }
            foreach (var (name, a, b) in fraction)
            {
                grid.RowDefinitions.Add(new RowDefinition());
                AddCell(grid, row, 0, name);
                AddCell(grid, row, 1, a.ToString("F2"));
                AddCell(grid, row, 2, b.ToString("F2"));
                AddCell(grid, row, 3, (b - a).ToString("+0.00;-0.00;0.00"));
                row++;
            }
            grid.RowDefinitions.Add(new RowDefinition());
            AddCell(grid, row, 0, "Total file size");
            AddCell(grid, row, 1, FormatBytes(c.Original.Bytes));
            AddCell(grid, row, 2, FormatBytes(c.Modified.Bytes));
            AddCell(grid, row, 3, SignedBytes(c.Modified.Bytes - c.Original.Bytes));
            row++;
            grid.RowDefinitions.Add(new RowDefinition());
            AddCell(grid, row, 0, "Average file size");
            AddCell(grid, row, 1, FormatBytes((long)c.Original.AverageFileSize));
            AddCell(grid, row, 2, FormatBytes((long)c.Modified.AverageFileSize));
            AddCell(grid, row, 3, SignedBytes((long)c.Modified.AverageFileSize - (long)c.Original.AverageFileSize));

            return new Border { Child = grid, Margin = new Thickness(0, 0, 0, 8) };
        }

        private static UIElement BuildLevelsGrid(TreeComparison c)
        {
            var grid = new Grid();
            for (int i = 0; i < 4; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());
            grid.RowDefinitions.Add(new RowDefinition());
            AddCell(grid, 0, 0, "Level", bold: true);
            AddCell(grid, 0, 1, "Original", bold: true);
            AddCell(grid, 0, 2, "Modified", bold: true);
            AddCell(grid, 0, 3, "Change", bold: true);
            int row = 1;
            foreach (var lr in c.LevelRows)
            {
                grid.RowDefinitions.Add(new RowDefinition());
                AddCell(grid, row, 0, lr.Depth == 0 ? "0 (root)" : lr.Depth.ToString());
                AddCell(grid, row, 1, lr.Original.ToString());
                AddCell(grid, row, 2, lr.Modified.ToString());
                AddCell(grid, row, 3, Signed(lr.Delta));
                row++;
            }
            return new Border { Child = grid, Margin = new Thickness(0, 0, 0, 4) };
        }

        private static void AddCell(Grid grid, int row, int column, string text, bool bold = false)
        {
            var block = new TextBlock { Text = text, FontSize = 12, Margin = new Thickness(4, 1, 10, 1), FontWeight = bold ? FontWeights.Bold : FontWeights.Normal };
            Grid.SetRow(block, row);
            Grid.SetColumn(block, column);
            grid.Children.Add(block);
        }

        private UIElement BuildChangeGroup(ChangeKind kind, List<SummaryEntry> rows)
        {
            var expander = new Expander { Header = $"{kind} ({rows.Count})", IsExpanded = true, Margin = new Thickness(0, 4, 0, 4), FontWeight = FontWeights.SemiBold };
            var list = new StackPanel();
            foreach (var entry in rows)
            {
                var line = new TextBlock
                {
                    Text = $"{ChangeStamp.Text(entry.Event.ObservedAt)}   {entry.Event.Path}   —   {entry.Detail}",
                    FontSize = 12,
                    Margin = new Thickness(12, 1, 0, 1),
                    TextWrapping = TextWrapping.Wrap
                };
                list.Children.Add(line);
            }
            expander.Content = list;
            return expander;
        }

        private static string FormatBytes(long value)
        {
            double v = value;
            string[] units = { "B", "KB", "MB", "GB", "TB" };
            int i = 0;
            while (Math.Abs(v) >= 1024 && i < units.Length - 1) { v /= 1024; i++; }
            return i == 0 ? $"{value} B" : $"{v:F1} {units[i]}";
        }

        private static string Signed(int value) => value > 0 ? $"+{value}" : value.ToString();
        private static string SignedBytes(long value) => (value >= 0 ? "+" : "-") + FormatBytes(Math.Abs(value));
    }
}
