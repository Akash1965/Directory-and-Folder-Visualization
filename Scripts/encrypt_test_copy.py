#!/usr/bin/env python3
"""Copy one file into a test folder and encrypt the COPY, leaving the original untouched.

This is for exercising ChangeLink's detection of an in-place "encrypted" change (same path,
same name, content and size change) without ever touching your real file.

Usage:
    python3 encrypt_test_copy.py --source "/Users/akash/Desktop/Lab ML/xsxssxsxxsssx.csv" \
                                  --dest-dir "/Users/akash/Desktop/ChaosTest"

What it does:
    1. Copies <source> into <dest-dir>, keeping the same filename.
    2. Takes a "before" snapshot of that copy (size, SHA-256).
    3. Encrypts the copy in place with a random key (stdlib-only stream cipher built on
       SHA-256 in counter mode — the same approach used by Scripts/chaos_modifier.py in
       this project; not a production cipher, just enough to change size/content realistically).
    4. Takes an "after" snapshot and prints both, so you can compare against what ChangeLink
       reports for that path.
    5. Saves the key to <dest-dir>/<filename>.key so you can decrypt the copy again if you want
       to inspect it (the cipher is symmetric and self-inverse: running it twice with the same
       key restores the original bytes).

The original file at --source is only ever read, never written.
"""
import argparse
import hashlib
import os
import secrets
import shutil
import sys
from datetime import datetime


def stamp():
    now = datetime.now()
    return now.strftime("%Y-%m-%d %H:%M:%S.") + f"{now.microsecond // 1000:03d}"


def keystream_xor(data: bytes, key: bytes) -> bytes:
    """SHA-256-based stream cipher in counter mode. Symmetric: applying it twice with the
    same key returns the original bytes. Not a real cryptographic cipher — a stand-in used
    only to produce a realistic-looking "encrypted" change for testing."""
    out = bytearray()
    for block_index, offset in enumerate(range(0, len(data), 32)):
        pad = hashlib.sha256(key + block_index.to_bytes(8, "big")).digest()
        chunk = data[offset:offset + 32]
        out.extend(b ^ p for b, p in zip(chunk, pad))
    return bytes(out)


def describe(path: str) -> dict:
    with open(path, "rb") as f:
        data = f.read()
    return {"path": path, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", required=True, help="the real file to copy from (read-only)")
    ap.add_argument("--dest-dir", required=True, help="test folder the copy is written into")
    ap.add_argument("--decrypt", action="store_true",
                     help="instead of encrypting, decrypt the copy using the saved .key file")
    args = ap.parse_args()

    source = os.path.abspath(os.path.expanduser(args.source))
    dest_dir = os.path.abspath(os.path.expanduser(args.dest_dir))

    if not os.path.isfile(source):
        sys.exit(f"Source file not found: {source}")
    os.makedirs(dest_dir, exist_ok=True)

    filename = os.path.basename(source)
    copy_path = os.path.join(dest_dir, filename)
    key_path = copy_path + ".key"

    if args.decrypt:
        if not os.path.isfile(copy_path) or not os.path.isfile(key_path):
            sys.exit(f"Nothing to decrypt: expected {copy_path} and {key_path}")
        key = bytes.fromhex(open(key_path).read().strip())
        before = describe(copy_path)
        with open(copy_path, "rb") as f:
            data = f.read()
        with open(copy_path, "wb") as f:
            f.write(keystream_xor(data, key))
        after = describe(copy_path)
        print(f"[{stamp()}] Decrypted copy in place: {copy_path}")
        print(f"  before: {before['size']} bytes, sha256 {before['sha256']}")
        print(f"  after:  {after['size']} bytes, sha256 {after['sha256']}")
        return 0

    # Fresh copy each run, so repeated runs behave the same way.
    shutil.copy2(source, copy_path)
    print(f"[{stamp()}] Copied {source}")
    print(f"           -> {copy_path}  (original left untouched)")

    before = describe(copy_path)
    print(f"  before encryption: {before['size']} bytes, sha256 {before['sha256']}")

    key = secrets.token_bytes(32)
    with open(copy_path, "rb") as f:
        data = f.read()
    with open(copy_path, "wb") as f:
        f.write(keystream_xor(data, key))
    with open(key_path, "w") as f:
        f.write(key.hex())

    after = describe(copy_path)
    print(f"[{stamp()}] Encrypted the copy in place (same path, same filename).")
    print(f"  after encryption:  {after['size']} bytes, sha256 {after['sha256']}")
    print(f"  key saved to:      {key_path}")
    print()
    print("ChangeLink should report this as a single MODIFY event on:")
    print(f"  {os.path.relpath(copy_path, dest_dir)}")
    print(f"To restore the copy, run this script again with --decrypt.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
