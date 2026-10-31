# Changelog

## Version 2

- Two top-to-bottom node-and-edge trees (Original and Modified) per monitored directory, light-blue circles joined by straight lines; every folder node expandable; a click acts on both trees.
- Changes shown live inside the interval (FSEvents with 0.5 s latency and 0.3 s debounce); interval timer kept as a full verification scan.
- Interval editable (seconds, minutes, hours) and changeable while monitoring without losing the baseline.
- Every modification of a file or folder is kept (per-node history, x N badge, popover, one summary row each); created-then-deleted items shown as ghost nodes.
- Summary panel with counts per type, distinct items, before/after totals; Hide/Show toggle; fit-to-pane scaling and zoom.
- Comparator fixes: hard links, folder-only modification time, rename vs move, consumed old paths.
- Scanner fixes: streamed 1 MiB SHA-256, hash reuse for unchanged files, failed scans keep the previous baseline.
- Fixed read-only interval field when started with `swift run` (regular activation policy).
- Fixed summary rows repeating one edit when a file had several modifications (unique row identifiers, plain list instead of lazy list).
- Clickable `Change-Link.app` with icon built by `Scripts/build-app.sh`.

## Summary panel, tree metrics and chaos tests

- The summary now shows, per monitored folder: what was there originally (files, folders, size), what is there now,
  and how many items were created, deleted, modified, renamed and moved.
- New side-by-side comparison of the original and modified tree: nodes, files, folders, leaves, depth, nodes per
  level (and the change per level), average depth, widest level, maximum fan-out, average branching factor, sizes,
  Jaccard path similarity, structural edit operations, items touched and the deepest changed level.
- The files and folders affected are listed under each change category (Created, Deleted, Modified, Renamed,
  Moved) with a millisecond timestamp for every modification.
- New `ChangeLinkChaosTest` target and `Scripts/chaos_modifier.py` apply random operations (including encryption)
  to a test folder and check the reported changes.
