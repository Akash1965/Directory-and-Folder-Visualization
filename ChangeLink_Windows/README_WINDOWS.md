# Change-Link for Windows

This is a Windows port of the macOS Change-Link project: a directory-tree change monitor that
takes periodic and live snapshots of one or more folders, compares them, and shows an Original
tree and a Modified tree side by side with a change summary.

It is a straight port, not a reinterpretation: the hashing, comparison, tree-building and
modification-classification algorithms are translated line-for-line from the Swift
`ChangeLinkCore` library documented in the project report, so the two builds should classify the
same file operations the same way. The UI (WPF instead of SwiftUI) is a from-scratch
reimplementation of the same layout, since SwiftUI itself doesn't run on Windows.

**This project was written without access to a Windows machine or the .NET SDK, so it has not
been compiled or run.** Open it in Visual Studio and build it there before relying on it; if it
throws a compiler error, paste it back and it can be fixed directly.

## Requirements

- Windows 10 or later
- .NET 8 SDK
- Visual Studio 2022 (recommended), or the `dotnet` CLI

## Building and running

**Visual Studio:** open `ChangeLinkWindows.sln`, set `ChangeLinkApp` as the startup project, and
press F5.

**Command line (from this folder, on Windows):**

```
dotnet build ChangeLinkWindows.sln
dotnet run --project ChangeLinkApp
```

**Self-test** (pure logic, no UI; also runs on macOS/Linux for reference, using the path-based
file-identity fallback there):

```
dotnet run --project ChangeLinkSelfTest
```

## Project layout

| Project | Role |
|---|---|
| `ChangeLinkCore` | Portable class library: models, snapshotting, hashing, comparison, tree building, metrics, modification classification. No UI or Windows-only code except the file-identity helper. |
| `ChangeLinkApp` | WPF desktop application: directory list, interval controls, live monitoring, the two tree panes, and the summary panel. |
| `ChangeLinkSelfTest` | Console self-test exercising the core library against a real temporary directory. |

## Mapping from the macOS build

| macOS (Swift) | Windows (C#) | Notes |
|---|---|---|
| `FileRecord`, `Snapshot`, `ChangeEvent`, `ChangeKind`, `NodeKind` | `Models.cs` | Same fields, same semantics. |
| `fileResourceIdentifier` | `FileIdentity.Resolve` (`FileIdentity.cs`) | Uses `GetFileInformationByHandle` (volume serial + MFT file index) over P/Invoke -- the direct NTFS analogue of a macOS resource identifier. Falls back to a path string if the handle can't be opened, same trade-off the macOS build makes. |
| `Snapshotter.takeValidated`, the one-pass `digest()` (SHA-256 + 64-byte prefix MD5 + Shannon entropy) | `Snapshotter.cs` | Same constants: 64-byte prefix window, 1 MiB entropy sample, 1 MiB hash chunks, same hash-reuse rule. |
| `SnapshotComparator.compare` | `SnapshotComparator.cs` | Same algorithm: hard-link-aware, rename/move via vanished-old-path + matching ID, directory-mtime-only changes ignored. |
| `ModificationClassifier` | `ModificationClassifier.cs` | Same thresholds (`theta_H = 7.3`, `theta_R = 0.95`, `k_min = 40`) and the same case-by-case `Classify` logic, including the base64/Fernet alphabet-ratio fix. |
| `DirectoryTreeDiff`, `TreeNode`, `ChangeSummary` | `TreeDiff.cs` | Same two-tree construction: the Original tree always shows the baseline structure with no change marks; the Modified tree shows net status plus ghost nodes for deletions, with the synthesized-intermediate-ghost-folder fix applied. |
| `TreeMetrics`, `TreeComparison` | `TreeMetrics.cs` | Same formulas: node/file/folder/leaf counts, height, average depth, level profile, max fan-out, average branching, byte totals, Jaccard path similarity, structural edit cost, touched ratio, deepest changed level. |
| `MonitorModel` | `MonitorModel.cs` | Same responsibilities: baseline capture, interval scheduling, live-refresh debouncing, change-log accumulation. |
| FSEvents (`FSEventsTrigger`) | `System.IO.FileSystemWatcher` + a 300 ms debounce timer | Windows has no direct FSEvents equivalent; `FileSystemWatcher` plus the same 300 ms coalescing window gives the same "one rescan per burst of activity" behaviour, though the exact OS-level timing differs from FSEvents' 0.5 s latency window. |
| SwiftUI `TreeGraphView`, `SummaryPanel` | WPF `MainWindow.xaml(.cs)`, `TreeLayout.cs` | Same layout constants (52 pt circles, 104 pt slot width, 116 pt level height, 16 pt margin, 0.35-1.0 fit range, 0.3-1.6 zoom range) and the same edge-shortening-by-radius math, redrawn with WPF `Canvas`/`Ellipse`/`Line` instead of SwiftUI `Path`/`Circle`. |
| `NSOpenPanel` | `System.Windows.Forms.FolderBrowserDialog` | Simplest native folder picker available from WPF; the project enables `UseWindowsForms` just for this dialog. |

## What's intentionally not here

Consistent with the current macOS build and report: there is no SQLite persistence layer and no
WhatsApp (or other) alert integration. Both existed only in the macOS project's command-line
self-test, never in the shipped GUI app, so this port doesn't carry them over either. State
(directories, baselines, change log) is kept in memory only, same as the macOS app.

## Known differences worth knowing about

- **File identity** is NTFS-specific (volume serial + MFT file index). It is stable across
  renames and moves *within the same volume*, matching the macOS app's own caveat that its
  resource-identifier fallback is not a stable identity either. A move across drives will look
  like a delete + create on both platforms.
- **Live-update timing** uses a single 300 ms debounce after each `FileSystemWatcher` event
  rather than FSEvents' two-stage (0.5 s OS coalescing + 0.3 s app debounce) scheme. In practice
  both coalesce a burst of filesystem activity into one rescan; the exact delay differs slightly.
- **Multiple monitored roots** are drawn stacked vertically in each pane (one tree per root, like
  the macOS app's repeated `RootDiffSection`), with pane-wide zoom/fit rather than a separate
  zoom level per root.
- The entropy/modification-type classifier is a heuristic, not a forensic determination, exactly
  as documented in the macOS report -- the same caveat applies here unchanged.
