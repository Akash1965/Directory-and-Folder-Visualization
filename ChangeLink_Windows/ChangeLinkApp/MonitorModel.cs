using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using ChangeLinkCore;

namespace ChangeLinkApp
{
    public enum IntervalUnit { Seconds, Minutes, Hours }

    public static class IntervalUnitExtensions
    {
        public static double Multiplier(this IntervalUnit unit) => unit switch
        {
            IntervalUnit.Seconds => 1,
            IntervalUnit.Minutes => 60,
            IntervalUnit.Hours => 3600,
            _ => 1
        };
    }

    /// <summary>
    /// Holds the monitored directories, the interval, the baselines, the latest snapshots, the
    /// change log and the scheduling of live refreshes -- the Windows counterpart of the macOS
    /// build's <c>MonitorModel</c>. A scan started by the interval timer re-hashes every file
    /// (a full verification pass); a scan started by a live filesystem notification reuses the
    /// hash of any file whose identity, size and modification time have not changed.
    /// </summary>
    public sealed class MonitorModel : IDisposable
    {
        public ObservableCollection<string> Roots { get; } = new();

        public bool IsRunning { get; private set; }
        public bool LiveUpdates { get; set; } = true;
        public string IntervalValueText { get; set; } = "2";
        public IntervalUnit IntervalUnit { get; set; } = IntervalUnit.Minutes;
        public string? IntervalError { get; private set; }
        public string? StatusMessage { get; private set; }
        public DateTime? NextScheduledScan { get; private set; }

        public List<RootDiff> Diffs { get; private set; } = new();

        /// <summary>Raised (on a background thread) whenever the trees/summary should be redrawn.</summary>
        public event Action? DiffsUpdated;
        /// <summary>Raised (on a background thread) whenever the status line text changes.</summary>
        public event Action<string>? StatusChanged;

        private readonly Dictionary<string, Snapshot> _baselines = new();
        private readonly Dictionary<string, DateTime> _baselineTakenAt = new();
        private readonly Dictionary<string, Snapshot> _latest = new();
        private readonly Dictionary<string, List<ChangeEvent>> _changeLogs = new();
        private readonly Dictionary<string, FileSystemWatcher> _watchers = new();
        private readonly object _scanLock = new();
        private bool _liveRefreshScheduled;
        private double _intervalSeconds = 120;
        private CancellationTokenSource? _loopCts;
        private Task? _loopTask;

        public void AddDirectory(string path)
        {
            if (!Roots.Contains(path)) Roots.Add(path);
        }

        public void RemoveDirectory(string path)
        {
            Roots.Remove(path);
            _baselines.Remove(path); _latest.Remove(path); _changeLogs.Remove(path); _baselineTakenAt.Remove(path);
            if (_watchers.TryGetValue(path, out var w)) { w.Dispose(); _watchers.Remove(path); }
            RebuildDiffs();
        }

        /// <summary>Validates the interval fields; sets <see cref="IntervalError"/> on failure.</summary>
        public double? ParsedIntervalSeconds()
        {
            if (!double.TryParse(IntervalValueText, out var value) || !double.IsFinite(value) || value <= 0)
            {
                IntervalError = "Enter a positive number.";
                return null;
            }
            double seconds = value * IntervalUnit.Multiplier();
            if (seconds < 1) { IntervalError = "The interval must be at least 1 second."; return null; }
            if (seconds > 365 * 24 * 3600) { IntervalError = "The interval must be at most 365 days."; return null; }
            IntervalError = null;
            return seconds;
        }

        public void ApplyInterval()
        {
            var seconds = ParsedIntervalSeconds();
            if (seconds is not double s) { SetStatus(IntervalError ?? "Enter a valid interval."); return; }
            _intervalSeconds = s;
            if (!IsRunning) { SetStatus($"Snapshot interval set to {IntervalDisplayText()}."); return; }
            RestartLoop(captureFirst: false);
            SetStatus($"Interval changed to {IntervalDisplayText()}. The next snapshot follows on the new schedule.");
        }

        private string IntervalDisplayText() => $"{IntervalValueText} {IntervalUnit.ToString().ToLowerInvariant()}";

        public void Start()
        {
            if (Roots.Count == 0) { SetStatus("Add at least one directory first."); return; }
            var seconds = ParsedIntervalSeconds();
            if (seconds is not double s) { SetStatus(IntervalError ?? "Enter a valid interval."); return; }
            _intervalSeconds = s;

            SetStatus("Capturing baseline snapshot...");
            foreach (var root in Roots)
            {
                try
                {
                    var snap = Snapshotter.TakeValidated(root, hashContents: true);
                    _baselines[root] = snap;
                    _baselineTakenAt[root] = snap.TakenAt;
                    _latest[root] = snap;
                    _changeLogs[root] = new List<ChangeEvent>();
                }
                catch (SnapshotException ex)
                {
                    SetStatus($"Could not capture a baseline for {root}: {ex.Message}");
                }
            }
            IsRunning = true;
            RebuildDiffs();
            RefreshLiveWatching();
            RestartLoop(captureFirst: true);
        }

        public void Stop()
        {
            IsRunning = false;
            _loopCts?.Cancel();
            foreach (var w in _watchers.Values) w.Dispose();
            _watchers.Clear();
            SetStatus("Monitoring stopped.");
        }

        public void TakeSnapshotNow()
        {
            if (!IsRunning) return;
            _ = CaptureSnapshots(live: false);
        }

        public void SetLatestAsNewBaseline()
        {
            foreach (var root in Roots.ToList())
            {
                if (!_latest.TryGetValue(root, out var snap)) continue;
                _baselines[root] = snap;
                _baselineTakenAt[root] = snap.TakenAt;
                _changeLogs[root] = new List<ChangeEvent>();
            }
            RebuildDiffs();
            SetStatus("Latest snapshot set as the new baseline.");
        }

        // --- Live (filesystem-notification) refresh ---

        public void RefreshLiveWatching()
        {
            foreach (var w in _watchers.Values) w.Dispose();
            _watchers.Clear();
            if (!IsRunning || !LiveUpdates) return;

            foreach (var root in Roots)
            {
                if (!Directory.Exists(root)) continue;
                try
                {
                    var watcher = new FileSystemWatcher(root)
                    {
                        IncludeSubdirectories = true,
                        NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size
                    };
                    FileSystemEventHandler onEvent = (_, __) => ScheduleLiveRefresh();
                    RenamedEventHandler onRenamed = (_, __) => ScheduleLiveRefresh();
                    watcher.Created += onEvent;
                    watcher.Deleted += onEvent;
                    watcher.Changed += onEvent;
                    watcher.Renamed += onRenamed;
                    watcher.EnableRaisingEvents = true;
                    _watchers[root] = watcher;
                }
                catch (Exception ex)
                {
                    SetStatus($"Live updates are unavailable for {root}: {ex.Message}");
                }
            }
        }

        /// <summary>Coalesces a burst of filesystem events into one rescan, matching the 0.3 s
        /// debounce the macOS build uses after its FSEvents trigger fires.</summary>
        private void ScheduleLiveRefresh()
        {
            lock (_scanLock)
            {
                if (!IsRunning || !LiveUpdates || _liveRefreshScheduled) return;
                _liveRefreshScheduled = true;
            }
            _ = Task.Run(async () =>
            {
                await Task.Delay(300);
                lock (_scanLock) { _liveRefreshScheduled = false; }
                if (IsRunning && LiveUpdates) await CaptureSnapshots(live: true);
            });
        }

        // --- Interval loop ---

        private void RestartLoop(bool captureFirst)
        {
            _loopCts?.Cancel();
            _loopCts = new CancellationTokenSource();
            var token = _loopCts.Token;
            _loopTask = Task.Run(async () =>
            {
                bool first = captureFirst;
                while (!token.IsCancellationRequested)
                {
                    if (!first)
                    {
                        NextScheduledScan = DateTime.Now.AddSeconds(_intervalSeconds);
                        try { await Task.Delay(TimeSpan.FromSeconds(_intervalSeconds), token); }
                        catch (TaskCanceledException) { break; }
                    }
                    first = false;
                    if (token.IsCancellationRequested) break;
                    await CaptureSnapshots(live: false);
                }
            }, token);
        }

        // --- Scanning ---

        private readonly SemaphoreSlim _scanGate = new(1, 1);

        /// <summary>Waits until no other scan is running, scans every root, compares with the
        /// previous latest snapshot, appends events to the log and rebuilds the trees.</summary>
        private async Task CaptureSnapshots(bool live)
        {
            await _scanGate.WaitAsync();
            try
            {
                foreach (var root in Roots.ToList())
                {
                    if (!_baselines.ContainsKey(root)) continue;
                    try
                    {
                        var previous = live ? _latest.GetValueOrDefault(root) : null;
                        var snap = await Task.Run(() => Snapshotter.TakeValidated(root, hashContents: true, previous));
                        var priorLatest = _latest.GetValueOrDefault(root) ?? _baselines[root];
                        var events = SnapshotComparator.Compare(priorLatest, snap);
                        if (events.Count > 0)
                        {
                            if (!_changeLogs.TryGetValue(root, out var log)) { log = new List<ChangeEvent>(); _changeLogs[root] = log; }
                            log.AddRange(events);
                        }
                        _latest[root] = snap;
                    }
                    catch (SnapshotException ex)
                    {
                        SetStatus($"Scan failed for {root}; keeping the previous baseline. ({ex.Message})");
                    }
                }
                RebuildDiffs();
            }
            finally
            {
                _scanGate.Release();
            }
        }

        private void RebuildDiffs()
        {
            var diffs = new List<RootDiff>();
            foreach (var root in Roots)
            {
                if (!_baselines.TryGetValue(root, out var baseline)) continue;
                var latest = _latest.GetValueOrDefault(root) ?? baseline;
                var log = _changeLogs.GetValueOrDefault(root) ?? new List<ChangeEvent>();
                diffs.Add(DirectoryTreeDiff.Build(root, baseline, latest, log, _baselineTakenAt.GetValueOrDefault(root, baseline.TakenAt), latest.TakenAt));
            }
            Diffs = diffs;
            DiffsUpdated?.Invoke();
        }

        private void SetStatus(string message)
        {
            StatusMessage = message;
            StatusChanged?.Invoke(message);
        }

        public void Dispose()
        {
            _loopCts?.Cancel();
            foreach (var w in _watchers.Values) w.Dispose();
        }
    }
}
