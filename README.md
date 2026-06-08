# VidyaGraph

> **A Localized Privacy-First Academic Knowledge Vault & Document Vector Graph**

[![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-blue.svg)](https://www.python.org/downloads/)
[![ShaktiDB](https://img.shields.io/badge/Database-ShaktiDB-orange.svg)](https://pravartak.org.in/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![CUDA](https://img.shields.io/badge/GPU-CUDA%20RTX%204050-brightgreen.svg)](https://developer.nvidia.com/cuda-toolkit)

---

## What is VidyaGraph?

VidyaGraph is a **completely self-contained, laptop-only** academic research
assistant that transforms text documents into an interactive knowledge graph.
It runs entirely on your local machine — no cloud APIs, no external databases,
no network egress.

### Key Features

- **🔐 Privacy-First** — All data stays on your laptop. Powered by ShaktiDB,
  a sovereign PostgreSQL 17 fork built for data localisation.
- **🧠 GPU-Accelerated Embeddings** — Uses `all-MiniLM-L6-v2` on NVIDIA CUDA
  for fast 384-dimensional vector encoding.
- **🔗 Cross-Document Intelligence** — Automatically discovers semantic bridges
  between separate documents at ingestion time. This is the primary "wow-factor"
  feature that distinguishes VidyaGraph from standard RAG pipelines.
- **📊 Interactive Knowledge Graph** — Vis.js-powered graph with force-directed
  physics, timeline filtering, lasso selection, and SSE-streamed search results.
- **⚡ Hybrid Query Strategy** — Combines pgvector approximate nearest-neighbour
  (IVFFlat cosine) with PostgreSQL recursive CTE graph traversal.
- **🔌 No Orchestration Frameworks** — Every pipeline step — chunking, embedding,
  edge-building, socket framing, CTE traversal — is implemented from primitives.

---

## Architecture

```
Windows 11 (GPU)                    WSL 2 (Ubuntu)
┌──────────────────────┐           ┌──────────────────────┐
│  FastAPI (port 8000) │           │  wsl_server.py       │
│  SentenceTransformer │──TCP/IP──►│  Insert (port 5555)  │
│  (all-MiniLM-L6-v2)  │  msgpack  │  Query  (port 5556)  │
│  CUDA RTX 4050       │◄──────────│  DB Writer (batch 50)│
└──────────────────────┘           └──────────┬───────────┘
                                              │
                                   ┌──────────▼───────────┐
                                   │  ShaktiDB (port 5432)│
                                   │  PostgreSQL 17 fork  │
                                   │  + pgvector          │
                                   └──────────────────────┘
```

### Why ShaktiDB?

[ShaktiDB](https://pravartak.org.in/) is a sovereign, hardened PostgreSQL 17
fork developed by **IIT Madras Pravartak** and **C-DAC**, funded by India's
**Ministry of Electronics and Information Technology (MeitY)**. Its privacy-by-design
properties directly align with VidyaGraph's air-gapped threat model:

- **No telemetry, no phone-home** — Data never leaves the deployment boundary
- **Regulatory compliance** — Built for India's DPDPA 2023 data localisation norms
- **Wire-compatible** — Works with psycopg2, psql, pgAdmin without modification

See [docs/architecture.md](docs/architecture.md) for the full rationale.

---

## Repository Structure

```
vidyagraph/
├── README.md                       # This file
├── .gitignore                      # Python, Node, OS artefacts
├── requirements_windows.txt        # Windows-side dependencies
├── requirements_wsl.txt            # WSL-side dependencies
├── schema/
│   ├── schema.sql                  # Full database schema (tables, indexes, views)
│   └── seed_test.sql               # Synthetic test data (2 docs, 6 chunks, 5 edges)
├── wsl_backend/
│   └── wsl_server.py               # WSL TCP server (insert + query)
├── windows_backend/
│   ├── windows_backend.py          # FastAPI app + embedding pipeline
│   └── static/
│       ├── index.html              # Frontend dashboard
│       └── app.js                  # Vis.js graph + interactions
└── docs/
    ├── architecture.md             # System architecture documentation
    └── weekly_log.md               # Weekly development log
```

---

## Setup Instructions

### Prerequisites

| Component | Requirement |
|---|---|
| Windows 11 | Intel Core i7-14650HX (or equivalent) |
| GPU | NVIDIA RTX 4050 (6 GB VRAM), CUDA-enabled |
| WSL 2 | Ubuntu installed and running |
| ShaktiDB | PostgreSQL 17 fork, running on WSL 2, port 5432 |
| Python | 3.10+ on both Windows and WSL 2 |
| CUDA Toolkit | Installed on Windows, compatible with PyTorch |

### Step 1: ShaktiDB Setup (WSL 2)

```bash
# 1. Ensure ShaktiDB is running on port 5432
sudo systemctl start shaktidb   # or: sudo pg_ctlcluster 17 main start

# 2. Create database and user
sudo -u postgres psql -c "CREATE USER vidyagraph WITH PASSWORD 'vidyagraph';"
sudo -u postgres psql -c "CREATE DATABASE vidyagraph OWNER vidyagraph;"

# 3. Enable pgvector extension
sudo -u postgres psql -d vidyagraph -c "CREATE EXTENSION IF NOT EXISTS vector;"

# 4. Apply schema
psql -U vidyagraph -d vidyagraph -f schema/schema.sql

# 5. (Optional) Load seed test data
psql -U vidyagraph -d vidyagraph -f schema/seed_test.sql
```

### Step 2: WSL Backend Setup

```bash
# In WSL 2 terminal
cd /mnt/d/Files/Coding/VidyaGraph  # or wherever your repo is
pip install -r requirements_wsl.txt

# Start the WSL server
python wsl_backend/wsl_server.py
```

### Step 3: Windows Backend Setup

```powershell
# In Windows PowerShell / terminal
cd D:\Files\Coding\VidyaGraph
pip install -r requirements_windows.txt

# Start the FastAPI server
python -m uvicorn windows_backend.windows_backend:app --host 0.0.0.0 --port 8000
```

### Step 4: Open Dashboard

Navigate to **http://localhost:8000** in your browser.

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SHAKTIDB_HOST` | `localhost` | ShaktiDB host address |
| `SHAKTIDB_PORT` | `5432` | ShaktiDB port |
| `SHAKTIDB_NAME` | `vidyagraph` | Database name |
| `SHAKTIDB_USER` | `vidyagraph` | Database username |
| `SHAKTIDB_PASS` | `vidyagraph` | Database password |

---

## How to Run

### Quick Start

```bash
# Terminal 1 (WSL 2): Start database server
python wsl_backend/wsl_server.py

# Terminal 2 (Windows): Start web server
python -m uvicorn windows_backend.windows_backend:app --port 8000

# Terminal 3 (Windows): Open browser
start http://localhost:8000
```

### Running Tests

```bash
# From Windows side (Week 5)
python -m pytest tests/test_pipeline.py -v
```

---

## Development Timeline

| Week | Milestone | Status |
|---|---|---|
| 1 | Foundation & Database | ✅ Complete |
| 2 | TCP Pipeline & Embedding Engine | 🔲 Pending |
| 3 | Query Engine & Cross-Document Intelligence | 🔲 Pending |
| 4 | Frontend: Graph Canvas & Core UI | 🔲 Pending |
| 5 | Polish, Testing & GitHub Release | 🔲 Pending |

See [docs/weekly_log.md](docs/weekly_log.md) for detailed progress.

---

## Academic Differentiation

- **ShaktiDB**: Sovereign PostgreSQL 17 fork (IIT Madras Pravartak / MeitY),
  privacy-by-design — not just a database choice but a thesis-aligned decision.
- **Cross-document edges**: Automatic semantic bridging between documents at
  ingestion time — most RAG pipelines treat documents in isolation.
- **No orchestration frameworks**: LangChain and LlamaIndex are explicitly
  excluded. Every step is implemented from primitives.
- **Hybrid query strategy**: pgvector ANN + recursive CTE graph traversal —
  neither alone gives the full picture.

---

## License

MIT

---

*Built as a university-evaluated academic project demonstrating privacy-first
knowledge management with sovereign database infrastructure.*
