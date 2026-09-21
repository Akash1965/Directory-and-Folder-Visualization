# Implementation mapping

| Practical capability | Implementation |
|---|---|
| State observation | `Snapshotter` metadata snapshots, including hidden files |
| Identity-preserving comparison | `SnapshotComparator` and `fileResourceIdentifier` |
| Event transport | `FSEventsWatcher` hint adapter; `PollingWatcher` fallback |
| Evidence policy | `Attribution.unknown` default and explicit evidence field |
| Durable state | SQLite snapshots, nodes-ready schema, changes, alerts, settings |
| Notification seam | `AlertProvider`, `MockWhatsAppProvider`, aggregation |
| Operator view | SwiftUI dashboard, roots, state filter, timeline and detail |
