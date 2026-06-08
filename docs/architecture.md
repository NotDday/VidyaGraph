# VidyaGraph — Architecture

> A Localized Privacy-First Academic Knowledge Vault & Document Vector Graph

---

## System Overview

VidyaGraph is a completely self-contained, laptop-only academic research
assistant that ingests text documents, generates GPU-accelerated embeddings,
builds a knowledge graph with cross-document semantic edges, and presents
the results through an interactive Vis.js graph dashboard.

The system is designed around a **split-process architecture**: the compute-heavy
embedding pipeline runs on Windows 11 (leveraging NVIDIA CUDA for GPU
acceleration), while the database operations run on WSL 2 (Ubuntu) where
ShaktiDB — a sovereign PostgreSQL 17 fork — handles vector storage and
graph traversal.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          WINDOWS 11 HOST                                │
│                                                                         │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │                    FastAPI + Uvicorn (port 8000)                   │  │
│  │                                                                    │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌─────────────────────────┐  │  │
│  │  │  POST /upload │  │  GET /search │  │  GET /graph  GET /status│  │  │
│  │  └──────┬───────┘  └──────┬───────┘  └─────────────┬───────────┘  │  │
│  │         │                 │                         │              │  │
│  │  ┌──────▼─────────────────▼──────────────────┐      │              │  │
│  │  │         Embedding Pipeline (CUDA)          │      │              │  │
│  │  │  ┌────────────┐  ┌──────────────────────┐  │      │              │  │
│  │  │  │ chunk_text()│  │ batch_embed() [GPU]  │  │      │              │  │
│  │  │  └────────────┘  └──────────────────────┘  │      │              │  │
│  │  │  ┌────────────────────┐  ┌──────────────┐  │      │              │  │
│  │  │  │build_semantic_edges│  │build_cross_doc│  │      │              │  │
│  │  │  └────────────────────┘  └──────────────┘  │      │              │  │
│  │  └──────────────────┬────────────────────────┘      │              │  │
│  │                     │                                │              │  │
│  │  ┌──────────────────▼────────────────────────────────▼──────────┐  │  │
│  │  │              TCP Socket Client (msgpack + framing)           │  │  │
│  │  │       Insert: localhost:5555  |  Query: localhost:5556       │  │  │
│  │  └──────────────────┬────────────────────────────────┬─────────┘  │  │
│  └─────────────────────┼────────────────────────────────┼────────────┘  │
│                        │          TCP/IP (localhost)     │               │
├════════════════════════╪════════════════════════════════╪═══════════════╡
│                        │        WSL 2 (Ubuntu)          │               │
│  ┌─────────────────────▼────────────────────────────────▼──────────┐   │
│  │                   wsl_server.py                                  │   │
│  │                                                                  │   │
│  │  ┌─────────────────┐  ┌──────────────────┐  ┌───────────────┐   │   │
│  │  │ Insert Listener  │  │ Query Listener   │  │  DB Writer    │   │   │
│  │  │ (port 5555)      │  │ (port 5556)      │  │  Thread       │   │   │
│  │  │                  │  │                  │  │  (batch 50)   │   │   │
│  │  │  ┌────────────┐  │  │  ┌────────────┐  │  │               │   │   │
│  │  │  │Handler     │  │  │  │CTE Query   │  │  │  queue.Queue  │   │   │
│  │  │  │Threads     │  │  │  │Handler     │  │  │  ──► bulk     │   │   │
│  │  │  └────────────┘  │  │  └────────────┘  │  │      insert   │   │   │
│  │  └─────────────────┘  └──────────────────┘  └───────┬───────┘   │   │
│  └──────────────────────────────────────────────────────┼──────────┘   │
│                                                         │              │
│  ┌──────────────────────────────────────────────────────▼──────────┐   │
│  │                  ShaktiDB (port 5432)                            │   │
│  │                  PostgreSQL 17 Fork + pgvector                   │   │
│  │                                                                  │   │
│  │  ┌────────────────┐ ┌──────────────┐ ┌───────────────────────┐  │   │
│  │  │document_registry│ │content_nodes │ │  knowledge_edges      │  │   │
│  │  │                │ │vector(384)   │ │  (semantic, cross_doc, │  │   │
│  │  │                │ │IVFFlat index │ │   entity)              │  │   │
│  │  └────────────────┘ └──────────────┘ └───────────────────────┘  │   │
│  │                                                                  │   │
│  │  ┌────────────────────────┐  ┌─────────────────────────────┐    │   │
│  │  │ knowledge_summary (MV) │  │ graph_traversal (CTE view)  │    │   │
│  │  └────────────────────────┘  └─────────────────────────────┘    │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                  Browser (localhost:8000)                         │   │
│  │  ┌──────────────┐  ┌───────────────────────┐  ┌──────────────┐  │   │
│  │  │ Left Panel    │  │  Vis.js Graph Canvas  │  │ Right Drawer │  │   │
│  │  │ - Upload      │  │  - ForceAtlas2 physics│  │ - Node detail│  │   │
│  │  │ - Search bar  │  │  - Timeline slider    │  │ - Provenance │  │   │
│  │  │ - Doc list    │  │  - Lasso selection    │  │ - Find similar│  │   │
│  │  └──────────────┘  └───────────────────────┘  └──────────────┘  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## ShaktiDB Rationale

### Why ShaktiDB over Stock PostgreSQL?

**ShaktiDB** is a sovereign, hardened PostgreSQL 17 fork developed by the
**Indian Institute of Technology Madras (IIT Madras) Pravartak Technology
Innovation Hub**, in collaboration with **C-DAC (Centre for Development of
Advanced Computing)**. It is funded by India's **Ministry of Electronics and
Information Technology (MeitY)** as part of the national sovereign digital
infrastructure initiative.

#### Key Properties

| Property | Description |
|---|---|
| **Privacy-by-Design** | Data never leaves the local deployment boundary. No telemetry, no crash reporting, no phone-home behaviour. |
| **Sovereignty** | Entire stack is auditable by Indian institutions. No foreign-controlled infrastructure dependencies. |
| **Regulatory Compliance** | Built to satisfy India's data localisation norms and the Digital Personal Data Protection Act (DPDPA) 2023. |
| **Wire Compatibility** | Fully wire-compatible with PostgreSQL 17. All standard tools (psycopg2, psql, pgAdmin) work without modification. |
| **Extension Support** | Supports pgvector and other standard PostgreSQL extensions. |

#### Alignment with VidyaGraph's Threat Model

VidyaGraph is designed as a **completely air-gapped, laptop-only** academic
knowledge vault. Its threat model explicitly prohibits:

- Cloud APIs (OpenAI, Pinecone, etc.)
- External vector databases
- Any network egress

ShaktiDB's privacy-by-design architecture is a natural fit — all document
embeddings, knowledge edges, and provenance metadata remain on the local
machine, inside a database engineered for data sovereignty. This alignment
is not coincidental — it is a deliberate architectural decision.

---

## Wire Protocol Specification

All TCP communication between the Windows backend and WSL backend uses a
length-prefixed binary protocol over TCP:

```
┌──────────────────┬───────────────────────────────────┐
│ 4 bytes          │ payload_length bytes               │
│ big-endian uint32│ msgpack-encoded payload            │
│ (payload length) │                                    │
└──────────────────┴───────────────────────────────────┘
```

### Insert Packet Schema

```python
{
    "doc_id":            str,           # UUID string
    "file_name":         str,           # Original filename
    "chunk_index":       int,           # 0-indexed chunk position
    "raw_text":          str,           # Chunk text content
    "embedding":         list[float],   # Exactly 384 floats (unit-normalised)
    "entities":          list[tuple],   # [(entity_a, entity_b), ...]
    "provenance":        dict,          # {"page": int, "line_start": int, "line_end": int}
    "relationship_type": str            # "semantic" | "cross_document" | "entity"
}
```

### Query Packet Schema

```python
{
    "query_vector": list[float],   # 384-dim unit-normalised query embedding
    "max_depth":    int,           # Max graph traversal depth (typically 2)
    "top_k":        int            # Number of seed nodes for CTE
}
```

### Query Response Schema

```python
{
    "nodes": [{"node_id": str, "preview": str, "degree": int,
               "weighted_degree": float, "doc_id": str}],
    "edges": [{"source": str, "target": str, "type": str, "weight": float}]
}
```

---

## Component Descriptions

### Windows Backend (`windows_backend.py`)

- **FastAPI + Uvicorn** web server on port 8000
- **SentenceTransformer** model (`all-MiniLM-L6-v2`) loaded on CUDA at startup
- **Embedding pipeline**: chunk_text → batch_embed → build_semantic_edges
- **TCP socket client**: persistent connections to WSL for insert (5555) and query (5556)

### WSL Backend (`wsl_server.py`)

- **Insert listener** (port 5555): accepts TCP connections, spawns handler threads
- **Query listener** (port 5556): executes parameterised recursive CTE queries
- **DB writer thread**: batches queue items (50 per batch) and bulk-inserts to ShaktiDB
- **Error handling**: exponential backoff reconnect, transaction rollback on failure

### ShaktiDB Schema

- **3 tables**: `document_registry`, `content_nodes`, `knowledge_edges`
- **6 indexes**: IVFFlat vector, 3× graph traversal, GIN full-text, GIN JSONB
- **1 materialized view**: `knowledge_summary` (graph centrality metrics)
- **1 recursive CTE view**: `graph_traversal_template` (hybrid vector + graph search)

### Frontend (`index.html` + `app.js`)

- **Dark-mode dashboard** with three-panel layout
- **Vis.js Network** graph with forceAtlas2Based physics
- **Drag-and-drop upload**, SSE streaming search, timeline slider, lasso selection

---

## Cross-Document Edge Algorithm

*Detailed explanation will be added in Week 3 when the algorithm is implemented.*

Most RAG pipelines treat documents in isolation. VidyaGraph builds a
**semantic bridge** between documents at ingestion time, creating a living
knowledge graph that reveals conceptual overlap the user did not explicitly
request.

**Algorithm Overview:**
1. When a new document is uploaded, its chunks are embedded using all-MiniLM-L6-v2.
2. All existing chunk embeddings are fetched from ShaktiDB.
3. Pairwise cosine similarity is computed between new and existing embeddings.
4. Pairs exceeding the threshold (0.5) generate `cross_document` edges.
5. These edges appear as dashed green lines on the knowledge graph.

This is the **primary academic contribution** of the project.

---

## Recursive CTE Query Plan

*Detailed explanation will be added in Week 3 when the query engine is implemented.*

The hybrid query strategy combines:
1. **pgvector IVFFlat** approximate nearest-neighbour for semantic seeding
2. **PostgreSQL recursive CTE** for structural graph traversal

Neither alone gives the full picture — the combination is the design insight.

---

## Known Limitations

- **IVFFlat recall**: IVFFlat trades some recall for lower memory usage. For
  datasets over ~100K vectors, HNSW would provide better recall at the cost
  of higher memory consumption.
- **Single-machine**: No horizontal scaling. Designed for laptop-only use.
- **Text only**: Currently supports `.txt` files only. PDF/DOCX extraction
  would require additional dependencies.
- **No authentication**: The web server has no auth layer. Acceptable for
  local-only deployment.

---

## Future Work

- PDF and DOCX ingestion via `pdfplumber` and `python-docx`
- Named entity recognition for `entity`-type edges
- Graph community detection (Louvain algorithm)
- Export knowledge graph as GraphML or RDF
- Multi-language embedding support
