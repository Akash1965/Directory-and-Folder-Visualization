using System;
using System.IO;
using System.Linq;
using ChangeLinkCore;

int passed = 0, failed = 0;

void Expect(bool condition, string label)
{
    if (condition) { passed++; }
    else { failed++; Console.WriteLine($"FAIL: {label}"); }
}

// --- Pure-function tests: ModificationClassifier ---

Expect(ModificationClassifier.Classify(100, 140, "abc", "abc", 3.0, 3.1, 10, 10, true) == ContentChangeKind.Appended, "appended: same prefix, grew");
Expect(ModificationClassifier.Classify(140, 100, "abc", "abc", 3.0, 3.1, 10, 10, true) == ContentChangeKind.Truncated, "truncated: same prefix, shrank");
Expect(ModificationClassifier.Classify(100, 100, "a", "b", 3.4, 3.4, 14, 14, false) == ContentChangeKind.MetadataOnly, "metadata only: content unchanged");
Expect(ModificationClassifier.Classify(100, 102, "a", "b", 3.5, 5.98, 14, 65, true) == ContentChangeKind.LikelyEncrypted,
    "likely encrypted: plain text -> Fernet-style output (alphabet-ratio path)");
Expect(ModificationClassifier.Classify(100, 102, "a", "b", 5.21, 4.71, 97, 90, true) == ContentChangeKind.ContentRewritten,
    "content rewritten: ordinary source-code-like rewrite");
Expect(ModificationClassifier.Classify(100, 102, "a", "b", 7.9, 7.95, 256, 256, true) == ContentChangeKind.ContentRewritten,
    "already-random content re-encrypted stays a rewrite, not a second \"encryption\"");

Expect(Math.Abs(ModificationClassifier.Entropy(new byte[] { 0, 0, 0, 0 }) - 0) < 1e-9, "entropy of a constant byte string is 0");
Expect(ModificationClassifier.Entropy(Enumerable.Range(0, 256).Select(i => (byte)i).ToArray()) > 7.9, "entropy of all 256 byte values is near the 8-bit maximum");

// --- End-to-end tests against a real temporary directory ---

string root = Path.Combine(Path.GetTempPath(), "ChangeLinkSelfTest_" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    Directory.CreateDirectory(Path.Combine(root, "docs"));
    File.WriteAllText(Path.Combine(root, "docs", "note.txt"), "hello,world,csv,like,content,with,enough,bytes,to,exceed,the,sixty,four,byte,prefix,window\n");

    var baseline = Snapshotter.TakeValidated(root, hashContents: true);
    Expect(baseline.Files.ContainsKey("docs"), "baseline sees the docs folder");
    Expect(baseline.Files.ContainsKey("docs/note.txt"), "baseline sees note.txt");

    // Create + modify (append).
    File.WriteAllText(Path.Combine(root, "docs", "new.txt"), "a brand new file\n");
    File.AppendAllText(Path.Combine(root, "docs", "note.txt"), "one more line appended at the end\n");
    var afterEdit = Snapshotter.TakeValidated(root, hashContents: true, baseline);
    var events1 = SnapshotComparator.Compare(baseline, afterEdit);
    Expect(events1.Any(e => e.Kind == ChangeKind.Create && e.Path == "docs/new.txt"), "create detected");
    var modifyEvent = events1.FirstOrDefault(e => e.Kind == ChangeKind.Modify && e.Path == "docs/note.txt");
    Expect(modifyEvent != null, "modify detected");

    // Rename.
    File.Move(Path.Combine(root, "docs", "new.txt"), Path.Combine(root, "docs", "renamed.txt"));
    var afterRename = Snapshotter.TakeValidated(root, hashContents: true, afterEdit);
    var events2 = SnapshotComparator.Compare(afterEdit, afterRename);
    Expect(events2.Any(e => e.Kind == ChangeKind.Rename && e.OldPath == "docs/new.txt" && e.Path == "docs/renamed.txt"), "rename detected, not delete+create");

    // Delete.
    File.Delete(Path.Combine(root, "docs", "renamed.txt"));
    var afterDelete = Snapshotter.TakeValidated(root, hashContents: true, afterRename);
    var events3 = SnapshotComparator.Compare(afterRename, afterDelete);
    Expect(events3.Any(e => e.Kind == ChangeKind.Delete && e.Path == "docs/renamed.txt"), "delete detected");

    // Hash reuse: an untouched file should keep the same hash object across scans.
    Expect(afterDelete.Files["docs/note.txt"].ContentHash == afterRename.Files["docs/note.txt"].ContentHash, "hash reused for an unchanged file");

    // Tree diff + metrics, accumulating the whole run's change log.
    var changeLog = events1.Concat(events2).Concat(events3).ToList();
    var diff = DirectoryTreeDiff.Build(root, baseline, afterDelete, changeLog, baseline.TakenAt, afterDelete.TakenAt);
    Expect(diff.Original.Children.All(c => c.Status == NodeStatus.Unchanged), "original tree shows baseline structure only, no change marks");
    Expect(diff.Summary.Total == changeLog.Count, "summary counts every logged event");

    var comparison = diff.Comparison;
    Expect(comparison.Original.Files >= 1 && comparison.Modified.Files >= 1, "tree-comparison metrics computed for both trees");
    Expect(comparison.StructuralOperations == comparison.CreatedCount + comparison.DeletedCount + comparison.RenamedCount + comparison.MovedCount,
        "structural edit cost is the sum of its four components");
}
finally
{
    Directory.Delete(root, recursive: true);
}

Console.WriteLine($"ChangeLinkSelfTest: {(failed == 0 ? "PASS" : "FAIL")} ({passed} passed, {failed} failed)");
Environment.Exit(failed == 0 ? 0 : 1);
