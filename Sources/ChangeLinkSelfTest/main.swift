import Foundation
import ChangeLinkCore
#if canImport(CryptoKit)
import CryptoKit
#endif

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

func record(_ path: String, _ id: String, size: Int64 = 1) -> FileRecord {
    FileRecord(path: path, fileID: id, size: size,
               modificationDate: Date(timeIntervalSince1970: 1), isDirectory: false)
}

func pollingDetectsModification(root: URL) throws -> Bool {
    let file = root.appendingPathComponent("observed.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("baseline".utf8).write(to: file)

    let poller = PollingWatcher()
    let signal = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var detected = false
    try poller.start(root: root, interval: 0.1) { changes in
        let found = changes.contains {
            $0.path == "observed.txt" && $0.kind == .modify && $0.contentChanged
        }
        if found {
            lock.lock()
            detected = true
            lock.unlock()
            signal.signal()
        }
    }
    Thread.sleep(forTimeInterval: 0.15)
    try Data("modified during monitoring".utf8).write(to: file)
    let completed = signal.wait(timeout: .now() + 5) == .success
    poller.stop()
    lock.lock()
    let result = detected
    lock.unlock()
    return completed && result
}

let root = URL(fileURLWithPath: "/")
let empty = Snapshot(root: root, files: [:])
let created = Snapshot(root: root, files: ["new": record("new", "new-id")])
expect(SnapshotComparator.compare(empty, created).contains { $0.kind == .create }, "create")
expect(SnapshotComparator.compare(created, empty).contains { $0.kind == .delete }, "delete")

let modified = Snapshot(root: root, files: ["new": record("new", "new-id", size: 2)])
expect(SnapshotComparator.compare(created, modified).contains { $0.kind == .modify }, "modify")

let renamed = Snapshot(root: root, files: ["renamed": record("renamed", "new-id")])
expect(SnapshotComparator.compare(created, renamed).contains { $0.kind == .rename }, "rename")

// Tree diff: both trees show every change and the summary counts them.
do {
    let dir = { (p: String) in FileRecord(path: p, fileID: "dir-" + p, size: 0, modificationDate: Date(timeIntervalSince1970: 1), isDirectory: true) }
    let old = Snapshot(root: root, files: ["d": dir("d"), "d/gone": record("d/gone", "g"), "d/edit": record("d/edit", "e"), "d/old": record("d/old", "o")])
    let new = Snapshot(root: root, files: ["d": dir("d"), "d/edit": record("d/edit", "e", size: 9), "d/new": record("d/new", "n"), "d/renamed": record("d/renamed", "o")])
    let diff = DirectoryTreeDiff.build(rootPath: "/x/proj", baseline: old, current: new)
    func find(_ node: TreeNode, _ id: String) -> TreeNode? {
        if node.id == id { return node }
        for child in node.children { if let hit = find(child, id) { return hit } }
        return nil
    }
    expect(find(diff.original, "d/gone")?.status == .unchanged && find(diff.original, "d/gone")?.history.isEmpty == true, "original shows structure only (no change marks)")
    expect(find(diff.original, "d/new") == nil, "original lacks created")
    expect(find(diff.modified, "d/new")?.status == .created, "modified shows created")
    expect(find(diff.modified, "d/gone")?.isGhost == true, "modified shows deleted ghost")
    expect(find(diff.modified, "d/renamed")?.status == .renamed && find(diff.original, "d/old")?.status == .unchanged, "rename is marked in the modified tree only")
    expect(diff.summary.total == 4, "summary counts all changes")

    // Tree comparison metrics (root + d + 3 files on both sides; one level-2 row of three nodes).
    let c = diff.comparison
    expect(c.original.nodes == 5 && c.modified.nodes == 5, "node counts (root included)")
    expect(c.original.files == 3 && c.original.directories == 1, "original file and folder counts")
    expect(c.original.height == 2 && c.modified.height == 2, "tree depth")
    expect(c.original.levels == [1, 1, 3] && c.modified.levels == [1, 1, 3], "nodes per level")
    expect(c.levelRows.allSatisfy { $0.delta == 0 }, "level change is zero when only names changed")
    expect(c.original.maxFanOut == 3 && c.original.widestLevel == 2, "fan-out and widest level")
    expect(abs(c.original.averageBranching - 2.0) < 1e-9, "average branching factor")
    expect(c.createdCount == 1 && c.deletedCount == 1 && c.renamedCount == 1 && c.structuralOperations == 3,
           "structural edit operations")
    expect(c.contentModifications == 1, "content modification count")
    expect(abs(c.pathSimilarity - 1.0 / 3.0) < 1e-9 && c.commonPaths == 2 && c.unionPaths == 6, "Jaccard path similarity")
    expect(c.deepestChangeDepth == 2, "deepest change level")
    expect(diff.summary.entries(of: .create, includeImplied: true).count == 1, "entries are grouped by category")
}

// Growth in depth and width shows up in the comparison.
do {
    let dir = { (p: String) in FileRecord(path: p, fileID: "dir-" + p, size: 0, modificationDate: Date(timeIntervalSince1970: 1), isDirectory: true) }
    let old = Snapshot(root: root, files: ["a": dir("a")])
    let new = Snapshot(root: root, files: ["a": dir("a"), "a/b": dir("a/b"), "a/b/c": dir("a/b/c"), "a/b/c/f": record("a/b/c/f", "f", size: 8)])
    let c = DirectoryTreeDiff.build(rootPath: "/x/deep", baseline: old, current: new).comparison
    expect(c.original.height == 1 && c.modified.height == 4, "depth change")
    expect(c.levelRows.map { $0.delta } == [0, 0, 1, 1, 1], "level change per depth")
    expect(c.createdCount == 3 && c.modified.files == 1 && c.modified.bytes == 8, "created counts and size")
}

// Several modifications of the same item are all kept in the tree history and the summary.
do {
    let t0 = Date(timeIntervalSince1970: 100)
    let old = Snapshot(root: root, files: ["f": record("f", "1")])
    let new = Snapshot(root: root, files: ["g": record("g", "1", size: 30)])
    let history = [
        ChangeEvent(kind: .modify, path: "f", fileID: "1", previousSize: 1, currentSize: 10, contentChanged: true, observedAt: t0),
        ChangeEvent(kind: .modify, path: "f", fileID: "1", previousSize: 10, currentSize: 20, contentChanged: true, observedAt: t0 + 1),
        ChangeEvent(kind: .rename, oldPath: "f", path: "g", fileID: "1", previousSize: 20, currentSize: 20, observedAt: t0 + 2),
        ChangeEvent(kind: .modify, path: "g", fileID: "1", previousSize: 20, currentSize: 30, contentChanged: true, observedAt: t0 + 3)
    ]
    let diff = DirectoryTreeDiff.build(rootPath: "/x", baseline: old, current: new, history: history)
    expect(diff.modified.children.first?.history.count == 4, "all modifications attached to the node")
    expect(diff.summary.entries.count == 4 && diff.summary.itemCount == 1, "summary lists every modification of one item")
    expect(Set(diff.summary.entries.map { $0.id }).count == 4 && Set(diff.summary.entries.map { $0.detail }).count == 4,
           "every summary entry is distinct (unique id and detail)")
}

// A folder that only existed to hold a deleted item (and was since renamed) is drawn as a ghost, not a real folder.
do {
    let dir = { (p: String) in FileRecord(path: p, fileID: "dir-" + p, size: 0, modificationDate: Date(timeIntervalSince1970: 1), isDirectory: true) }
    let old = Snapshot(root: root, files: ["a": dir("a")])
    let new = Snapshot(root: root, files: ["a": dir("a"), "a/y": FileRecord(path: "a/y", fileID: "dir-a/x", size: 0, modificationDate: Date(timeIntervalSince1970: 1), isDirectory: true)])
    let t0 = Date(timeIntervalSince1970: 500)
    let history = [
        ChangeEvent(kind: .create, path: "a/x", fileID: "dir-a/x", nodeKind: .directory, observedAt: t0),
        ChangeEvent(kind: .create, path: "a/x/f", fileID: "f", currentSize: 4, observedAt: t0 + 1),
        ChangeEvent(kind: .delete, path: "a/x/f", fileID: "f", previousSize: 4, observedAt: t0 + 2),
        ChangeEvent(kind: .rename, oldPath: "a/x", path: "a/y", fileID: "dir-a/x", nodeKind: .directory, observedAt: t0 + 3)
    ]
    let diff = DirectoryTreeDiff.build(rootPath: "/x/ghost", baseline: old, current: new, history: history)
    func find(_ node: TreeNode, _ id: String) -> TreeNode? {
        if node.id == id { return node }
        for child in node.children { if let hit = find(child, id) { return hit } }
        return nil
    }
    expect(find(diff.modified, "a/x")?.isGhost == true, "folder that only holds a deleted item is a ghost")
    expect(diff.comparison.modified.nodes == 3, "ghost folders are not counted as nodes")
}

// Modification classifier: pure-function cases.
do {
    func classify(size0: Int64, size1: Int64, prefix0: String?, prefix1: String?, e0: Double?, e1: Double?) -> ContentChangeKind {
        ModificationClassifier.classify(previousSize: size0, currentSize: size1, previousPrefixHash: prefix0,
                                        currentPrefixHash: prefix1, previousEntropy: e0, currentEntropy: e1, contentChanged: true)
    }
    expect(classify(size0: 100, size1: 150, prefix0: "p", prefix1: "p", e0: 4.5, e1: 4.6) == .appended,
           "same prefix + grew = appended")
    expect(classify(size0: 150, size1: 50, prefix0: "p", prefix1: "p", e0: 4.5, e1: 4.4) == .truncated,
           "same prefix + shrank = truncated")
    expect(classify(size0: 1000, size1: 1000, prefix0: "a", prefix1: "b", e0: 4.8, e1: 7.95) == .likelyEncrypted,
           "low entropy -> near-random entropy = likely encrypted")
    expect(classify(size0: 1000, size1: 1000, prefix0: "a", prefix1: "b", e0: 7.9, e1: 7.95) == .contentRewritten,
           "already-random content staying random is not flagged as newly encrypted")
    expect(classify(size0: 1000, size1: 1000, prefix0: "a", prefix1: "b", e0: 4.8, e1: 5.1) == .contentRewritten,
           "an ordinary rewrite is not flagged as encryption")
    expect(ModificationClassifier.classify(previousSize: 10, currentSize: 10, previousPrefixHash: "x", currentPrefixHash: "x",
                                           previousEntropy: 4, currentEntropy: 4, contentChanged: false) == .metadataOnly,
           "no content change = metadata only")

    // base64-style ciphertext (Fernet, PGP ASCII-armor, JWTs, ...) caps raw 8-bit entropy around 6
    // bits/byte, well under highEntropyThreshold, but uses its ~65-symbol alphabet almost perfectly
    // evenly — unlike plain text or code, which use a similar-sized alphabet very unevenly. Numbers
    // below are the measurements in TESTING.md (real Fernet output on real text).
    expect(ModificationClassifier.classify(previousSize: 2080, currentSize: 2872, previousPrefixHash: "a", currentPrefixHash: "b",
                                           previousEntropy: 3.49, currentEntropy: 5.98,
                                           previousDistinctByteCount: 14, currentDistinctByteCount: 65,
                                           contentChanged: true) == .likelyEncrypted,
           "base64/Fernet-style output is detected as likely encrypted even though its raw entropy is only ~6 bits/byte")
    expect(ModificationClassifier.classify(previousSize: 22326, currentSize: 22326, previousPrefixHash: "a", currentPrefixHash: "b",
                                           previousEntropy: 5.21, currentEntropy: 4.71,
                                           previousDistinctByteCount: 97, currentDistinctByteCount: 90,
                                           contentChanged: true) == .contentRewritten,
           "ordinary source code, which also uses dozens of distinct bytes, is not mistaken for encoded data")
    expect(ModificationClassifier.classify(previousSize: 2872, currentSize: 2872, previousPrefixHash: "a", currentPrefixHash: "b",
                                           previousEntropy: 5.98, currentEntropy: 5.99,
                                           previousDistinctByteCount: 65, currentDistinctByteCount: 65,
                                           contentChanged: true) == .contentRewritten,
           "already base64/encoded-looking content staying that way is not re-flagged as newly encrypted")
    let text = Data(String(repeating: "the quick brown fox, ", count: 500).utf8)
    let random = Data((0..<text.count).map { _ in UInt8.random(in: 0...255) })
    expect(ModificationClassifier.entropy(of: text) < 5.5, "repetitive ASCII text has low entropy")
    expect(ModificationClassifier.entropy(of: random) > 7.5, "uniformly random bytes have high entropy")
}

let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("change-link-self-test-\(UUID())")
try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryRoot) }
try Data("test".utf8).write(to: temporaryRoot.appendingPathComponent(".hidden"))
let snapshot = try Snapshotter.takeValidated(root: temporaryRoot, hashContents: true)
expect(snapshot.files[".hidden"]?.contentHash != nil, "hidden file and hash")
try Data("x".utf8).write(to: temporaryRoot.appendingPathComponent(".hidden"))
let changedSnapshot = try Snapshotter.takeValidated(root: temporaryRoot, hashContents: true)
let observedChange = SnapshotComparator.compare(snapshot, changedSnapshot).first { $0.path == ".hidden" }
expect(observedChange?.kind == .modify, "manual and scheduled scans compare successive snapshots")
expect(observedChange?.previousSize == 4 && observedChange?.currentSize == 1, "size decrease is reported")
expect(observedChange?.contentChanged == true, "content hash difference is reported")

// End-to-end: a real text edit is not flagged as encryption, and a real "encryption" (XOR with a
// SHA-256 keystream, same trick the chaos tools use) of real text is.
do {
    let textFile = temporaryRoot.appendingPathComponent("notes.csv")
    let originalText = String(repeating: "name,value,timestamp\nfox,42,2026-01-01\n", count: 400)
    try Data(originalText.utf8).write(to: textFile)
    let before = try Snapshotter.takeValidated(root: temporaryRoot, hashContents: true)

    try Data((originalText + "fox,43,2026-01-02\n").utf8).write(to: textFile)
    let afterEdit = try Snapshotter.takeValidated(root: temporaryRoot, hashContents: true)
    let editEvent = SnapshotComparator.compare(before, afterEdit).first { $0.path == "notes.csv" }
    expect(editEvent?.contentChangeKind != .likelyEncrypted, "an ordinary text edit is not flagged as encryption")

    func keystreamXOR(_ data: Data, key: Data) -> Data {
        var out = Data(capacity: data.count)
        var block: UInt64 = 0
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: 32, limitedBy: data.endIndex) ?? data.endIndex
            var hasher = SHA256(); hasher.update(data: key); hasher.update(data: withUnsafeBytes(of: block.bigEndian) { Data($0) })
            let pad = Data(hasher.finalize())
            var padIndex = pad.startIndex
            for i in index..<end { out.append(data[i] ^ pad[padIndex]); padIndex = pad.index(after: padIndex) }
            index = end; block += 1
        }
        return out
    }
    let plain = try Data(contentsOf: textFile)
    try keystreamXOR(plain, key: Data((0..<32).map { _ in UInt8.random(in: 0...255) })).write(to: textFile)
    let afterEncrypt = try Snapshotter.takeValidated(root: temporaryRoot, hashContents: true, reusingHashesFrom: afterEdit)
    let encryptEvent = SnapshotComparator.compare(afterEdit, afterEncrypt).first { $0.path == "notes.csv" }
    expect(encryptEvent?.contentChangeKind == .likelyEncrypted,
           "scrambling real text content in place is detected as likely encrypted")

    // The same, but "encrypt" by base64-encoding scrambled bytes, like Fernet/PGP ASCII-armor do.
    // This caps raw entropy around 6 bits/byte (below highEntropyThreshold on its own), so this test
    // exists specifically to confirm the alphabet-ratio check catches it.
    try Data(originalText.utf8).write(to: textFile)
    let beforeArmored = try Snapshotter.takeValidated(root: temporaryRoot, hashContents: true)
    let scrambled = keystreamXOR(Data(originalText.utf8), key: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    try Data(scrambled.base64EncodedString().utf8).write(to: textFile)
    let afterArmored = try Snapshotter.takeValidated(root: temporaryRoot, hashContents: true, reusingHashesFrom: beforeArmored)
    let armoredEvent = SnapshotComparator.compare(beforeArmored, afterArmored).first { $0.path == "notes.csv" }
    expect(armoredEvent?.currentEntropy ?? 8 < ModificationClassifier.highEntropyThreshold,
           "base64-encoded ciphertext really does stay under the raw entropy threshold, as the real Fernet test did")
    expect(armoredEvent?.contentChangeKind == .likelyEncrypted,
           "base64-encoded ciphertext (Fernet-style) is still caught, via the alphabet-ratio check")

    try? FileManager.default.removeItem(at: textFile)
}

let pollingRoot = temporaryRoot.appendingPathComponent("polling")
let pollingResult = try pollingDetectsModification(root: pollingRoot)
expect(pollingResult, "scheduled poll compares the real filesystem with its baseline")

var rejectedUnavailableRoot = false
do {
    _ = try Snapshotter.takeValidated(
        root: temporaryRoot.appendingPathComponent("unavailable-root"),
        hashContents: true
    )
} catch {
    rejectedUnavailableRoot = true
}
expect(rejectedUnavailableRoot, "unavailable root is rejected")

let dbURL = temporaryRoot.appendingPathComponent("history.sqlite")
let store = try ChangeStore(url: dbURL)
try store.save(snapshot: snapshot)
let attributed = AttributedChange(change: ChangeEvent(kind: .create, path: ".hidden", fileID: "hidden"))
try store.insert(attributed)
let provider = MockWhatsAppProvider()
try await provider.send(AlertAggregator().message(for: [attributed]))
let messageCount = await provider.messages.count
expect(messageCount == 1, "mock WhatsApp")

print("ChangeLinkSelfTest: PASS")
