import Foundation
import CryptoKit
import ChangeLinkCore

// ChangeLinkChaosTest
//
// Applies a random mix of file-system operations (create, append, overwrite, AES encryption, rename,
// move, delete, folder create/rename/move/delete) to a scratch directory. After every single operation
// it takes a real snapshot, compares it with the previous one and checks that ChangeLink reported
// exactly the events that operation must cause. At the end it builds the original/modified trees,
// checks the totals, the tree metrics and the per-category summary, and prints a timestamped timeline.
//
// Usage:  swift run ChangeLinkChaosTest [--ops 60] [--seed 42] [--dir /path/to/empty/folder] [--delay 0.5] [--keep]
//   --dir   use this (empty or new) folder, e.g. one the app is monitoring; it is never cleaned up
//   --delay seconds to wait between operations, so the live app can show each step

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct Expected: Hashable {
    let kind: ChangeKind
    let old: String?
    let path: String
}

struct Step {
    let name: String
    let expected: Set<Expected>
    /// When set, every MODIFY event this step produces must be classified as one of these kinds
    /// (checked against ChangeEvent.contentChangeKind in the main loop).
    var expectedChangeKinds: Set<ContentChangeKind>? = nil
}

// MARK: - Arguments

let args = CommandLine.arguments
func option(_ name: String) -> String? {
    if let index = args.firstIndex(of: name), index + 1 < args.count { return args[index + 1] }
    return nil
}
let opCount = Int(option("--ops") ?? "") ?? 60
let seed = UInt64(option("--seed") ?? "") ?? UInt64.random(in: 1...UInt64.max)
let delay = Double(option("--delay") ?? "") ?? 0
let userDirectory = option("--dir")
let keep = args.contains("--keep") || userDirectory != nil
var rng = SplitMix64(state: seed)

let root: URL = userDirectory.map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.temporaryDirectory.appendingPathComponent("changelink-chaos-\(seed)")
let fm = FileManager.default
try fm.createDirectory(at: root, withIntermediateDirectories: true)
guard try fm.contentsOfDirectory(atPath: root.path).isEmpty else {
    print("Refusing to run: \(root.path) is not empty. Pass an empty or new folder.")
    exit(2)
}

// MARK: - Model of what should exist

var files = Set<String>()
var dirs = Set<String>()
var serial = 0
var pendingLock: String?
let key = SymmetricKey(size: .bits256)

func parent(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
}
func lastComponent(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}
func join(_ dir: String, _ name: String) -> String { dir.isEmpty ? name : dir + "/" + name }
func fresh(_ prefix: String, _ ext: String = "") -> String {
    serial += 1
    return "\(prefix)\(serial)\(ext)"
}
func url(_ path: String) -> URL { root.appendingPathComponent(path) }
func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }
func randomData(_ lower: Int, _ upper: Int) -> Data {
    let length = Int(rng.next() % UInt64(upper - lower + 1)) + lower
    return Data((0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
}
/// Plausible document content (CSV-like rows of common English words), not uniformly random bytes.
/// Real documents have low Shannon entropy (typically 4-5 bits/byte); only encryption/compression
/// pushes that near 8. Using real-looking text here is what lets the "likely encrypted" classifier
/// in ModificationClassifier.swift mean something in this test.
let words = ["alpha","beta","gamma","delta","report","value","status","folder","change","link",
             "project","reading","sensor","result","sample","total","entry","record","note","event"]
func textLikeData(_ lowerRows: Int, _ upperRows: Int) -> Data {
    let rows = Int(rng.next() % UInt64(upperRows - lowerRows + 1)) + lowerRows
    var text = ""
    for _ in 0..<rows {
        let fields = (0..<4).map { _ in pick(words) }
        text += fields.joined(separator: ",") + ",\(rng.next() % 10000)\n"
    }
    return Data(text.utf8)
}
func descendants(of dir: String) -> [String] {
    (files.union(dirs)).filter { $0.hasPrefix(dir + "/") }.sorted()
}
func depth(_ path: String) -> Int { path.split(separator: "/").count }

/// Renames/moves `old` (a file or folder) to `new` and returns the events every affected path must produce.
func relocate(_ old: String, _ new: String) throws -> Set<Expected> {
    let affected = [old] + descendants(of: old)
    try fm.moveItem(at: url(old), to: url(new))
    var expected = Set<Expected>()
    for path in affected {
        let target = new + String(path.dropFirst(old.count))
        let kind: ChangeKind = parent(path) == parent(target) ? .rename : .move
        expected.insert(Expected(kind: kind, old: path, path: target))
        if files.remove(path) != nil { files.insert(target) }
        if dirs.remove(path) != nil { dirs.insert(target) }
    }
    return expected
}

// MARK: - Operations

func makeFile() throws -> Step {
    let dir = pick([""] + dirs.sorted())
    let path = join(dir, fresh("doc", pick([".txt", ".log", ".csv", ".docx"])))
    try textLikeData(3, 60).write(to: url(path))      // at least 3 rows: comfortably past the 64-byte prefix window
    files.insert(path)
    return Step(name: "create file", expected: [Expected(kind: .create, old: nil, path: path)])
}

func makeFolder() throws -> Step {
    let dir = pick([""] + dirs.sorted().filter { depth($0) < 4 })
    let path = join(dir, fresh("folder"))
    try fm.createDirectory(at: url(path), withIntermediateDirectories: false)
    dirs.insert(path)
    return Step(name: "create folder", expected: [Expected(kind: .create, old: nil, path: path)])
}

func appendToFile() throws -> Step {
    let path = pick(files.sorted())
    let handle = try FileHandle(forWritingTo: url(path))
    try handle.seekToEnd()
    try handle.write(contentsOf: textLikeData(1, 20))
    try handle.close()
    return Step(name: "append to file", expected: [Expected(kind: .modify, old: nil, path: path)],
                expectedChangeKinds: [.appended])
}

func overwriteFile() throws -> Step {
    let path = pick(files.sorted())
    try textLikeData(1, 60).write(to: url(path))      // in place: same file identity, different content
    return Step(name: "overwrite file", expected: [Expected(kind: .modify, old: nil, path: path)])
    // Not asserted on expectedChangeKind: depending on the random content this can come out as
    // "appended" (if the new text happens to start the same way), "truncated" or "content rewritten".
}

func encryptFile() throws -> Step {
    let path = pick(files.sorted())
    let plain = try Data(contentsOf: url(path))
    let sealed = try AES.GCM.seal(plain, using: key).combined!
    try sealed.write(to: url(path))                    // in place, like ransomware does
    pendingLock = path
    return Step(name: "encrypt file (AES-GCM)", expected: [Expected(kind: .modify, old: nil, path: path)],
                // .contentRewritten covers the rare case of re-encrypting an already-random file
                // (its entropy was already high, so no new entropy jump is detected — by design).
                expectedChangeKinds: [.likelyEncrypted, .contentRewritten])
}

func lockRename(_ path: String) throws -> Step {
    let new = path + ".locked"
    let expected = try relocate(path, new)
    return Step(name: "append .locked extension", expected: expected)
}

func renameFile() throws -> Step {
    let path = pick(files.sorted())
    let ext = (lastComponent(path) as NSString).pathExtension
    let new = join(parent(path), fresh("renamed", ext.isEmpty ? "" : "." + ext))
    return Step(name: "rename file", expected: try relocate(path, new))
}

func moveFile() throws -> Step? {
    let path = pick(files.sorted())
    let targets = ([""] + dirs.sorted()).filter { $0 != parent(path) }
    guard !targets.isEmpty else { return nil }
    let new = join(pick(targets), lastComponent(path))
    return Step(name: "move file", expected: try relocate(path, new))
}

func deleteFile() throws -> Step {
    let path = pick(files.sorted())
    try fm.removeItem(at: url(path))
    files.remove(path)
    return Step(name: "delete file", expected: [Expected(kind: .delete, old: nil, path: path)])
}

func deleteFolder() throws -> Step {
    let dir = pick(dirs.sorted())
    let affected = [dir] + descendants(of: dir)
    try fm.removeItem(at: url(dir))
    for path in affected { files.remove(path); dirs.remove(path) }
    return Step(name: "delete folder (\(affected.count - 1) inside)",
                expected: Set(affected.map { Expected(kind: .delete, old: nil, path: $0) }))
}

func renameFolder() throws -> Step {
    let dir = pick(dirs.sorted())
    let new = join(parent(dir), fresh("folder"))
    return Step(name: "rename folder", expected: try relocate(dir, new))
}

func moveFolder() throws -> Step? {
    let dir = pick(dirs.sorted())
    let targets = ([""] + dirs.sorted()).filter { $0 != dir && !$0.hasPrefix(dir + "/") && $0 != parent(dir) }
    guard !targets.isEmpty else { return nil }
    let new = join(pick(targets), lastComponent(dir))
    return Step(name: "move folder", expected: try relocate(dir, new))
}

func randomStep() throws -> Step {
    if let locked = pendingLock {
        pendingLock = nil
        if files.contains(locked), rng.next() % 5 != 0 { return try lockRename(locked) }
    }
    while true {
        var choices: [() throws -> Step?] = [makeFile, makeFile, makeFolder]
        if !files.isEmpty {
            choices += [appendToFile, overwriteFile, encryptFile, encryptFile, renameFile, moveFile, deleteFile]
        }
        if !dirs.isEmpty { choices += [deleteFolder, renameFolder, moveFolder] }
        if let step = try pick(choices)() { return step }
    }
}

// MARK: - Run

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("  CHECK FAILED: \(message)") }
}
func describe(_ event: ChangeEvent) -> String {
    let arrow = event.oldPath.map { "\($0) -> " } ?? ""
    return "\(event.kind.rawValue.uppercased().padding(toLength: 6, withPad: " ", startingAt: 0)) \(arrow)\(event.path)"
}

print("ChangeLink chaos test  seed=\(seed)  ops=\(opCount)")
print("Folder: \(root.path)\n")

// Initial content = the baseline.
for _ in 0..<3 { _ = try makeFolder() }
for _ in 0..<8 { _ = try makeFile() }
pendingLock = nil
let startedAt = Date()
var previous = try Snapshotter.takeValidated(root: root, hashContents: true)
let baseline = previous
let baselineFiles = files.count
let baselineDirs = dirs.count
print("Baseline: \(baselineFiles) files, \(baselineDirs) folders at \(ChangeStamp.text(baseline.takenAt))\n")

var history: [ChangeEvent] = []
var lastStepEnd = Date.distantPast
var timeline: [(Int, String, ChangeEvent)] = []
for index in 1...opCount {
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    let step = try randomStep()
    Thread.sleep(forTimeInterval: 0.01)
    let current = try Snapshotter.takeValidated(root: root, hashContents: true, reusingHashesFrom: previous)
    let events = SnapshotComparator.compare(previous, current)
    let got = Set(events.map { Expected(kind: $0.kind, old: $0.oldPath, path: $0.path) })
    print("#\(index)  \(step.name)")
    for event in events {
        print("      \(ChangeStamp.text(event.observedAt))  \(describe(event))")
        timeline.append((index, step.name, event))
    }
    check(got == step.expected && events.count == step.expected.count,
          "step #\(index) '\(step.name)': expected \(step.expected.map { "\($0.kind.rawValue) \($0.path)" }.sorted()), got \(events.map { "\($0.kind.rawValue) \($0.path)" }.sorted())")
    for event in events where event.kind == .modify {
        print("        modification type: \(event.contentChangeKind?.label ?? "?")  (entropy \(event.previousEntropy.map { String(format: "%.2f", $0) } ?? "?") -> \(event.currentEntropy.map { String(format: "%.2f", $0) } ?? "?") bits/byte)")
        if let expectedKinds = step.expectedChangeKinds {
            check(event.contentChangeKind.map(expectedKinds.contains) == true,
                  "step #\(index) '\(step.name)': expected modification type in \(expectedKinds.map(\.label)), got \(event.contentChangeKind?.label ?? "nil")")
        }
    }
    if let first = events.map({ $0.observedAt }).min() {
        check(first >= lastStepEnd, "step #\(index) timestamps are not earlier than the previous step's")
    }
    if let last = events.map({ $0.observedAt }).max() { lastStepEnd = max(lastStepEnd, last) }
    history.append(contentsOf: events)
    previous = current
}
let finished = Date()

// MARK: - Final checks on trees, metrics and summary

let final = previous
print("\n=== Final comparison ===")
check(Set(final.files.keys) == files.union(dirs), "final snapshot matches the model of the folder")
let diff = DirectoryTreeDiff.build(rootPath: root.path, baseline: baseline, current: final, history: history)
let summary = diff.summary
let comparison = diff.comparison

check(summary.before.files == baselineFiles && summary.before.directories == baselineDirs, "original totals")
check(summary.after.files == files.count && summary.after.directories == dirs.count, "final totals")
check(summary.total + summary.impliedCount == history.count, "every event is counted once (or marked implied)")
let listed = ChangeKind.allCases.reduce(0) { $0 + summary.entries(of: $1, includeImplied: true).count }
check(listed == history.count, "every event is listed under its category")
check(comparison.original.nodes == baselineFiles + baselineDirs + 1, "original node count")
check(comparison.modified.nodes == files.count + dirs.count + 1, "modified node count")
check(comparison.original.levels.reduce(0, +) == comparison.original.nodes, "original levels add up to the node count")
check(comparison.modified.levels.reduce(0, +) == comparison.modified.nodes, "modified levels add up to the node count")
check(comparison.original.files == baselineFiles && comparison.modified.files == files.count, "file counts from the trees")
let deepestPath = max(files.map(depth).max() ?? 0, dirs.map(depth).max() ?? 0)
check(comparison.modified.height == deepestPath, "modified depth equals the deepest path")
check(history.allSatisfy { $0.observedAt >= startedAt && $0.observedAt <= finished }, "timestamps fall inside the run")

print("Originally: \(summary.before.files) files, \(summary.before.directories) folders")
print("Now:        \(summary.after.files) files, \(summary.after.directories) folders")
print("Changes:    " + ChangeKind.allCases.map { "\($0.rawValue) \(summary.counts[$0] ?? 0)" }.joined(separator: ", ")
      + "  (\(summary.total) modifications, \(summary.impliedCount) implied by a folder move/rename)")
let o = comparison.original, m = comparison.modified
print(String(format: "Depth %d -> %d | nodes %d -> %d | leaves %d -> %d | max fan-out %d -> %d | avg branching %.2f -> %.2f | avg depth %.2f -> %.2f",
             o.height, m.height, o.nodes, m.nodes, o.leaves, m.leaves, o.maxFanOut, m.maxFanOut,
             o.averageBranching, m.averageBranching, o.averageDepth, m.averageDepth))
print("Nodes per level: \(o.levels) -> \(m.levels)")
print(String(format: "Path similarity %.1f%% | structural operations %d | deepest change at level %d",
             comparison.pathSimilarity * 100, comparison.structuralOperations, comparison.deepestChangeDepth))

print("\n=== Items under each category (with timestamps) ===")
for kind in ChangeKind.allCases {
    let rows = summary.entries(of: kind, includeImplied: true)
    guard !rows.isEmpty else { continue }
    print("\n\(kind.rawValue.uppercased()) (\(rows.count))")
    for row in rows { print("  \(ChangeStamp.text(row.event.observedAt))  \(row.event.path)  [\(row.detail)]") }
}

if !keep { try? fm.removeItem(at: root) }
if failures == 0 {
    print("\nChangeLinkChaosTest: PASS (\(opCount) random operations, seed \(seed))")
} else {
    print("\nChangeLinkChaosTest: FAIL (\(failures) check(s)), re-run with --seed \(seed) --keep to reproduce")
    exit(1)
}
