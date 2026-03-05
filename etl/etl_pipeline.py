#!/usr/bin/env python3
"""
Standalone ETL pipeline for Kubeflow docs RAG indexing.
Crawls GitHub docs → chunks → embeds → stores in Milvus.
All config via environment variables (injected by K8s ConfigMap/Secret).

Extracted from: https://github.com/kubeflow/docs-agent/blob/main/pipelines/github_rag_pipeline.yaml
"""

import json
import os
import re
import sys
import time
import base64
import requests
from datetime import datetime

# ── Config from env vars ──────────────────────────────────────────────

MILVUS_HOST = os.getenv("MILVUS_HOST", "my-release-milvus.docs-agent.svc.cluster.local")
MILVUS_PORT = os.getenv("MILVUS_PORT", "19530")
MILVUS_USER = os.getenv("MILVUS_USER", "root")
MILVUS_PASSWORD = os.getenv("MILVUS_PASSWORD", "Milvus")
COLLECTION_NAME = os.getenv("COLLECTION_NAME", "kubeflow_docs_docs_rag")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "sentence-transformers/all-mpnet-base-v2")
GITHUB_REPO = os.getenv("GITHUB_REPO", "kubeflow/website")
GITHUB_DOCS_PATH = os.getenv("GITHUB_DOCS_PATH", "content/en/docs")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "")
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "1000"))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "100"))
BASE_URL = os.getenv("BASE_URL", "https://www.kubeflow.org/docs")


def stage_download():
    """Stage 1: Recursively download .md/.html files from GitHub."""
    print(f"\n{'='*60}")
    print(f"STAGE 1: Download from GitHub")
    print(f"  Repo: {GITHUB_REPO}")
    print(f"  Path: {GITHUB_DOCS_PATH}")
    print(f"{'='*60}\n")

    owner, repo = GITHUB_REPO.split("/")
    headers = {"Authorization": f"token {GITHUB_TOKEN}"} if GITHUB_TOKEN else {}

    def get_files_recursive(url, depth=0):
        files = []
        try:
            response = requests.get(url, headers=headers)
            response.raise_for_status()
            items = response.json()

            if not isinstance(items, list):
                print(f"  Warning: unexpected response at {url}")
                return files

            for item in items:
                if item["type"] == "file" and (
                    item["name"].endswith(".md") or item["name"].endswith(".html")
                ):
                    file_response = requests.get(item["url"], headers=headers)
                    file_response.raise_for_status()
                    file_data = file_response.json()
                    content = base64.b64decode(file_data["content"]).decode("utf-8")

                    if item["name"].endswith(".html"):
                        from bs4 import BeautifulSoup
                        soup = BeautifulSoup(content, "html.parser")
                        content = soup.get_text(separator=" ", strip=True)

                    files.append({
                        "path": item["path"],
                        "content": content,
                        "file_name": item["name"],
                    })
                    if len(files) % 20 == 0:
                        print(f"  Downloaded {len(files)} files...")

                elif item["type"] == "dir":
                    files.extend(get_files_recursive(item["url"], depth + 1))

        except requests.exceptions.HTTPError as e:
            if e.response.status_code == 403:
                print(f"  Rate limited! Waiting 60s...")
                time.sleep(60)
                return get_files_recursive(url, depth)
            print(f"  Error fetching {url}: {e}")
        except Exception as e:
            print(f"  Error fetching {url}: {e}")

        return files

    api_url = f"https://api.github.com/repos/{owner}/{repo}/contents/{GITHUB_DOCS_PATH}"
    files = get_files_recursive(api_url)
    print(f"\n  Total files downloaded: {len(files)}")
    return files


def stage_chunk_and_embed(files):
    """Stage 2: Clean, chunk, and embed documents."""
    print(f"\n{'='*60}")
    print(f"STAGE 2: Chunk & Embed")
    print(f"  Model: {EMBEDDING_MODEL}")
    print(f"  Chunk size: {CHUNK_SIZE}, overlap: {CHUNK_OVERLAP}")
    print(f"{'='*60}\n")

    import torch
    from sentence_transformers import SentenceTransformer
    from langchain_text_splitters import RecursiveCharacterTextSplitter

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = SentenceTransformer(EMBEDDING_MODEL, device=device)
    print(f"  Model loaded on {device}")

    repo_name = GITHUB_REPO.split("/")[-1]
    text_splitter = RecursiveCharacterTextSplitter(
        chunk_size=CHUNK_SIZE,
        chunk_overlap=CHUNK_OVERLAP,
        length_function=len,
        separators=["\n\n", "\n", ". ", " ", ""],
    )

    records = []

    for file_data in files:
        content = file_data["content"]

        # Aggressive cleaning (from the KFP pipeline)
        content = re.sub(r"^\s*[+\-]{3,}.*?[+\-]{3,}\s*", "", content, flags=re.DOTALL | re.MULTILINE)
        content = re.sub(r"\{\{.*?\}\}", "", content, flags=re.DOTALL)
        content = re.sub(r"<!--.*?-->", "", content, flags=re.DOTALL)
        content = re.sub(r"<[^>]+>", " ", content)
        content = re.sub(r"\b(Get Started|Contribute|GenAI|Home|Menu|Navigation)\b", "", content, flags=re.IGNORECASE)
        content = re.sub(r"https?://\S+", "", content)
        content = re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", content)
        content = re.sub(r"\s+", " ", content)
        content = re.sub(r"\n\s*\n\s*\n+", "\n\n", content)
        content = content.strip()

        if len(content) < 50:
            continue

        # Build citation URL
        path_parts = file_data["path"].split("/")
        if "docs" in path_parts:
            docs_index = path_parts.index("docs")
            url_path = "/".join(path_parts[docs_index + 1:])
            url_path = os.path.splitext(url_path)[0]
            citation_url = f"{BASE_URL}/{url_path}"
        else:
            citation_url = f"{BASE_URL}/{file_data['path']}"

        file_unique_id = f"{repo_name}:{file_data['path']}"
        chunks = text_splitter.split_text(content)

        if chunks:
            avg_len = sum(len(c) for c in chunks) / len(chunks)
            print(f"  {file_data['path']} -> {len(chunks)} chunks (avg {avg_len:.0f} chars)")

        for chunk_idx, chunk in enumerate(chunks):
            embedding = model.encode(chunk).tolist()
            records.append({
                "file_unique_id": file_unique_id,
                "repo_name": repo_name,
                "file_path": file_data["path"],
                "file_name": file_data["file_name"],
                "citation_url": citation_url[:1024],
                "chunk_index": chunk_idx,
                "content_text": chunk[:2000],
                "embedding": embedding,
            })

    print(f"\n  Total records (chunks): {len(records)}")
    return records


def stage_store_milvus(records):
    """Stage 3: Store embedded vectors in Milvus."""
    print(f"\n{'='*60}")
    print(f"STAGE 3: Store in Milvus")
    print(f"  Host: {MILVUS_HOST}:{MILVUS_PORT}")
    print(f"  Collection: {COLLECTION_NAME}")
    print(f"{'='*60}\n")

    from pymilvus import (
        connections, utility,
        FieldSchema, CollectionSchema, DataType, Collection,
    )

    connections.connect(
        "default",
        host=MILVUS_HOST,
        port=MILVUS_PORT,
        user=MILVUS_USER,
        password=MILVUS_PASSWORD,
    )
    print("  Connected to Milvus")

    if utility.has_collection(COLLECTION_NAME):
        utility.drop_collection(COLLECTION_NAME)
        print(f"  Dropped existing collection: {COLLECTION_NAME}")

    fields = [
        FieldSchema(name="id", dtype=DataType.INT64, is_primary=True, auto_id=True),
        FieldSchema(name="file_unique_id", dtype=DataType.VARCHAR, max_length=512),
        FieldSchema(name="repo_name", dtype=DataType.VARCHAR, max_length=256),
        FieldSchema(name="file_path", dtype=DataType.VARCHAR, max_length=512),
        FieldSchema(name="file_name", dtype=DataType.VARCHAR, max_length=256),
        FieldSchema(name="citation_url", dtype=DataType.VARCHAR, max_length=1024),
        FieldSchema(name="chunk_index", dtype=DataType.INT64),
        FieldSchema(name="content_text", dtype=DataType.VARCHAR, max_length=2000),
        FieldSchema(name="vector", dtype=DataType.FLOAT_VECTOR, dim=768),
        FieldSchema(name="last_updated", dtype=DataType.INT64),
    ]

    schema = CollectionSchema(fields, "RAG collection for Kubeflow documentation")
    collection = Collection(COLLECTION_NAME, schema)
    print(f"  Created collection: {COLLECTION_NAME}")

    timestamp = int(datetime.now().timestamp())
    batch_size = 1000

    for i in range(0, len(records), batch_size):
        batch = records[i : i + batch_size]
        insert_data = [
            {
                "file_unique_id": r["file_unique_id"],
                "repo_name": r["repo_name"],
                "file_path": r["file_path"],
                "file_name": r["file_name"],
                "citation_url": r["citation_url"],
                "chunk_index": r["chunk_index"],
                "content_text": r["content_text"],
                "vector": r["embedding"],
                "last_updated": timestamp,
            }
            for r in batch
        ]
        collection.insert(insert_data)
        print(f"  Inserted batch {i // batch_size + 1} ({len(batch)} records)")

    collection.flush()

    nlist = min(1024, max(1, len(records)))
    index_params = {
        "metric_type": "COSINE",
        "index_type": "IVF_FLAT",
        "params": {"nlist": nlist},
    }
    collection.create_index("vector", index_params)
    collection.load()

    print(f"\n  Collection loaded. Total entities: {collection.num_entities}")
    connections.disconnect("default")


def main():
    print("=" * 60)
    print("ETL Pipeline: Kubeflow Docs → Milvus")
    print(f"Started at: {datetime.now().isoformat()}")
    print("=" * 60)

    t0 = time.time()

    # Stage 1
    t1 = time.time()
    files = stage_download()
    print(f"  Stage 1 took {time.time() - t1:.1f}s")

    if not files:
        print("ERROR: No files downloaded. Exiting.")
        sys.exit(1)

    # Stage 2
    t2 = time.time()
    records = stage_chunk_and_embed(files)
    print(f"  Stage 2 took {time.time() - t2:.1f}s")

    if not records:
        print("ERROR: No records created. Exiting.")
        sys.exit(1)

    # Stage 3
    t3 = time.time()
    stage_store_milvus(records)
    print(f"  Stage 3 took {time.time() - t3:.1f}s")

    print(f"\nTotal pipeline time: {time.time() - t0:.1f}s")
    print("ETL pipeline completed successfully.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"\nFATAL ERROR: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)
