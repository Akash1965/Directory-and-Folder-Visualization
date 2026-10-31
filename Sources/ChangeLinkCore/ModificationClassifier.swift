import Foundation

// MARK: - What kind of content change a modification looks like

/// A best-effort guess at what a MODIFY event actually did to a file's bytes. This is a heuristic
/// read of size, a hash of the leading bytes, and Shannon entropy — not a forensic determination.
/// See FORENSIC_LIMITATIONS.md: a determined actor can make any of these look like any other.
public enum ContentChangeKind: String, Codable, Sendable, CaseIterable {
    /// The file grew and its old bytes are still the start of the new file (a log line appended, etc.).
    case appended
    /// The file shrank and its new bytes are the start of what used to be there (truncated, cleared).
    case truncated
    /// The content looks close to statistically random — consistent with encryption or compression —
    /// and did not look that way before. This is the strongest signal this classifier gives.
    case likelyEncrypted
    /// The file's hash changed but the modification stamp or other attribute did not meaningfully move,
    /// or there isn't enough information (no entropy/prefix sample) to say more than "something changed".
    case contentRewritten
    /// Only metadata changed; the content hash is identical.
    case metadataOnly

    public var label: String {
        switch self {
        case .appended: return "appended"
        case .truncated: return "truncated"
        case .likelyEncrypted: return "likely encrypted"
        case .contentRewritten: return "content rewritten"
        case .metadataOnly: return "metadata only"
        }
    }
}

public enum ModificationClassifier {
    /// Byte values at or above this many bits/byte of raw Shannon entropy look statistically random.
    /// Plain text and most office/CSV content measured well under 6; AES/stream-cipher output and
    /// already-compressed data measure close to 8. See TESTING.md for the sample measurements used
    /// to pick this threshold.
    public static let highEntropyThreshold = 7.3
    /// Below this, content is confidently "not already random", so a later jump above a high-entropy
    /// or high-alphabet-ratio threshold is a meaningful change rather than noise around one boundary.
    public static let lowEntropyThreshold = 7.0
    /// Many real tools (Fernet, PGP ASCII-armor, JWTs, plain `base64`) encrypt or compress data and
    /// then re-encode it into text using a fixed alphabet of around 64-96 symbols. That caps the raw
    /// 8-bit entropy at log2(alphabet size) — roughly 6 bits/byte for base64 — well under
    /// `highEntropyThreshold`, so raw entropy alone misses it. What does carry over is that the
    /// output uses its (larger than plain-text) alphabet almost perfectly evenly: entropy divided by
    /// log2(distinct byte values seen) sits close to 1.0, versus ~0.7-0.9 for ordinary text, code or
    /// CSV even though those also use dozens of distinct bytes. See TESTING.md for the measurements
    /// (plain text ~0.72-0.92, Fernet/base64 output ~0.99) used to pick these two thresholds.
    public static let alphabetRatioThreshold = 0.95
    public static let minAlphabetSizeForRatioCheck = 40

    /// Shannon entropy of `data`, in bits per byte (0 for empty or single-valued data, up to 8 for
    /// uniformly random bytes).
    public static func entropy(of data: Data) -> Double {
        guard !data.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        for byte in data { counts[Int(byte)] += 1 }
        let total = Double(data.count)
        var sum = 0.0
        for count in counts where count > 0 {
            let p = Double(count) / total
            sum -= p * log2(p)
        }
        return sum
    }

    /// True when a sample's bytes look like raw random/compressed data (entropy near 8 bits/byte) OR
    /// like encrypted-or-compressed data that was then text-encoded into a restricted alphabet (entropy
    /// close to the maximum possible for however many distinct byte values it actually uses). Ordinary
    /// text, code and CSV score well below this even when they use a similarly sized alphabet, because
    /// their byte frequencies are skewed rather than close to uniform.
    static func looksEncodedOrRandom(entropy: Double?, distinctByteCount: Int?) -> Bool {
        guard let entropy else { return false }
        if entropy >= highEntropyThreshold { return true }
        guard let distinctByteCount, distinctByteCount >= minAlphabetSizeForRatioCheck else { return false }
        let maxPossible = log2(Double(distinctByteCount))
        guard maxPossible > 0 else { return false }
        return (entropy / maxPossible) >= alphabetRatioThreshold
    }

    /// Classifies a content change using only the cheap, already-computed signals kept in a
    /// `FileRecord`: size, a hash of the leading bytes ("prefix hash"), and the entropy/alphabet size
    /// of a sample of the file. None of these require re-reading the whole file at classification time.
    public static func classify(
        previousSize: Int64, currentSize: Int64,
        previousPrefixHash: String?, currentPrefixHash: String?,
        previousEntropy: Double?, currentEntropy: Double?,
        previousDistinctByteCount: Int? = nil, currentDistinctByteCount: Int? = nil,
        contentChanged: Bool
    ) -> ContentChangeKind {
        guard contentChanged else { return .metadataOnly }
        let samePrefix = previousPrefixHash != nil && previousPrefixHash == currentPrefixHash

        if samePrefix && currentSize > previousSize { return .appended }
        if samePrefix && currentSize < previousSize { return .truncated }

        let wasEncodedOrRandom = looksEncodedOrRandom(entropy: previousEntropy, distinctByteCount: previousDistinctByteCount)
        let isEncodedOrRandom = looksEncodedOrRandom(entropy: currentEntropy, distinctByteCount: currentDistinctByteCount)
        if isEncodedOrRandom && !wasEncodedOrRandom { return .likelyEncrypted }
        return .contentRewritten
    }
}
