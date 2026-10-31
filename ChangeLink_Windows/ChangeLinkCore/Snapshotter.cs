using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;

namespace ChangeLinkCore
{
    /// <summary>Thrown when a scan cannot be trusted and the previous baseline must be kept.</summary>
    public sealed class SnapshotException : Exception
    {
        public SnapshotException(string message) : base(message) { }
    }

    /// <summary>
    /// Walks a directory tree and records metadata (and, optionally, content hashes) for every
    /// item below it. Mirrors <c>Snapshotter.takeValidated</c> in the macOS build: the same
    /// prefix-window size, entropy sample limit and hash-reuse rule, so a snapshot taken here
    /// classifies modifications exactly the way the macOS report describes.
    /// </summary>
    public static class Snapshotter
    {
        /// <summary>
        /// Size of the fixed leading window hashed for the "prefix hash". Kept small (64 bytes)
        /// so append/truncate detection works even on small files: appending bytes past this
        /// window leaves the hash unchanged, and only an edit to the file's opening bytes
        /// changes it.
        /// </summary>
        public const int PrefixWindowSize = 64;

        /// <summary>First 1 MiB sampled for Shannon entropy -- enough to tell text/CSV apart
        /// from encrypted/compressed data without reading an arbitrarily large file in full.</summary>
        public const int EntropySampleLimit = 1 << 20;

        /// <summary>Size of each streamed read while hashing, so memory use does not depend on file size.</summary>
        public const int HashChunkSize = 1 << 20;

        public readonly struct ContentDigest
        {
            public readonly string Hash;
            public readonly string PrefixHash;
            public readonly double Entropy;
            public readonly int DistinctByteCount;

            public ContentDigest(string hash, string prefixHash, double entropy, int distinctByteCount)
            {
                Hash = hash;
                PrefixHash = prefixHash;
                Entropy = entropy;
                DistinctByteCount = distinctByteCount;
            }
        }

        /// <summary>
        /// One streamed pass over the file that produces everything a later modification can be
        /// classified from: the full-content SHA-256 hash, an MD5 hash of just the leading
        /// <see cref="PrefixWindowSize"/> bytes (to recognise an append or truncation without
        /// re-reading the whole file later), and the Shannon entropy of the first
        /// <see cref="EntropySampleLimit"/> bytes (to recognise content that now looks encrypted).
        /// </summary>
        public static ContentDigest Digest(string path)
        {
            using var sha256 = SHA256.Create();
            var counts = new int[256];
            int sampled = 0;
            byte[] prefix = Array.Empty<byte>();
            bool sawFirstChunk = false;

            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var buffer = new byte[HashChunkSize];
            int read;
            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                sha256.TransformBlock(buffer, 0, read, buffer, 0);

                if (!sawFirstChunk)
                {
                    int n = Math.Min(PrefixWindowSize, read);
                    prefix = new byte[n];
                    Array.Copy(buffer, 0, prefix, 0, n);
                    sawFirstChunk = true;
                }
                if (sampled < EntropySampleLimit)
                {
                    int take = Math.Min(read, EntropySampleLimit - sampled);
                    for (int i = 0; i < take; i++) counts[buffer[i]]++;
                    sampled += read;
                }
            }
            sha256.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
            string hash = Convert.ToHexString(sha256.Hash!).ToLowerInvariant();
            string prefixHash = Convert.ToHexString(MD5.HashData(prefix)).ToLowerInvariant();

            int distinct = 0;
            double total = 0;
            foreach (var c in counts) if (c > 0) { distinct++; total += c; }
            double entropy = 0;
            if (total > 0)
            {
                foreach (var c in counts)
                {
                    if (c == 0) continue;
                    double p = c / total;
                    entropy -= p * Math.Log2(p);
                }
            }
            return new ContentDigest(hash, prefixHash, entropy, distinct);
        }

        /// <summary>
        /// Scans <paramref name="root"/> and returns a validated snapshot, reusing content hashes
        /// (and the entropy/prefix-hash/distinct-byte-count that came from the same digest pass)
        /// from <paramref name="previous"/> whenever a file's identity, size and modification
        /// time have not changed. Throws <see cref="SnapshotException"/> if the root is missing,
        /// is not a directory, or enumeration fails outright -- the caller should keep the
        /// previous baseline in that case rather than infer deletions from an incomplete scan.
        /// Items that disappear mid-scan, or that can't be read, are skipped rather than failing
        /// the whole snapshot.
        /// </summary>
        public static Snapshot TakeValidated(string root, bool hashContents, Snapshot? previous = null)
        {
            if (!Directory.Exists(root))
                throw new SnapshotException($"The selected root is unavailable or is not a directory: {root}");

            var result = new Dictionary<string, FileRecord>();
            var rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

            IEnumerable<string> Walk(string dir)
            {
                IEnumerable<string> entries;
                try
                {
                    entries = Directory.EnumerateFileSystemEntries(dir);
                }
                catch (Exception ex)
                {
                    throw new SnapshotException($"Could not enumerate {dir}: {ex.Message}");
                }
                foreach (var entry in entries)
                {
                    yield return entry;
                    bool isDir;
                    try { isDir = Directory.Exists(entry) && !File.Exists(entry); }
                    catch { continue; }
                    if (isDir)
                    {
                        foreach (var child in Walk(entry)) yield return child;
                    }
                }
            }

            foreach (var full in Walk(rootFull))
            {
                bool isDirectory;
                long size;
                DateTime modified;
                try
                {
                    isDirectory = Directory.Exists(full) && !File.Exists(full);
                    if (isDirectory)
                    {
                        var di = new DirectoryInfo(full);
                        size = 0;
                        modified = di.LastWriteTime;
                    }
                    else
                    {
                        var fi = new FileInfo(full);
                        if (!fi.Exists) continue; // vanished between listing and inspection: a normal race
                        size = fi.Length;
                        modified = fi.LastWriteTime;
                    }
                }
                catch
                {
                    continue; // vanished, or unreadable: skip, do not fail the whole snapshot
                }

                string relative = full.Substring(rootFull.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                    .Replace(Path.DirectorySeparatorChar, '/');
                if (relative.Length == 0) continue;

                string id = FileIdentity.Resolve(full);

                string? hash = null; double? entropy = null; string? prefixHash = null; int? distinctByteCount = null;
                if (hashContents && !isDirectory)
                {
                    if (previous != null && previous.Files.TryGetValue(relative, out var old) &&
                        old.FileId == id && old.Size == size && old.ModificationDate == modified && old.ContentHash != null)
                    {
                        hash = old.ContentHash; entropy = old.Entropy; prefixHash = old.PrefixHash; distinctByteCount = old.DistinctByteCount;
                    }
                    else
                    {
                        try
                        {
                            var d = Digest(full);
                            hash = d.Hash; entropy = d.Entropy; prefixHash = d.PrefixHash; distinctByteCount = d.DistinctByteCount;
                        }
                        catch
                        {
                            // Unreadable file or broken link: leave content fields null rather than failing the scan.
                        }
                    }
                }

                result[relative] = new FileRecord(relative, id, size, modified, isDirectory, hash, entropy, prefixHash, distinctByteCount);
            }

            return new Snapshot(root, result);
        }
    }
}
