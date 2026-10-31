#!/usr/bin/env python3
"""Random file-system "chaos" generator for testing ChangeLink.

Applies a random mix of operations to an EMPTY test folder: create file, create folder, append, overwrite,
encrypt (stream cipher, ransomware style), add a .locked extension, rename, move, delete, and the same for
folders. Every operation is written to a log with a millisecond timestamp, so you can compare it with
what ChangeLink shows.

Usage:
  python3 Scripts/chaos_modifier.py --dir ~/Desktop/ChaosTest --ops 40 --delay 1.0
      Point ChangeLink at ~/Desktop/ChaosTest first. --delay is the pause (seconds) between operations.
  python3 Scripts/chaos_modifier.py --verify --ops 200 --seed 7
      Self-check: snapshots after every operation, classifies the changes with the same rules as
      ChangeLink (file identity + size + mtime + SHA-256) and checks they match what was done.

Options: --dir PATH  --ops N  --seed N  --delay S  --log FILE.jsonl  --verify  --keep
The script refuses to run in a folder that already contains files.
"""
import argparse, collections, hashlib, json, math, os, random, shutil, sys, tempfile, time
from datetime import datetime


def stamp(t=None):
    t = time.time() if t is None else t
    return datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M:%S.") + f"{int((t % 1) * 1000):03d}"


def keystream_xor(data: bytes, key: bytes) -> bytes:
    """Stdlib-only stream cipher (SHA-256 in counter mode); stands in for real encryption."""
    out = bytearray()
    for block in range(0, len(data), 32):
        pad = hashlib.sha256(key + block.to_bytes(8, "big")).digest()
        chunk = data[block:block + 32]
        out.extend(b ^ p for b, p in zip(chunk, pad))
    return bytes(out)


WORDS = ["alpha", "beta", "gamma", "delta", "report", "value", "status", "folder", "change", "link",
         "project", "reading", "sensor", "result", "sample", "total", "entry", "record", "note", "event"]

# Must match ModificationClassifier.swift: a small FIXED window so appending bytes past it (or
# shortening down to it) leaves the hash unchanged.
PREFIX_WINDOW = 64
HIGH_ENTROPY = 7.3
# Many real tools (Fernet, PGP ASCII-armor, JWTs, plain base64) encrypt/compress then re-encode into
# a restricted text alphabet, which caps raw entropy around 6 bits/byte -- below HIGH_ENTROPY. What
# doesn't disappear is that the output uses its (larger than plain-text) alphabet almost perfectly
# evenly. See TESTING.md for the measurements behind these two thresholds.
ALPHABET_RATIO_THRESHOLD = 0.95
MIN_ALPHABET_SIZE_FOR_RATIO_CHECK = 40


def shannon_entropy(data: bytes):
    if not data:
        return 0.0, 0
    sample = data[:1 << 20]
    counts = collections.Counter(sample)
    n = len(sample)
    entropy = -sum((c / n) * math.log2(c / n) for c in counts.values())
    return entropy, len(counts)


def prefix_hash(data: bytes) -> bytes:
    return hashlib.md5(data[:PREFIX_WINDOW]).digest()


def looks_encoded_or_random(entropy, distinct_byte_count) -> bool:
    if entropy is None:
        return False
    if entropy >= HIGH_ENTROPY:
        return True
    if not distinct_byte_count or distinct_byte_count < MIN_ALPHABET_SIZE_FOR_RATIO_CHECK:
        return False
    return (entropy / math.log2(distinct_byte_count)) >= ALPHABET_RATIO_THRESHOLD


def classify_change(prev_size, cur_size, prev_prefix, cur_prefix,
                     prev_entropy, cur_entropy, prev_distinct=None, cur_distinct=None) -> str:
    """Mirrors ModificationClassifier.classify in ChangeLinkCore."""
    same_prefix = prev_prefix is not None and prev_prefix == cur_prefix
    if same_prefix and cur_size > prev_size:
        return "appended"
    if same_prefix and cur_size < prev_size:
        return "truncated"
    was = looks_encoded_or_random(prev_entropy, prev_distinct)
    is_now = looks_encoded_or_random(cur_entropy, cur_distinct)
    if is_now and not was:
        return "likely encrypted"
    return "content rewritten"


class Chaos:
    def __init__(self, root, seed, log_path):
        self.root, self.rng, self.serial = root, random.Random(seed), 0
        self.files, self.dirs = set(), set()
        self.pending_lock = None
        self.key = bytes(self.rng.getrandbits(8) for _ in range(32))
        self.log = open(log_path, "w") if log_path else None
        self.index = 0

    # ---- helpers
    def p(self, rel): return os.path.join(self.root, rel)
    @staticmethod
    def parent(rel): return rel.rsplit("/", 1)[0] if "/" in rel else ""
    @staticmethod
    def last(rel): return rel.rsplit("/", 1)[-1]
    @staticmethod
    def join(d, n): return n if not d else d + "/" + n
    def fresh(self, prefix, ext=""):
        self.serial += 1
        return f"{prefix}{self.serial}{ext}"
    def data(self, lo, hi): return bytes(self.rng.getrandbits(8) for _ in range(self.rng.randint(lo, hi)))
    def text_data(self, lo_rows, hi_rows):
        """Plausible CSV-like document content, not uniformly random bytes: real documents have low
        Shannon entropy (~4-5 bits/byte), so only encryption/compression later pushes it near 8."""
        rows = self.rng.randint(lo_rows, hi_rows)
        lines = []
        for _ in range(rows):
            fields = [self.rng.choice(WORDS) for _ in range(4)]
            lines.append(",".join(fields) + f",{self.rng.randint(0, 9999)}")
        return ("\n".join(lines) + "\n").encode()
    def descendants(self, d): return sorted(x for x in self.files | self.dirs if x.startswith(d + "/"))
    def depth(self, rel): return rel.count("/") + 1

    def record(self, op, expected, note=""):
        """expected: set of (kind, old, path). Logged with a timestamp."""
        self.index += 1
        entry = {"n": self.index, "time": stamp(), "epoch": time.time(), "operation": op, "note": note,
                 "events": sorted([{"kind": k, "old": o, "path": n} for k, o, n in expected],
                                  key=lambda e: (e["path"], e["kind"]), )}
        if self.log:
            self.log.write(json.dumps(entry) + "\n"); self.log.flush()
        return entry

    def relocate(self, old, new):
        affected = [old] + self.descendants(old)
        os.rename(self.p(old), self.p(new))
        expected = set()
        for x in affected:
            target = new + x[len(old):]
            kind = "rename" if self.parent(x) == self.parent(target) else "move"
            expected.add((kind, x, target))
            if x in self.files: self.files.discard(x); self.files.add(target)
            if x in self.dirs: self.dirs.discard(x); self.dirs.add(target)
        return expected

    # ---- operations (each returns (name, expected) or None)
    def make_file(self):
        d = self.rng.choice([""] + sorted(self.dirs))
        rel = self.join(d, self.fresh("doc", self.rng.choice([".txt", ".log", ".csv", ".docx"])))
        # At least 3 rows so the file comfortably exceeds the 64-byte prefix window used to detect
        # appends later.
        with open(self.p(rel), "wb") as f: f.write(self.text_data(3, 60))
        self.files.add(rel); return "create file", {("create", None, rel)}

    def make_folder(self):
        d = self.rng.choice([""] + [x for x in sorted(self.dirs) if self.depth(x) < 4])
        rel = self.join(d, self.fresh("folder"))
        os.mkdir(self.p(rel)); self.dirs.add(rel); return "create folder", {("create", None, rel)}

    def append(self):
        rel = self.rng.choice(sorted(self.files))
        with open(self.p(rel), "ab") as f: f.write(self.text_data(1, 20))
        return "append to file", {("modify", None, rel)}

    def overwrite(self):
        rel = self.rng.choice(sorted(self.files))
        with open(self.p(rel), "r+b") as f:
            f.seek(0); f.truncate(); f.write(self.text_data(1, 60))
        return "overwrite file", {("modify", None, rel)}

    def encrypt(self):
        rel = self.rng.choice(sorted(self.files))
        with open(self.p(rel), "r+b") as f:
            plain = f.read(); f.seek(0); f.truncate(); f.write(keystream_xor(plain, self.key))
        self.pending_lock = rel
        return "encrypt file", {("modify", None, rel)}

    def lock_rename(self, rel):
        return "append .locked extension", self.relocate(rel, rel + ".locked")

    def rename_file(self):
        rel = self.rng.choice(sorted(self.files))
        ext = os.path.splitext(self.last(rel))[1]
        return "rename file", self.relocate(rel, self.join(self.parent(rel), self.fresh("renamed", ext)))

    def move_file(self):
        rel = self.rng.choice(sorted(self.files))
        targets = [t for t in [""] + sorted(self.dirs) if t != self.parent(rel)]
        if not targets: return None
        return "move file", self.relocate(rel, self.join(self.rng.choice(targets), self.last(rel)))

    def delete_file(self):
        rel = self.rng.choice(sorted(self.files))
        os.remove(self.p(rel)); self.files.discard(rel)
        return "delete file", {("delete", None, rel)}

    def delete_folder(self):
        d = self.rng.choice(sorted(self.dirs))
        affected = [d] + self.descendants(d)
        shutil.rmtree(self.p(d))
        for x in affected: self.files.discard(x); self.dirs.discard(x)
        return f"delete folder ({len(affected) - 1} inside)", {("delete", None, x) for x in affected}

    def rename_folder(self):
        d = self.rng.choice(sorted(self.dirs))
        return "rename folder", self.relocate(d, self.join(self.parent(d), self.fresh("folder")))

    def move_folder(self):
        d = self.rng.choice(sorted(self.dirs))
        targets = [t for t in [""] + sorted(self.dirs)
                   if t != d and not t.startswith(d + "/") and t != self.parent(d)]
        if not targets: return None
        return "move folder", self.relocate(d, self.join(self.rng.choice(targets), self.last(d)))

    def step(self):
        if self.pending_lock:
            rel, self.pending_lock = self.pending_lock, None
            if rel in self.files and self.rng.random() > 0.2:
                return self.lock_rename(rel)
        while True:
            choices = [self.make_file, self.make_file, self.make_folder]
            if self.files:
                choices += [self.append, self.overwrite, self.encrypt, self.encrypt,
                            self.rename_file, self.move_file, self.delete_file]
            if self.dirs:
                choices += [self.delete_folder, self.rename_folder, self.move_folder]
            result = self.rng.choice(choices)()
            if result: return result


# ---- A port of ChangeLink's snapshot rules, used by --verify
# Each record: (fileID, size, mtime_ns, is_dir, contentHash, entropy, prefixHash, distinctByteCount)
def snapshot(root):
    snap = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            st = os.lstat(full)
            is_dir = os.path.isdir(full)
            h = entropy = phash = distinct = None
            if not is_dir:
                with open(full, "rb") as f: content = f.read()
                h = hashlib.sha256(content).hexdigest()
                entropy, distinct = shannon_entropy(content)
                phash = prefix_hash(content)
            snap[rel] = (f"{st.st_dev}:{st.st_ino}", st.st_size if not is_dir else 0, st.st_mtime_ns, is_dir,
                        h, entropy, phash, distinct)
    return snap


def compare(old, new):
    """Returns (events, modify_detail) where modify_detail maps a modified path to
    (classification, previous_entropy, current_entropy), mirroring ChangeEvent.contentChangeKind."""
    events, consumed, modify_detail = set(), set(), {}
    by_id = {}
    for p, r in old.items(): by_id.setdefault(r[0], []).append(p)
    for p in sorted(new):
        r = new[p]
        if p in old:
            if old[p] == r: continue
            if old[p][3] and r[3] and old[p][0] == r[0]: continue   # directory mtime only
            events.add(("modify", None, p))
            prev, cur = old[p], r
            kind = classify_change(prev[1], cur[1], prev[6], cur[6], prev[5], cur[5], prev[7], cur[7])
            modify_detail[p] = (kind, prev[5], cur[5])
        else:
            src = next((q for q in sorted(by_id.get(r[0], [])) if q not in new and q not in consumed), None)
            if src is not None:
                consumed.add(src)
                parent = lambda x: x.rsplit("/", 1)[0] if "/" in x else ""
                events.add(("rename" if parent(src) == parent(p) else "move", src, p))
            else:
                events.add(("create", None, p))
    for p in old:
        if p not in new and p not in consumed: events.add(("delete", None, p))
    return events, modify_detail


def metrics(snap):
    levels = {}
    for p in snap: levels[p.count("/") + 1] = levels.get(p.count("/") + 1, 0) + 1
    levels[0] = 1
    height = max(levels)
    children = {}
    for p in snap: children[Chaos.parent(p)] = children.get(Chaos.parent(p), 0) + 1
    nodes = len(snap) + 1
    return {"nodes": nodes, "files": sum(1 for r in snap.values() if not r[3]),
            "folders": sum(1 for r in snap.values() if r[3]), "height": height,
            "levels": [levels.get(d, 0) for d in range(height + 1)],
            "max_fan_out": max(children.values(), default=0),
            "avg_branching": round(sum(children.values()) / len(children), 2) if children else 0.0}


# Expected modification classification per operation name (only checked under --verify).
# "encrypt file" accepts "content rewritten" too: re-encrypting an already-random file produces
# no new entropy jump, so it is not re-flagged as newly encrypted (by design).
EXPECTED_CHANGE_KINDS = {
    "append to file": {"appended"},
    "encrypt file": {"likely encrypted", "content rewritten"},
}


def main():
    ap = argparse.ArgumentParser(description="Random file-system chaos for testing ChangeLink")
    ap.add_argument("--dir"); ap.add_argument("--ops", type=int, default=40)
    ap.add_argument("--seed", type=int, default=random.randrange(1, 10**9))
    ap.add_argument("--delay", type=float, default=0.0)
    ap.add_argument("--log", default="chaos_log.jsonl")
    ap.add_argument("--verify", action="store_true"); ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    root = os.path.abspath(os.path.expanduser(a.dir)) if a.dir else tempfile.mkdtemp(prefix="changelink-chaos-")
    os.makedirs(root, exist_ok=True)
    if os.listdir(root):
        sys.exit(f"Refusing to run: {root} is not empty. Pass an empty or new folder.")
    chaos = Chaos(root, a.seed, a.log)
    print(f"ChangeLink chaos run  seed={a.seed}  ops={a.ops}\nFolder: {root}\nLog: {os.path.abspath(a.log)}\n")

    for _ in range(3): chaos.make_folder()
    for _ in range(8): chaos.make_file()
    chaos.pending_lock = None
    chaos.index = 0
    prev = snapshot(root)
    baseline = prev
    print(f"Baseline at {stamp()}: {len(chaos.files)} files, {len(chaos.dirs)} folders\n")
    counts, failures, started = {}, 0, time.time()
    for i in range(1, a.ops + 1):
        if a.delay: time.sleep(a.delay)
        name, expected = chaos.step()
        entry = chaos.record(name, expected)
        print(f"#{i:<3} {entry['time']}  {name}")
        for k, o, n in sorted(expected, key=lambda e: (e[2], e[0])):
            print(f"        {k.upper():<6} {(o + ' -> ') if o else ''}{n}")
            counts[k] = counts.get(k, 0) + 1
        if a.verify:
            time.sleep(0.005)
            cur = snapshot(root)
            got, modify_detail = compare(prev, cur)
            if got != expected:
                failures += 1
                print(f"        MISMATCH expected {sorted(expected)} got {sorted(got)}")
            for path, (kind, prev_e, cur_e) in modify_detail.items():
                print(f"        modification type: {kind}  (entropy "
                      f"{'?' if prev_e is None else f'{prev_e:.2f}'} -> "
                      f"{'?' if cur_e is None else f'{cur_e:.2f}'} bits/byte)")
                expected_kinds = EXPECTED_CHANGE_KINDS.get(name)
                if expected_kinds and kind not in expected_kinds:
                    failures += 1
                    print(f"        MISMATCH modification type: expected one of {expected_kinds}, got {kind}")
            prev = cur
    print("\n=== Summary of what was done ===")
    print("Operations by event kind: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    print(f"Final state: {len(chaos.files)} files, {len(chaos.dirs)} folders")
    if a.verify:
        m0, m1 = metrics(baseline), metrics(prev)
        print("Tree metrics (original -> modified):")
        for k in m0: print(f"  {k:<14} {m0[k]} -> {m1[k]}")
        print(f"\nVerification: {'PASS' if failures == 0 else 'FAIL'} ({a.ops} operations, {failures} mismatches)")
    print(f"Run time {time.time() - started:.1f}s. Log written to {a.log}")
    if not a.keep and not a.dir: shutil.rmtree(root, ignore_errors=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
