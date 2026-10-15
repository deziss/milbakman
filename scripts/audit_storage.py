#!/usr/bin/env python3
"""
Read-only audit of a Milvus storage root (bucket prefix or local data dir).

Splits the data under the root into:
  CURRENT  binlogs of collections the running Milvus knows about. These are
           the only data milvus-backup copies.
  UNKNOWN  binlogs of collection IDs this Milvus does not know: an older
           Milvus that used the same bucket/root, or dropped collections not
           yet garbage-collected. Never included in backups.
  INDEX    index_files/ (not attributable by path; not part of backups,
           indexes are rebuilt on restore).
  OTHER    anything else under the root.
It also lists other top-level folders in the bucket (e.g. an old Milvus root).

Nothing is modified. Storage credentials come from AUDIT_ACCESS_KEY /
AUDIT_SECRET_KEY, Milvus credentials from MILVUS_USER / MILVUS_PASSWORD.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from migrate_s3 import LocalStore, S3Client, S3Error, describe_error  # noqa: E402


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.2f} {unit}"
        n /= 1024


def current_collections(host, port):
    """{collection_id: "db.collection"} for every database on the Milvus."""
    try:
        from pymilvus import MilvusClient
    except ImportError:
        raise S3Error("pymilvus is not installed: run via `milvus.sh audit`, or pass --collection-ids") from None

    client = MilvusClient(
        uri=f"http://{host}:{port}",
        user=os.environ.get("MILVUS_USER", ""),
        password=os.environ.get("MILVUS_PASSWORD", ""),
    )
    try:
        try:
            databases = client.list_databases()
        except Exception:
            databases = ["default"]  # servers without database support
        found = {}
        for db_name in databases:
            client.using_database(db_name)
            for name in client.list_collections():
                info = client.describe_collection(name)
                found[int(info["collection_id"])] = f"{db_name}.{name}"
        return found
    finally:
        client.close()


def scan(store, bucket, root, known):
    root = root.strip("/")
    kinds = {}        # kind -> {"current": [objects, bytes], "unknown": [...]}
    per_coll = {}     # collection id -> [objects, bytes]
    index = [0, 0]
    other = {}        # first path segment -> [objects, bytes]

    for obj in store.iter_objects(bucket, prefix=root):
        rel = obj["key"][len(root) + 1:] if root else obj["key"]
        parts = rel.split("/")
        kind, size = parts[0], obj["size"]
        if kind.endswith("_log") and len(parts) > 2 and parts[1].isdigit():
            coll = int(parts[1])
            side = "current" if coll in known else "unknown"
            entry = kinds.setdefault(kind, {"current": [0, 0], "unknown": [0, 0]})[side]
            entry[0] += 1
            entry[1] += size
            totals = per_coll.setdefault(coll, [0, 0])
            totals[0] += 1
            totals[1] += size
        elif kind == "index_files":
            index[0] += 1
            index[1] += size
        else:
            entry = other.setdefault(kind, [0, 0])
            entry[0] += 1
            entry[1] += size
    return kinds, per_coll, index, other


def main():
    p = argparse.ArgumentParser(description="Read-only audit of a Milvus storage root")
    p.add_argument("--milvus-host", default="localhost")
    p.add_argument("--milvus-port", default="19530")
    p.add_argument("--collection-ids", default="",
                   help="comma-separated IDs to treat as current (skips querying Milvus)")
    p.add_argument("--endpoint", help="S3 endpoint host:port")
    p.add_argument("--bucket")
    p.add_argument("--region", default="us-east-1")
    p.add_argument("--ssl", default="false", choices=["true", "false"])
    p.add_argument("--root", default="files", help="Milvus rootPath inside the bucket")
    p.add_argument("--local-dir", help="local-disk Milvus data dir (instead of a bucket)")
    p.add_argument("--top", type=int, default=20, help="unknown collection IDs to list")
    p.add_argument("--json", action="store_true")
    args = p.parse_args()

    if args.local_dir:
        store, bucket, root = LocalStore(args.local_dir), None, ""
        location = args.local_dir
    else:
        if not (args.endpoint and args.bucket):
            p.error("--endpoint and --bucket are required (or --local-dir)")
        key, secret = os.environ.get("AUDIT_ACCESS_KEY"), os.environ.get("AUDIT_SECRET_KEY")
        if not (key and secret):
            p.error("storage credentials missing: set AUDIT_ACCESS_KEY / AUDIT_SECRET_KEY")
        store = S3Client(args.endpoint, key, secret, args.region, args.ssl == "true")
        bucket, root = args.bucket, args.root.strip("/")
        location = f"s3://{bucket}/{root}"

    try:
        if args.collection_ids:
            known = {int(x): "-" for x in args.collection_ids.split(",") if x.strip()}
        else:
            known = current_collections(args.milvus_host, args.milvus_port)
        kinds, per_coll, index, other = scan(store, bucket, root, known)
        other_roots = [] if args.local_dir else [r for r in store.list_prefixes(bucket) if r != root]
    except S3Error as e:
        print(f"[AUDIT ERROR] {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"[AUDIT ERROR] {describe_error(e)}", file=sys.stderr)
        sys.exit(1)

    cur_bytes = sum(v["current"][1] for v in kinds.values())
    unk_bytes = sum(v["unknown"][1] for v in kinds.values())
    unknown_ids = sorted((c for c in per_coll if c not in known), key=lambda c: -per_coll[c][1])

    if args.json:
        print(json.dumps({
            "location": location,
            "current_collections": [
                {"id": c, "name": known[c], "objects": per_coll.get(c, [0, 0])[0], "bytes": per_coll.get(c, [0, 0])[1]}
                for c in sorted(known)
            ],
            "unknown_collections": [{"id": c, "objects": per_coll[c][0], "bytes": per_coll[c][1]} for c in unknown_ids],
            "by_kind": {k: {"current": {"objects": v["current"][0], "bytes": v["current"][1]},
                            "unknown": {"objects": v["unknown"][0], "bytes": v["unknown"][1]}}
                        for k, v in sorted(kinds.items())},
            "index_files": {"objects": index[0], "bytes": index[1]},
            "other": {k: {"objects": v[0], "bytes": v[1]} for k, v in sorted(other.items())},
            "other_roots_in_bucket": other_roots,
            "current_bytes": cur_bytes,
            "unknown_bytes": unk_bytes,
        }, indent=2))
        return

    print(f"\nStorage audit of {location}  (read-only)\n")
    print(f"  {'KIND':<14} {'CURRENT':>22} {'UNKNOWN':>22}")
    for kind, v in sorted(kinds.items()):
        print(f"  {kind:<14} {human(v['current'][1]):>12} {v['current'][0]:>7} obj"
              f" {human(v['unknown'][1]):>12} {v['unknown'][0]:>7} obj")
    print(f"  {'index_files':<14} {human(index[1]):>12} {index[0]:>7} obj  (not part of backups)")
    for kind, (n, b) in sorted(other.items()):
        print(f"  {kind:<14} {human(b):>12} {n:>7} obj  (other)")

    print(f"\n  Current collections ({len(known)}):")
    for c in sorted(known, key=lambda c: known[c]):
        n, b = per_coll.get(c, [0, 0])
        print(f"    {known[c]:<40} id {c:<20} {human(b):>12}")
    if unknown_ids:
        print(f"\n  Unknown collection IDs ({len(unknown_ids)}; top {min(args.top, len(unknown_ids))} by size):")
        for c in unknown_ids[:args.top]:
            print(f"    id {c:<20} {human(per_coll[c][1]):>12}  {per_coll[c][0]} objects")
    if other_roots:
        print(f"\n  Other top-level folders in bucket '{bucket}': {', '.join(other_roots)}")

    print(f"\n  Backups copy only CURRENT data: {human(cur_bytes)}.")
    if unk_bytes:
        print(f"  {human(unk_bytes)} in {len(unknown_ids)} unknown collection(s) is never backed up.")
        print("  It belongs to an older Milvus that used this root, or to dropped collections")
        print("  waiting for garbage collection. Milvus GC may remove unreferenced files here.")
    print()


if __name__ == "__main__":
    main()
