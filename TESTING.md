# Testing

## Automated

```sh
swift run ChangeLinkSelfTest   # prints "ChangeLinkSelfTest: PASS"
swift test                     # XCTest suite (needs a full Xcode toolchain to run the tests)
```

The self-test covers: create, delete, modify and rename/move by resource identifier; hard links (a new link is a creation); folder-only modification-time changes (ignored); several modifications of one item (all kept, with distinct summary entries); items created and deleted before the next scan (ghost nodes); tree construction for both trees; hidden-file traversal and SHA-256 hashing; unavailable root; SQLite persistence; and the mock WhatsApp provider.

## Manual checklist (graphical application)

| # | Action | Expected |
|---|--------|----------|
| 1 | Launch the app | Empty dashboard, legend and empty summary |
| 2 | Type 10, choose Seconds, press Apply | Status line: "Snapshot interval set to 10 seconds" |
| 3 | Add Directory, Start Monitoring | Baseline captured; identical Original and Modified trees |
| 4 | Create a file in the folder | Green node appears in the Modified tree within a few seconds, before the interval ends |
| 5 | Rewrite one file three times | x3 badge; three separate summary rows; popover lists all three |
| 6 | Rewrite a file with same-length text | Modify, "content changed" (hash differs, size does not) |
| 7 | Click a folder node in either tree | Folder collapses/expands in both trees (+N badge when collapsed) |
| 8 | Filter = Modify | Only modifications listed in the sidebar |
| 9 | Load Demo Output | Create, modify, rename, move and delete shown in both trees and in the summary |
| 10 | Hide summary, zoom in/out, Fit | Trees resize; summary toggles |

## Random-modification (chaos) tests

Two programs apply a random mix of operations (create, append, overwrite, AES/stream encryption, add a `.locked`
extension, rename, move, delete, and the same for folders) to a scratch folder and check what ChangeLink reports.

**1. Swift test against the real ChangeLink code**

    swift run ChangeLinkChaosTest --ops 80 --seed 42

After every operation it takes a real snapshot, compares it with the previous one and checks that exactly the
expected events appear (including the implied move events of everything inside a renamed or moved folder). At the
end it builds the original and modified trees and checks the totals, node counts, level counts, depth, the category
lists and that timestamps are ordered and inside the run. Every event is printed with a millisecond timestamp.
Options: `--ops N`, `--seed N` (repeat a run), `--dir PATH` (an empty folder, for example one the app watches),
`--delay S` (pause between operations), `--keep`.

**2. Python generator for watching the live app**

    python3 Scripts/chaos_modifier.py --dir ~/Desktop/ChaosTest --ops 40 --delay 1.0

Add `~/Desktop/ChaosTest` to ChangeLink first, then run this. Each operation is printed and appended to
`chaos_log.jsonl` with a timestamp, so the log can be compared with the app's summary. `--verify` runs the same
checks as the Swift test with a Python port of the comparison rules and prints the tree metrics.

## Tree-comparison metrics

`TreeMetrics` and `TreeComparison` (in `ChangeLinkCore/TreeMetrics.swift`) are covered by `ChangeLinkSelfTest`:
node, file, folder and leaf counts, depth (height), nodes per level and their change, average depth, widest level,
maximum fan-out, average branching factor, total and average size, Jaccard path similarity, structural edit
operations and the depth of the deepest change.

## Modification-type classification (ModificationClassifier.swift)

Every content change (a MODIFY event) is additionally classified as appended, truncated, likely encrypted, or
content rewritten, using only cheap signals already computed while hashing a file: its size, a hash of a small
fixed leading window (to catch an append or a truncation without re-reading the file), the Shannon entropy of up
to its first 1 MiB, and how many of the 256 possible byte values appear in that sample.

Two separate tests feed the "likely encrypted" threshold, because one signal alone misses a common real case:

| Content | raw entropy (bits/byte) | distinct bytes | entropy ÷ log2(distinct) |
|---|---|---|---|
| Plain CSV-like text | 3.49 | 14 | 0.92 |
| English prose | 4.32 | 29 | 0.89 |
| Swift source code | 5.21 | 97 | 0.79 |
| Python source code | 4.71 | 90 | 0.73 |
| Real CSV (first 1 MiB) | 5.00 | 67 | 0.83 |
| `os.urandom` (true random bytes) | 7.89 | 256 | 0.99 |
| AES/stream-cipher output | 7.9–8.0 | 256 | 0.99 |
| `base64.b64encode(random bytes)` | 5.98 | 64 | 1.00 |
| **Fernet** (`cryptography.fernet`) token of real text | 5.98 | 65 | 0.99 |

Raw random bytes and AES/stream-cipher ciphertext sit near 8 bits/byte, well clear of ordinary content (`highEntropyThreshold = 7.3`). But a large family of real tools — Fernet, PGP ASCII-armor, JWTs, plain `base64` — encrypt or compress and then re-encode the result into text using a restricted alphabet (base64's 64–76 symbols). That caps the raw entropy at `log2(alphabet size)`, around 6 bits/byte, which is *below* `highEntropyThreshold` and would be missed by entropy alone.

What doesn't disappear is that the output uses its alphabet almost perfectly evenly. The last column above divides entropy by the maximum entropy possible for however many distinct byte values actually appeared — 1.0 is perfectly uniform. Encoded/encrypted content sits at 0.99–1.00; ordinary text and code sit at 0.73–0.92 even when they use a similarly large alphabet (code uses 90–97 distinct bytes but very unevenly). `ModificationClassifier` flags content as "likely encrypted" if it newly crosses *either* bar: raw entropy ≥ 7.3, or (at least 40 distinct bytes and ratio ≥ 0.95) — and only when the content did *not* already look that way, so re-encrypting an already-random or already-encoded file is reported as an ordinary rewrite, not a second "encryption".

`ChangeLinkSelfTest` includes both an end-to-end check with a real stream-cipher pass over real text, and one that base64-encodes the scrambled bytes (the Fernet case) to confirm the alphabet-ratio check catches what the raw-entropy check alone would miss.
