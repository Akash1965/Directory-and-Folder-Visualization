import Foundation
import ChangeLinkCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

func record(_ path: String, _ id: String, size: Int64 = 1) -> FileRecord {
    FileRecord(path: path, fileID: id, size: size,
               modificationDate: Date(timeIntervalSince1970: 1), isDirectory: false)
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

let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("change-link-self-test-\(UUID())")
try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryRoot) }
try Data("test".utf8).write(to: temporaryRoot.appendingPathComponent(".hidden"))
let snapshot = Snapshotter.take(root: temporaryRoot, hashContents: true)
expect(snapshot.files[".hidden"]?.contentHash != nil, "hidden file and hash")

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
