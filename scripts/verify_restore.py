#!/usr/bin/env python3
"""
Milvus restore verifier.

Modes:
  --compare     Compare entity counts per collection between the source and
                the target Milvus (works for any data). Target collection name
                is <source name><--suffix>.
  (default)     Check the benchmark collection written by seed_benchmark.py:
                entity count, and that a known vector finds itself first.

Credentials come from MILVUS_USER / MILVUS_PASSWORD in the environment.
Exit codes: 0 pass, 1 error, 2 verification failed.
"""

import argparse
import json
import os
import sys

from pymilvus import Collection, connections, utility


def connect(alias, host, port):
    connections.connect(
        alias=alias, host=host, port=port, timeout=30,
        user=os.environ.get("MILVUS_USER", ""), password=os.environ.get("MILVUS_PASSWORD", ""),
    )
    print(f"[VERIFIER] Connected to {alias} Milvus at {host}:{port}")


def compare(args):
    connect("source", args.source_host, args.source_port)
    connect("target", args.host, args.port)

    if args.collections:
        names = [c.strip() for c in args.collections.split(",") if c.strip()]
    else:
        names = sorted(utility.list_collections(using="source"))
    if not names:
        print("[VERIFIER ERROR] No collections to compare on the source.", file=sys.stderr)
        return 1

    rows, ok = [], True
    for name in names:
        target_name = f"{name}{args.suffix}"
        row = {"collection": name, "target_collection": target_name}
        if not utility.has_collection(name, using="source"):
            row.update(status="MISSING_ON_SOURCE")
        elif not utility.has_collection(target_name, using="target"):
            row.update(status="MISSING_ON_TARGET")
        else:
            src_count = Collection(name, using="source").num_entities
            dst_count = Collection(target_name, using="target").num_entities
            row.update(source_count=src_count, target_count=dst_count,
                       status="OK" if src_count == dst_count else "COUNT_MISMATCH")
        ok = ok and row["status"] == "OK"
        rows.append(row)
        print(f"  {row['status']:<18} {name} -> {target_name}"
              f"  {row.get('source_count', '-')} / {row.get('target_count', '-')}")

    print(json.dumps({"status": "SUCCESS" if ok else "FAILURE", "collections": rows}, indent=2))
    if not ok:
        print("[VERIFIER FAIL] Source and target differ (num_entities counts flushed rows only).", file=sys.stderr)
        return 2
    print(f"[VERIFIER PASS] {len(rows)} collection(s) match.")
    return 0


def benchmark(args):
    import numpy as np

    connect("default", args.host, args.port)
    if not utility.has_collection(args.collection):
        print(f"[VERIFIER ERROR] Collection '{args.collection}' does not exist on {args.host}:{args.port}", file=sys.stderr)
        return 1

    collection = Collection(name=args.collection)
    if not collection.indexes:
        print("[VERIFIER] No index on restored collection; creating IVF_FLAT...")
        collection.create_index(
            field_name="vector",
            index_params={"metric_type": "L2", "index_type": "IVF_FLAT", "params": {"nlist": 64}},
        )
    collection.load()
    num_entities = collection.num_entities

    # Rebuild the seeder's first vector (same seed) and search for it
    np.random.seed(42)
    vectors = np.random.rand(args.expected_count, args.dim).astype(np.float32)
    vectors = vectors / np.linalg.norm(vectors, axis=1, keepdims=True)
    results = collection.search(
        data=[vectors[0].tolist()], anns_field="vector",
        param={"metric_type": "L2", "params": {"nprobe": 16}},
        limit=5, output_fields=["id", "title", "category"],
    )
    hits = [{"id": h.entity.get("id"), "title": h.entity.get("title"), "distance": round(float(h.distance), 5)}
            for h in results[0]]

    checks = {
        "count_matched": num_entities == args.expected_count,
        "top_match_is_id_1": bool(hits) and hits[0]["id"] == 1,
        "distance_near_zero": bool(hits) and hits[0]["distance"] < 0.001,
    }
    ok = all(checks.values())
    print(json.dumps({
        "status": "SUCCESS" if ok else "FAILURE", "collection": args.collection,
        "expected_count": args.expected_count, "actual_count": num_entities, **checks, "sample_hits": hits,
    }, indent=2))
    if not ok:
        print(f"[VERIFIER FAIL] Data integrity check failed on {args.host}:{args.port}", file=sys.stderr)
        return 2
    print(f"[VERIFIER PASS] All checks passed on {args.host}:{args.port}")
    return 0


def main():
    p = argparse.ArgumentParser(description="Verify a restored Milvus")
    p.add_argument("--host", default="localhost", help="target Milvus host")
    p.add_argument("--port", default="19540", help="target Milvus port")
    p.add_argument("--compare", action="store_true", help="compare entity counts source vs target")
    p.add_argument("--source-host", default="localhost")
    p.add_argument("--source-port", default="19530")
    p.add_argument("--suffix", default="", help="suffix used at restore time (-s)")
    p.add_argument("--collections", default="", help="comma-separated list (default: all on source)")
    p.add_argument("--collection", default="benchmark_vectors", help="benchmark collection")
    p.add_argument("--expected-count", type=int, default=1000)
    p.add_argument("--dim", type=int, default=128)
    args = p.parse_args()

    try:
        sys.exit(compare(args) if args.compare else benchmark(args))
    except Exception as e:
        print(f"[VERIFIER ERROR] {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
