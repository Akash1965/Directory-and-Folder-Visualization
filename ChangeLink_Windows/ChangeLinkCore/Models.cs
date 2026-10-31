using System;
using System.Collections.Generic;

namespace ChangeLinkCore
{
    /// <summary>Whether a tree node represents a file or a folder.</summary>
    public enum NodeKind
    {
        File,
        Directory
    }

    /// <summary>
    /// The five change types the comparator can report for one path. Declared in the same
    /// alphabetical order as the raw string values used by the macOS build ("create" &lt;
    /// "delete" &lt; "modify" &lt; "move" &lt; "rename"), since the comparator's tie-break sort
    /// relies on that order.
    /// </summary>
    public enum ChangeKind
    {
        Create,
        Delete,
        Modify,
        Move,
        Rename
    }

    /// <summary>
    /// A best-effort guess at what a Modify event actually did to a file's bytes.
    /// This is a heuristic read of size, a hash of the leading bytes, and Shannon
    /// entropy -- not a forensic determination. A determined actor can make any of
    /// these look like any other; see FORENSIC_LIMITATIONS.md.
    /// </summary>
    public enum ContentChangeKind
    {
        /// <summary>The file grew and its old bytes are still the start of the new file.</summary>
        Appended,
        /// <summary>The file shrank and its new bytes are the start of what used to be there.</summary>
        Truncated,
        /// <summary>The content looks close to statistically random and did not look that way before.</summary>
        LikelyEncrypted,
        /// <summary>The hash changed but none of the other signals point to append/truncate/encryption.</summary>
        ContentRewritten,
        /// <summary>Only metadata changed; the content hash is identical.</summary>
        MetadataOnly
    }

    public static class ContentChangeKindExtensions
    {
        public static string Label(this ContentChangeKind kind) => kind switch
        {
            ContentChangeKind.Appended => "appended",
            ContentChangeKind.Truncated => "truncated",
            ContentChangeKind.LikelyEncrypted => "likely encrypted",
            ContentChangeKind.ContentRewritten => "content rewritten",
            ContentChangeKind.MetadataOnly => "metadata only",
            _ => kind.ToString()
        };
    }

    /// <summary>
    /// One file or folder as observed during a scan. <see cref="FileId"/> is the NTFS
    /// file-index identity when it could be read (stable across renames and moves on
    /// the same volume), or a path-derived fallback otherwise -- the same trade-off the
    /// macOS build makes with <c>fileResourceIdentifier</c>.
    /// </summary>
    public sealed class FileRecord : IEquatable<FileRecord>
    {
        public string Path { get; }
        public string FileId { get; }
        public long Size { get; }
        public DateTime ModificationDate { get; }
        public bool IsDirectory { get; }
        public string? ContentHash { get; }
        public double? Entropy { get; }
        public string? PrefixHash { get; }
        public int? DistinctByteCount { get; }

        public FileRecord(
            string path, string fileId, long size, DateTime modificationDate, bool isDirectory,
            string? contentHash = null, double? entropy = null, string? prefixHash = null, int? distinctByteCount = null)
        {
            Path = path;
            FileId = fileId;
            Size = size;
            ModificationDate = modificationDate;
            IsDirectory = isDirectory;
            ContentHash = contentHash;
            Entropy = entropy;
            PrefixHash = prefixHash;
            DistinctByteCount = distinctByteCount;
        }

        public bool Equals(FileRecord? other)
        {
            if (other is null) return false;
            return Path == other.Path && FileId == other.FileId && Size == other.Size &&
                   ModificationDate == other.ModificationDate && IsDirectory == other.IsDirectory &&
                   ContentHash == other.ContentHash;
        }

        public override bool Equals(object? obj) => Equals(obj as FileRecord);

        public override int GetHashCode() => HashCode.Combine(Path, FileId, Size, ModificationDate, IsDirectory, ContentHash);
    }

    /// <summary>One scan of one monitored root: every file and folder below it, keyed by relative path.</summary>
    public sealed class Snapshot
    {
        public string Root { get; }
        public Dictionary<string, FileRecord> Files { get; }
        public DateTime TakenAt { get; }

        public Snapshot(string root, Dictionary<string, FileRecord> files, DateTime? takenAt = null)
        {
            Root = root;
            Files = files;
            TakenAt = takenAt ?? DateTime.Now;
        }
    }

    /// <summary>One detected difference between two snapshots of the same root.</summary>
    public sealed class ChangeEvent
    {
        public ChangeKind Kind { get; }
        public string Path { get; }
        public string? OldPath { get; }
        public string FileId { get; }
        public NodeKind NodeKind { get; }
        public long? PreviousSize { get; }
        public long? CurrentSize { get; }
        public bool ContentChanged { get; }
        public ContentChangeKind? ContentChangeKind { get; }
        public double? PreviousEntropy { get; }
        public double? CurrentEntropy { get; }
        public DateTime ObservedAt { get; }

        public ChangeEvent(
            ChangeKind kind, string path, string fileId, NodeKind nodeKind,
            string? oldPath = null, long? previousSize = null, long? currentSize = null,
            bool contentChanged = false, ContentChangeKind? contentChangeKind = null,
            double? previousEntropy = null, double? currentEntropy = null, DateTime? observedAt = null)
        {
            Kind = kind;
            Path = path;
            OldPath = oldPath;
            FileId = fileId;
            NodeKind = nodeKind;
            PreviousSize = previousSize;
            CurrentSize = currentSize;
            ContentChanged = contentChanged;
            ContentChangeKind = contentChangeKind;
            PreviousEntropy = previousEntropy;
            CurrentEntropy = currentEntropy;
            ObservedAt = observedAt ?? DateTime.Now;
        }
    }
}
