using System;

namespace ChangeLinkCore
{
    /// <summary>
    /// Classifies a content change using only cheap, already-computed signals: size, a hash of
    /// the leading bytes ("prefix hash"), and the entropy/alphabet size of a sample of the file.
    /// A direct port of the macOS build's <c>ModificationClassifier</c> -- same thresholds, same
    /// case-by-case logic -- so a file classified by this port and by the macOS app agree.
    /// This is a heuristic, not a forensic determination: evidence consistent with encryption,
    /// not proof of it.
    /// </summary>
    public static class ModificationClassifier
    {
        /// <summary>Byte values at or above this many bits/byte of raw Shannon entropy look
        /// statistically random (AES/stream-cipher output, already-compressed data).</summary>
        public const double HighEntropyThreshold = 7.3;

        /// <summary>Kept for parity with the macOS build; not used by <see cref="Classify"/> itself.</summary>
        public const double LowEntropyThreshold = 7.0;

        /// <summary>
        /// Many real tools (Fernet, PGP ASCII-armor, JWTs, plain base64) encrypt or compress
        /// data and then re-encode it into text using a fixed alphabet of around 64-96 symbols.
        /// That caps the raw 8-bit entropy at log2(alphabet size) -- roughly 6 bits/byte for
        /// base64 -- well under <see cref="HighEntropyThreshold"/>. What carries over is that the
        /// output uses its (larger than plain-text) alphabet almost perfectly evenly: entropy
        /// divided by log2(distinct byte values seen) sits close to 1.0, versus ~0.7-0.9 for
        /// ordinary text, code or CSV even when those also use dozens of distinct bytes.
        /// </summary>
        public const double AlphabetRatioThreshold = 0.95;

        public const int MinAlphabetSizeForRatioCheck = 40;

        /// <summary>Shannon entropy of <paramref name="data"/>, in bits per byte (0 for empty or
        /// single-valued data, up to 8 for uniformly random bytes).</summary>
        public static double Entropy(byte[] data)
        {
            if (data.Length == 0) return 0;
            var counts = new int[256];
            foreach (var b in data) counts[b]++;
            double total = data.Length;
            double sum = 0;
            foreach (var count in counts)
            {
                if (count == 0) continue;
                double p = count / total;
                sum -= p * Math.Log2(p);
            }
            return sum;
        }

        /// <summary>
        /// True when a sample looks like raw random/compressed data (entropy near 8 bits/byte)
        /// OR like encrypted-or-compressed data that was then text-encoded into a restricted
        /// alphabet (entropy close to the maximum possible for however many distinct byte values
        /// it actually uses).
        /// </summary>
        public static bool LooksEncodedOrRandom(double? entropy, int? distinctByteCount)
        {
            if (entropy is not double h) return false;
            if (h >= HighEntropyThreshold) return true;
            if (distinctByteCount is not int k || k < MinAlphabetSizeForRatioCheck) return false;
            double maxPossible = Math.Log2(k);
            if (maxPossible <= 0) return false;
            return (h / maxPossible) >= AlphabetRatioThreshold;
        }

        public static ContentChangeKind Classify(
            long previousSize, long currentSize,
            string? previousPrefixHash, string? currentPrefixHash,
            double? previousEntropy, double? currentEntropy,
            int? previousDistinctByteCount, int? currentDistinctByteCount,
            bool contentChanged)
        {
            if (!contentChanged) return ContentChangeKind.MetadataOnly;

            bool samePrefix = previousPrefixHash != null && previousPrefixHash == currentPrefixHash;
            if (samePrefix && currentSize > previousSize) return ContentChangeKind.Appended;
            if (samePrefix && currentSize < previousSize) return ContentChangeKind.Truncated;

            bool wasEncodedOrRandom = LooksEncodedOrRandom(previousEntropy, previousDistinctByteCount);
            bool isEncodedOrRandom = LooksEncodedOrRandom(currentEntropy, currentDistinctByteCount);
            if (isEncodedOrRandom && !wasEncodedOrRandom) return ContentChangeKind.LikelyEncrypted;
            return ContentChangeKind.ContentRewritten;
        }
    }
}
