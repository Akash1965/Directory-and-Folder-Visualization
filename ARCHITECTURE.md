# Architecture

The core is platform-isolated behind `Snapshotter`, `SnapshotComparator`, `ChangeWatcher`, `AlertProvider`, and `ChangeStore`. A snapshot is a keyed map of relative paths to metadata and stable resource IDs. Comparison first matches IDs (to identify rename/move), then paths (to identify modify), giving deterministic events. The UI is a thin SwiftUI consumer and has no filesystem authority.

FSEvents integration is intentionally an adapter seam: event paths are hints and a fresh snapshot is required for correctness. `PollingWatcher` is the documented fallback. A host may schedule either adapter and persist snapshots between launches.
