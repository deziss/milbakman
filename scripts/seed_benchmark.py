#!/usr/bin/env python3
"""
Milvus Test Data Seeder
Creates a collection, builds index, inserts sample vectors, and validates readiness.
"""

import argparse
import json
import os
import sys
import numpy as np
from pymilvus import (
    connections,
    utility,
    FieldSchema,
    CollectionSchema,
    DataType,
    Collection,
)

def seed_milvus(host: str, port: str, collection_name: str, dim: int = 128, count: int = 1000):
    print(f"[SEEDER] Connecting to Milvus at {host}:{port}...")
    # Credentials come from the environment (MILVUS_USER / MILVUS_PASSWORD), never argv
    connections.connect(
        alias="default", host=host, port=port, timeout=30,
        user=os.environ.get("MILVUS_USER", ""), password=os.environ.get("MILVUS_PASSWORD", ""),
    )
    print(f"[SEEDER] Connected successfully to Milvus at {host}:{port}")

    if utility.has_collection(collection_name):
        print(f"[SEEDER] Dropping existing collection '{collection_name}'...")
        utility.drop_collection(collection_name)

    print(f"[SEEDER] Defining schema for collection '{collection_name}' (dim={dim})...")
    fields = [
        FieldSchema(name="id", dtype=DataType.INT64, is_primary=True, auto_id=False),
        FieldSchema(name="title", dtype=DataType.VARCHAR, max_length=128),
        FieldSchema(name="category", dtype=DataType.VARCHAR, max_length=64),
        FieldSchema(name="vector", dtype=DataType.FLOAT_VECTOR, dim=dim),
    ]
    schema = CollectionSchema(fields=fields, description="Milvus Backup Benchmark Collection")
    collection = Collection(name=collection_name, schema=schema)

    print(f"[SEEDER] Generating {count} sample vector records...")
    np.random.seed(42)
    ids = list(range(1, count + 1))
    titles = [f"Item Document #{i}" for i in ids]
    categories = ["finance" if i % 3 == 0 else "tech" if i % 3 == 1 else "health" for i in ids]
    vectors = np.random.rand(count, dim).astype(np.float32)
    # Normalize vectors
    vectors = vectors / np.linalg.norm(vectors, axis=1, keepdims=True)

    entities = [
        ids,
        titles,
        categories,
        vectors.tolist(),
    ]

    print(f"[SEEDER] Inserting {count} entities...")
    insert_result = collection.insert(entities)
    print(f"[SEEDER] Inserted entity count: {insert_result.insert_count}")

    print("[SEEDER] Creating IVF_FLAT vector index...")
    index_params = {
        "metric_type": "L2",
        "index_type": "IVF_FLAT",
        "params": {"nlist": 64},
    }
    collection.create_index(field_name="vector", index_params=index_params)
    print("[SEEDER] Index created successfully.")

    print("[SEEDER] Flushing data to storage...")
    collection.flush()

    print("[SEEDER] Loading collection into memory...")
    collection.load()

    # Perform a test query using entity 1's vector
    search_vector = [vectors[0].tolist()]
    search_params = {"metric_type": "L2", "params": {"nprobe": 16}}
    results = collection.search(
        data=search_vector,
        anns_field="vector",
        param=search_params,
        limit=5,
        output_fields=["id", "title", "category"],
    )

    sample_hits = []
    for hit in results[0]:
        sample_hits.append({
            "id": hit.entity.get("id"),
            "title": hit.entity.get("title"),
            "distance": round(float(hit.distance), 5),
        })

    summary = {
        "status": "SUCCESS",
        "host": host,
        "port": port,
        "collection": collection_name,
        "entities_inserted": count,
        "total_entities_reported": collection.num_entities,
        "sample_search_hits": sample_hits,
    }

    print("[SEEDER] Benchmark summary:")
    print(json.dumps(summary, indent=2))
    connections.disconnect("default")
    return summary

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Seed Milvus with benchmark data")
    parser.add_argument("--host", default="localhost", help="Milvus host")
    parser.add_argument("--port", default="19530", help="Milvus port")
    parser.add_argument("--collection", default="benchmark_vectors", help="Collection name")
    parser.add_argument("--dim", type=int, default=128, help="Vector dimension")
    parser.add_argument("--count", type=int, default=1000, help="Number of vectors")
    args = parser.parse_args()

    try:
        seed_milvus(args.host, args.port, args.collection, args.dim, args.count)
    except Exception as e:
        print(f"[SEEDER ERROR] {e}", file=sys.stderr)
        sys.exit(1)
