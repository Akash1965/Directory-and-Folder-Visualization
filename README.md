# ChangeLink for macOS

ChangeLink is a Swift Package containing a filesystem snapshot/comparison core and a SwiftUI macOS dashboard. It detects creates, deletes, modifications, renames, and moves by comparing stable `fileResourceIdentifier` values rather than path guesses. The paper-inspired temporal model is backed by SQLite and exposes explicit UNKNOWN attribution when process evidence is unavailable.

## Architecture
`Snapshotter` traverses a root and records metadata; `SnapshotComparator` emits `ChangeEvent`; `ChangeStore` persists events in system SQLite3; `AttributedChange` defaults to evidence-aware `UNKNOWN`. This is deliberate: FSEvents reports paths, not an authoritative responsible process. No process attribution is fabricated. `MockWhatsAppProvider` and `AlertAggregator` support deterministic integration tests and can be replaced by a real provider.

The dashboard shows, for every monitored directory, two node-and-edge trees side by side: the **Original** tree (the baseline snapshot taken when monitoring started) on the left and the **Modified** tree (the latest snapshot, after the interval) on the right. Every folder node is expandable/collapsible by clicking it (plus "Expand all" / "Collapse all"); folders containing a change start expanded so nothing is hidden. Nodes are coloured and labelled: green `+` created, red `–` deleted (shown dashed as a ghost in the Modified tree), orange `~` modified, purple `R`/`M` renamed/moved (shown at the old location in Original and the new one in Modified). A summary of all changes (counts per kind, before/after file/folder/byte totals, and a per-path list) is pinned at the bottom; "Set Latest as New Baseline" starts a fresh comparison. Modification details include previous/current byte size and content-hash evidence when available. Polling snapshots hash regular files (streamed in chunks) for this testable configuration; for very large trees, disable or move hashing to a bounded worker strategy before production deployment.

`FSEventsWatcher` is an adapter seam; consumers should resnapshot after FSEvents hints. The SwiftUI host uses the interval-based `PollingWatcher` so it remains usable without additional entitlements. The default interval is two minutes and can be changed at any time from the sidebar. While monitoring, an FSEvents watcher triggers a debounced rescan whenever files change, so the trees update live inside the interval; the periodic snapshot is a full verification pass.

## Build and run
Requires macOS 13+, Swift 5.9+. Run `swift run ChangeLinkSelfTest` for the deterministic suite, `swift test` for XCTest-enabled toolchains, then `swift run ChangeLinkApp`. SQLite is linked from the system library.

## LaunchAgent
`Scripts/install-launchagent.sh` and `Scripts/uninstall-launchagent.sh` manage a per-user agent. Review and customize the plist before deployment. A real app may need `com.apple.security.files.user-selected.read-write` (or security-scoped bookmarks) and notification entitlements. Full-disk access is a user privacy decision and cannot be granted by this package.

## Attribution and privacy
Do not infer a process from timestamps, usernames, or path activity. Only add `.process` when independently verified evidence exists (for example, an explicitly authorized audit source), and preserve that evidence string. Credentials belong outside source control; copy `.env.example` and use a secure secret store.
