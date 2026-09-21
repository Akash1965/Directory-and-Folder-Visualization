# ChangeLink for macOS

ChangeLink is a Swift Package containing a filesystem snapshot/comparison core and a SwiftUI macOS dashboard. It detects creates, deletes, modifications, renames, and moves by comparing stable `fileResourceIdentifier` values rather than path guesses. The paper-inspired temporal model is backed by SQLite and exposes explicit UNKNOWN attribution when process evidence is unavailable.

## Architecture
`Snapshotter` traverses a root and records metadata; `SnapshotComparator` emits `ChangeEvent`; `ChangeStore` persists events in system SQLite3; `AttributedChange` defaults to evidence-aware `UNKNOWN`. This is deliberate: FSEvents reports paths, not an authoritative responsible process. No process attribution is fabricated. `MockWhatsAppProvider` and `AlertAggregator` support deterministic integration tests and can be replaced by a real provider.

The dashboard renders the complete latest snapshot tree, not only changed paths. Changed nodes are marked in place with green (created), red (deleted), orange (modified), or purple (renamed/moved) indicators. Modification details include previous/current byte size and content-hash evidence when available. Polling snapshots hash regular files for this testable configuration; for very large trees, disable or move hashing to a bounded worker strategy before production deployment because hashing every file is more expensive than metadata-only scans.

`FSEventsWatcher` is an adapter seam; consumers should resnapshot after FSEvents hints. The SwiftUI host uses the interval-based `PollingWatcher` so it remains usable without additional entitlements. The default interval is one hour; the core accepts shorter intervals for testing.

## Build and run
Requires macOS 13+, Swift 5.9+. Run `swift run ChangeLinkSelfTest` for the deterministic suite, `swift test` for XCTest-enabled toolchains, then `swift run ChangeLinkApp`. SQLite is linked from the system library.

## LaunchAgent
`Scripts/install-launchagent.sh` and `Scripts/uninstall-launchagent.sh` manage a per-user agent. Review and customize the plist before deployment. A real app may need `com.apple.security.files.user-selected.read-write` (or security-scoped bookmarks) and notification entitlements. Full-disk access is a user privacy decision and cannot be granted by this package.

## Attribution and privacy
Do not infer a process from timestamps, usernames, or path activity. Only add `.process` when independently verified evidence exists (for example, an explicitly authorized audit source), and preserve that evidence string. Credentials belong outside source control; copy `.env.example` and use a secure secret store.
