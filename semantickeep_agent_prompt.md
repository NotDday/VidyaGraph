# SemanticKeep — Agentic Build Prompt
## For: Google Antigravity (Agentic Coding Environment)
## Project: A Localized Privacy-First Academic Knowledge Vault & Document Vector Graph

---

## AGENT CONTEXT & ROLE

You are an autonomous full-stack systems engineer. Your job is to build
**SemanticKeep** — a completely self-contained, laptop-only academic research
assistant — from scratch, committing working code to a GitHub repository at
the end of each weekly milestone. Every file you generate must be complete,
runnable, and free of placeholders. Apply thorough inline comments suitable
for a university evaluation. Use structured Python logging (`logging` module)
throughout — never bare `print()` statements. All functions must have type
annotations and docstrings.

Do not ask clarifying questions. Make all architectural decisions using the
constraints and specifications below. When a decision is ambiguous, choose
the option that maximises clarity, testability, and academic demonstrability.

---

## HARD CONSTRAINTS — NEVER VIOLATE THESE

| Constraint | Value |
|---|---|
| Host OS | Windows 11 (Intel Core i7-14650HX) |
| GPU | NVIDIA RTX 4050, 6 GB VRAM, CUDA-enabled |
| Backend runtime | WSL 2 (Ubuntu), sharing network via `localhost` |
| Database | ShaktiDB (PostgreSQL 17 fork by IIT Madras Pravartak / MeitY) on port 5432 in WSL 2 |
| Embedding model | `all-MiniLM-L6-v2` via `sentence-transformers` — exactly 384 dimensions |
| Vector extension | `pgvector` (`CREATE EXTENSION IF NOT EXISTS vector;`) |
| Frontend server | FastAPI + Uvicorn on Windows 11, port 8000 |
| Graph library | Vis.js (vis-network) via CDN in vanilla JS |
| Styling | Tailwind CSS (CDN), dark mode, no component frameworks |
| Wire protocol | 4-byte big-endian length prefix + msgpack body over TCP |
| Prohibited | LangChain, LlamaIndex, Pinecone, Neo4j, any cloud API, any external vector DB |
| Allowed stdlib | `socket`, `threading`, `queue`, `logging`, `json`, `math`, `struct`, `pathlib` |
| Allowed third-party | `fastapi`, `uvicorn`, `psycopg2-binary`, `msgpack`, `sentence-transformers`, `torch`, `numpy`, `python-multipart` |

---

## REPOSITORY STRUCTURE

Initialise a GitHub repository named `semantickeep` with this exact layout.
Create all files even if empty at initialisation — fill them in during the
correct week.

```
semantickeep/
├── README.md
├── .gitignore                  # Python, Node, OS artefacts
├── requirements_windows.txt    # Windows-side dependencies
├── requirements_wsl.txt        # WSL-side dependencies
├── schema/
│   └── schema.sql
├── wsl_backend/
│   └── wsl_server.py
├── windows_backend/
│   ├── windows_backend.py
│   └── static/
│       ├── index.html
│       └── app.js
└── docs/
    ├── architecture.md
    └── weekly_log.md           # Agent appends a log entry each week
```

---

## DATABASE SCHEMA SPECIFICATION

ShaktiDB is a hardened PostgreSQL 17 fork developed by IIT Madras Pravartak
and funded by MeitY as sovereign digital infrastructure. It is wire-compatible
with PostgreSQL 17 and supports standard extensions including pgvector. Use
`psycopg2-binary` to connect. The sovereignty and privacy-by-design properties
of ShaktiDB directly align with SemanticKeep's privacy-first threat model —
document this alignment explicitly in `architecture.md`.

### Tables

```sql
-- 1. document_registry
--    One row per ingested file.
CREATE TABLE document_registry (
    doc_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    file_name    TEXT NOT NULL,
    file_path    TEXT NOT NULL,
    file_size_kb NUMERIC(10,2),
    imported_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. content_nodes
--    One row per text chunk. provenance stores page/line metadata as JSONB.
CREATE TABLE content_nodes (
    node_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    doc_id           UUID NOT NULL REFERENCES document_registry(doc_id) ON DELETE CASCADE,
    chunk_index      INTEGER NOT NULL,
    raw_text         TEXT NOT NULL,
    embedding_vector vector(384) NOT NULL,
    provenance       JSONB NOT NULL DEFAULT '{}'
);

-- 3. knowledge_edges
--    Self-referencing M:N join forming the graph layer.
--    relationship_type: 'semantic' | 'cross_document' | 'entity'
CREATE TABLE knowledge_edges (
    edge_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_node_id   UUID NOT NULL REFERENCES content_nodes(node_id) ON DELETE CASCADE,
    target_node_id   UUID NOT NULL REFERENCES content_nodes(node_id) ON DELETE CASCADE,
    relationship_type TEXT NOT NULL DEFAULT 'semantic',
    strength_weight  NUMERIC(5,4) NOT NULL CHECK (strength_weight BETWEEN 0 AND 1),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Indexes

```sql
-- Vector similarity search (IVFFlat — lower memory than HNSW on 6 GB VRAM)
CREATE INDEX idx_embedding_ivfflat
    ON content_nodes USING ivfflat (embedding_vector vector_cosine_ops)
    WITH (lists = 100);

-- Graph traversal
CREATE INDEX idx_edges_source ON knowledge_edges(source_node_id);
CREATE INDEX idx_edges_target ON knowledge_edges(target_node_id);
CREATE INDEX idx_edges_type   ON knowledge_edges(relationship_type);

-- Full-text search on raw chunks
CREATE INDEX idx_raw_text_gin ON content_nodes USING gin(to_tsvector('english', raw_text));

-- Provenance JSONB
CREATE INDEX idx_provenance ON content_nodes USING gin(provenance);
```

### Materialized view — graph centrality

```sql
CREATE MATERIALIZED VIEW knowledge_summary AS
    SELECT
        n.node_id,
        n.doc_id,
        n.chunk_index,
        LEFT(n.raw_text, 120)                      AS preview,
        COUNT(e.edge_id)                            AS degree,
        COALESCE(SUM(e.strength_weight), 0)         AS weighted_degree,
        n.imported_at_proxy
    FROM content_nodes n
    LEFT JOIN (
        SELECT edge_id, source_node_id AS node_id, strength_weight FROM knowledge_edges
        UNION ALL
        SELECT edge_id, target_node_id AS node_id, strength_weight FROM knowledge_edges
    ) e ON e.node_id = n.node_id
    LEFT JOIN document_registry dr ON dr.doc_id = n.doc_id
    GROUP BY n.node_id, n.doc_id, n.chunk_index, n.raw_text, dr.imported_at;

CREATE UNIQUE INDEX ON knowledge_summary(node_id);
```

Add a trigger to refresh the materialized view automatically after bulk
inserts complete (use a deferred trigger on `content_nodes`).

### Recursive CTE view

```sql
CREATE OR REPLACE VIEW graph_traversal_template AS
-- Parameterised at call time via prepared statement.
-- Finds semantically close seed nodes then walks edges up to depth 2.
WITH RECURSIVE
seed AS (
    SELECT node_id, raw_text, embedding_vector, 0 AS depth
    FROM content_nodes
    ORDER BY embedding_vector <=> $1   -- query vector placeholder
    LIMIT 5
),
traversal (node_id, raw_text, depth, path, is_cycle) AS (
    SELECT node_id, raw_text, depth, ARRAY[node_id], false FROM seed
    UNION ALL
    SELECT
        cn.node_id, cn.raw_text, t.depth + 1,
        t.path || cn.node_id,
        cn.node_id = ANY(t.path)
    FROM traversal t
    JOIN knowledge_edges ke
        ON ke.source_node_id = t.node_id OR ke.target_node_id = t.node_id
    JOIN content_nodes cn
        ON cn.node_id = CASE
            WHEN ke.source_node_id = t.node_id THEN ke.target_node_id
            ELSE ke.source_node_id END
    WHERE t.depth < $2   -- max_depth placeholder
      AND NOT t.is_cycle
)
SELECT DISTINCT node_id, raw_text, depth FROM traversal;
```

---

## WSL BACKEND SPECIFICATION (`wsl_server.py`)

### Architecture

- Single Python process with three thread pools:
  1. **Listener thread** — `socket.accept()` loop, spawns a handler thread per connection
  2. **Handler threads** — receive framed msgpack packets, validate, push to insert queue
  3. **DB writer thread** — drains `queue.Queue` in batches of 50, executes bulk inserts via `psycopg2` `execute_values`

### Wire protocol (strict — both sides must match)

```
[ 4 bytes big-endian uint32 : payload_length ][ payload_length bytes : msgpack payload ]
```

Implement `send_framed(sock, data: bytes)` and `recv_framed(sock) -> bytes` helpers
that loop until exactly the declared number of bytes are transferred. Never
assume `recv()` returns a complete message.

### Packet schema (msgpack dict)

```python
{
    "doc_id":       str,           # UUID string
    "file_name":    str,
    "chunk_index":  int,
    "raw_text":     str,
    "embedding":    list[float],   # exactly 384 floats
    "entities":     list[tuple],   # [("entity_a", "entity_b"), ...]
    "provenance":   dict,          # {"page": int, "line_start": int, "line_end": int}
    "relationship_type": str       # "semantic" | "cross_document" | "entity"
}
```

### Query endpoint

Expose a second TCP port (5433) for query requests. A query packet contains:

```python
{ "query_vector": list[float], "max_depth": int, "top_k": int }
```

The server executes the recursive CTE, refreshes `knowledge_summary`, and
returns a response packet:

```python
{
    "nodes": [{"node_id": str, "preview": str, "degree": int, "weighted_degree": float, "doc_id": str}],
    "edges": [{"source": str, "target": str, "type": str, "weight": float}]
}
```

### Error handling requirements

- Catch all socket errors and log with `logging.exception`
- On DB error: rollback transaction, log, return error packet — do not crash
- Implement exponential backoff reconnect to ShaktiDB (1s, 2s, 4s, max 30s)
- Graceful shutdown on SIGTERM: drain the insert queue before closing DB connection

---

## WINDOWS BACKEND SPECIFICATION (`windows_backend.py`)

### FastAPI endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/upload` | Accept `.txt` file, run full pipeline, return graph payload |
| `GET` | `/search` | Accept `?q=` query string, return graph payload via SSE stream |
| `GET` | `/graph` | Return full current graph from ShaktiDB (nodes + edges) |
| `GET` | `/status` | Return socket connection status JSON |
| `GET` | `/` | Serve `static/index.html` |

### Embedding pipeline (runs on Windows, GPU)

```python
# Pseudo-code — implement fully
model = SentenceTransformer('all-MiniLM-L6-v2', device='cuda')

def chunk_text(text: str, size: int = 300, overlap: int = 50) -> list[dict]:
    # Split into overlapping word-boundary chunks.
    # Each chunk dict: {text, chunk_index, provenance: {line_start, line_end}}

def batch_embed(chunks: list[str], batch_size: int = 32) -> np.ndarray:
    # Returns shape (N, 384). Normalize to unit vectors before returning.

def build_semantic_edges(embeddings: np.ndarray, threshold: float = 0.4) -> list[tuple]:
    # Pairwise cosine sim via numpy dot on unit vectors.
    # Return list of (i, j, similarity_score) where score > threshold.

def build_cross_document_edges(
    new_embeddings: np.ndarray,
    new_node_ids: list[str],
    existing_nodes: list[dict],
    threshold: float = 0.5
) -> list[tuple]:
    # Compare new chunks against all existing chunks already in ShaktiDB.
    # Return cross-document edges with relationship_type='cross_document'.
    # This is the primary wow-factor feature — document it clearly.
```

### Socket client

- Maintain a persistent TCP connection to WSL 2 on localhost:5432 (insert) and localhost:5433 (query)
- Reconnect automatically with exponential backoff if connection drops
- Expose `/status` endpoint that returns `{"insert": "connected"|"reconnecting"|"error", "query": "..."}`

### SSE streaming search (`/search`)

```python
from fastapi.responses import StreamingResponse

@app.get("/search")
async def search(q: str):
    async def event_stream():
        embedding = model.encode([q], normalize_embeddings=True)[0].tolist()
        results = await query_wsl(embedding, max_depth=2, top_k=10)
        for node in results["nodes"]:
            yield f"data: {json.dumps({'type': 'node', 'payload': node})}\n\n"
            await asyncio.sleep(0.04)   # paced reveal for visual effect
        for edge in results["edges"]:
            yield f"data: {json.dumps({'type': 'edge', 'payload': edge})}\n\n"
            await asyncio.sleep(0.02)
        yield "data: {\"type\": \"done\"}\n\n"
    return StreamingResponse(event_stream(), media_type="text/event-stream")
```

---

## FRONTEND SPECIFICATION (`index.html` + `app.js`)

### Layout

```
┌─────────────────────────────────────────────────────────┐
│ Header: "SemanticKeep" | socket status badge | doc count │
├──────────────────────────┬──────────────────────────────┤
│  Left panel (320px)      │  Main canvas                 │
│  - Upload dropzone       │  - Vis.js network graph      │
│  - Search bar            │  - Timeline slider (bottom)  │
│  - Document list         │                              │
├──────────────────────────┴──────────────────────────────┤
│  Side drawer (slides in on node click, 380px)           │
│  - Raw text | Provenance | Connected nodes              │
└─────────────────────────────────────────────────────────┘
```

### Vis.js graph configuration

```javascript
// Node sizing: driven by weighted_degree from knowledge_summary
// Node color: by relationship cluster
//   - document root nodes:    #534AB7  (purple)
//   - content chunk nodes:    #1D9E75  (teal)
//   - high-centrality nodes:  #D85A30  (coral, weighted_degree > 5)

// Edge styling by relationship_type:
const edgeStyles = {
    semantic:        { color: '#7F77DD', width: 1.5, dashes: false },
    cross_document:  { color: '#1D9E75', width: 2.5, dashes: [8, 4] },
    entity:          { color: '#D85A30', width: 1,   dashes: false  }
};

// Physics: forceAtlas2Based for organic clustering
const physicsOptions = {
    solver: 'forceAtlas2Based',
    forceAtlas2Based: { gravitationalConstant: -80, springLength: 120, springConstant: 0.08 }
};
```

### Required interactions

1. **Drag-and-drop upload** — drop `.txt` file onto left panel, show progress bar during ingestion, then animate new nodes appearing on graph
2. **Click node** — slide in right drawer with raw text, provenance (page/line), degree, and a "Find similar" button that triggers a search seeded from that node's embedding
3. **Timeline slider** — HTML range input below canvas; dragging filters `dataset.update()` to show only nodes from documents ingested before the selected timestamp
4. **Lasso selection** — Shift+drag to select node cluster; "Summarise selection" button appears, POSTs selected node IDs to `/summarise` endpoint which concatenates raw text and returns it to a modal
5. **Socket status badge** — header badge, three states:
   - Green dot + "Connected"
   - Amber dot + "Reconnecting..." (pulse animation)
   - Red dot + "Disconnected"
   Polls `/status` every 3 seconds.
6. **Empty state** — when graph has zero nodes, show centered placeholder: upload icon + "No documents yet — drop a .txt file to begin"

### SSE graph update

```javascript
// On search, open EventSource to /search?q=...
// On each 'node' event: network.body.data.nodes.update(payload)
// On each 'edge' event: network.body.data.edges.update(payload)
// On 'done' event: close EventSource, fit graph view
const es = new EventSource(`/search?q=${encodeURIComponent(query)}`);
es.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.type === 'node') nodesDataset.update(buildVisNode(msg.payload));
    if (msg.type === 'edge') edgesDataset.update(buildVisEdge(msg.payload));
    if (msg.type === 'done') { es.close(); network.fit(); }
};
```

---

## 5-WEEK BUILD TIMELINE

Execute each week fully before moving to the next. Commit to GitHub at the
end of every week with the tag format `week-N-complete`. Append a summary
entry to `docs/weekly_log.md` with: what was built, what was tested, and any
deviations from spec with justification.

---

### WEEK 1 — Foundation & Database
**Goal:** ShaktiDB schema live, repository initialised, psycopg2 connection verified.

**Tasks — complete all before committing:**

1. Initialise GitHub repo `semantickeep` with the full directory structure above. Create all files (empty where not yet implemented). Add `.gitignore` covering Python, WSL artefacts, `__pycache__`, `.env`, `*.pyc`.

2. Write `schema/schema.sql` in full:
   - All three tables with PK, FK, CHECK constraints
   - All six indexes
   - `knowledge_summary` materialized view with refresh trigger
   - `graph_traversal_template` recursive CTE view
   - Include a `CYCLE` clause or visited-array guard on the recursive CTE to prevent infinite traversal on cyclic graphs
   - Opening comment block: explain why ShaktiDB was chosen (sovereignty, privacy-by-design, MeitY-funded, PostgreSQL 17 fork by IIT Madras Pravartak) and how its design mandate aligns with SemanticKeep's privacy-first constraint

3. Write a `schema/seed_test.sql` that inserts two synthetic documents with three chunks each and two cross-document edges. Used for testing without running the full pipeline.

4. Write `wsl_backend/wsl_server.py` — skeleton only this week:
   - DB connection with exponential backoff retry
   - `send_framed` / `recv_framed` wire protocol helpers
   - Main listener loop (accept + spawn handler thread)
   - DB writer thread reading from `queue.Queue`
   - All logging configured via `logging.basicConfig`

5. Write `requirements_wsl.txt` and `requirements_windows.txt`.

6. Write `README.md` with: project overview, architecture summary, ShaktiDB rationale, setup instructions for WSL and Windows sides, and how to run.

**Week 1 commit tag:** `week-1-complete`

---

### WEEK 2 — TCP Pipeline & Embedding Engine
**Goal:** End-to-end data flow: file in on Windows → embeddings computed on GPU → packets streamed to WSL → inserted into ShaktiDB.

**Tasks:**

1. Complete `wsl_server.py`:
   - Full handler thread: receive packet, validate schema, enqueue
   - DB writer thread: batch insert using `psycopg2.extras.execute_values` for `document_registry`, `content_nodes`, `knowledge_edges` in a single transaction per batch
   - Proper rollback on DB error with logging
   - Graceful SIGTERM handling: drain queue before exit

2. Write `windows_backend/windows_backend.py`:
   - FastAPI app with all five endpoints stubbed (return `{"status": "not implemented"}` for unfinished ones)
   - `SentenceTransformer` model loading at startup with CUDA device
   - `chunk_text()`: overlapping window chunker, 300-word chunks, 50-word overlap, records `line_start`/`line_end` in provenance dict
   - `batch_embed()`: batch size 32, unit-normalized output, log time taken per batch
   - `build_semantic_edges()`: numpy pairwise cosine on unit vectors, threshold 0.4
   - Socket client with reconnect logic connecting to WSL on localhost:5432
   - `POST /upload`: full pipeline — read file → chunk → embed → build edges → stream packets to WSL
   - Log ingestion time breakdown: chunking, embedding, edge-building, transmission

3. Smoke test: ingest one `.txt` file end-to-end, verify rows appear in ShaktiDB via `psql`.

**Week 2 commit tag:** `week-2-complete`

---

### WEEK 3 — Query Engine & Cross-Document Intelligence
**Goal:** Search works. Cross-document edges are built automatically on second upload. Query results stream back to Windows.

**Tasks:**

1. Implement query TCP server on port 5433 in `wsl_server.py`:
   - Receive query packet (`query_vector`, `max_depth`, `top_k`)
   - Execute the recursive CTE against ShaktiDB — parameterised, not string-formatted
   - Refresh `knowledge_summary` materialized view after inserts
   - Return nodes + edges response packet

2. Implement `build_cross_document_edges()` in `windows_backend.py`:
   - On each upload, fetch existing node embeddings from ShaktiDB via a `GET /graph` internal call
   - Compute cosine similarity between new chunks and all existing chunks
   - Emit edges where similarity > 0.5 with `relationship_type='cross_document'`
   - This is the primary differentiator — add a detailed docstring explaining the mechanism and its academic significance

3. Implement `/search` SSE endpoint in FastAPI — full streaming implementation as specified above.

4. Implement `/graph` endpoint: query ShaktiDB for all nodes and edges, return as JSON shaped for Vis.js consumption (`{nodes: [...], edges: [...]}`).

5. Implement `/status` endpoint: return live socket connection state.

6. Integration test: upload two different academic `.txt` files. Verify cross-document edges exist in ShaktiDB with `SELECT * FROM knowledge_edges WHERE relationship_type = 'cross_document';`

**Week 3 commit tag:** `week-3-complete`

---

### WEEK 4 — Frontend: Graph Canvas & Core UI
**Goal:** Dark-mode dashboard running, Vis.js graph renders, node click opens drawer.

**Tasks:**

1. Write `windows_backend/static/index.html`:
   - Full HTML5 document, dark background (`#0f0f13`), Tailwind CSS via CDN
   - Three-panel layout: left sidebar (320px), main canvas (flex-grow), right drawer (380px, hidden by default)
   - Import Vis.js network via CDN
   - Import `app.js` as a module
   - Socket status badge in header (three visual states)
   - Timeline range input below canvas
   - Empty-state overlay on canvas

2. Write `windows_backend/static/app.js`:
   - Vis.js `Network` initialisation with physics config as specified
   - `nodesDataset` and `edgesDataset` as `vis.DataSet` instances
   - `buildVisNode(payload)`: maps API node to Vis node with size from `weighted_degree`, color from centrality thresholds, title for tooltip
   - `buildVisEdge(payload)`: maps API edge to Vis edge with style from `edgeStyles` map
   - On page load: `GET /graph`, populate datasets, fit view
   - Node click handler: populate drawer with raw text, provenance JSON, degree, "Find similar" button
   - Drag-and-drop upload handler on left panel: `FormData` POST to `/upload`, show progress, animate new nodes
   - SSE search handler as specified
   - Timeline slider: `dataset.update()` to toggle node visibility by `imported_at` timestamp
   - Socket status poller: `setInterval` every 3s, `GET /status`, update badge

3. Lasso selection: enable `multiselect: true` in Vis.js options, wire Shift+drag to "Summarise selection" button that POSTs `{node_ids: [...]}` to `/summarise`. `/summarise` concatenates raw text of selected nodes and returns it. Display result in a modal div (not `alert()`).

**Week 4 commit tag:** `week-4-complete`

---

### WEEK 5 — Polish, Testing & GitHub Release
**Goal:** Submission-ready. All features working, documented, and demonstrable.

**Tasks:**

1. **End-to-end test suite** — write `tests/test_pipeline.py`:
   - Test `chunk_text()`: verify overlap, verify provenance keys exist
   - Test `batch_embed()`: verify output shape is `(N, 384)`, verify unit norm
   - Test `build_semantic_edges()`: known vectors → verify correct edges returned
   - Test `send_framed` / `recv_framed`: loopback socket, verify round-trip integrity
   - Test ShaktiDB connection and `SELECT version()` — assert version string contains 'ShaktiDB' or 'PostgreSQL 17'

2. **Performance benchmarking** — write `docs/benchmarks.md`:
   - Measure embedding time: sequential vs batch_size=32 (expect ~8–10× speedup on RTX 4050)
   - Measure ingestion throughput: packets/sec through TCP pipeline
   - Measure query latency: recursive CTE at depth 1 vs depth 2
   - Include actual numbers from your hardware

3. **`docs/architecture.md`** — complete final version:
   - System diagram (ASCII is fine)
   - ShaktiDB rationale section (sovereignty + privacy alignment, MeitY funding, IIT Madras Pravartak)
   - Wire protocol specification (framing, msgpack, packet schema)
   - Cross-document edge algorithm explanation
   - Recursive CTE query plan explanation
   - Known limitations and future work

4. **Final README** — add: demo GIF placeholder, badge for Python version, ShaktiDB logo/link, instructions for running tests and benchmarks.

5. **GitHub release** — create release `v1.0.0` with tag. Write release notes summarising: features built, architecture decisions, ShaktiDB integration, wow-factor features (cross-document edges, SSE streaming, timeline slider, lasso summarise).

6. **Final integration demo checklist** (verify all pass before tagging):
   - [ ] `SELECT version();` in ShaktiDB shows correct version string
   - [ ] Upload doc A → graph renders nodes and edges
   - [ ] Upload doc B → cross-document edges (dashed green) appear
   - [ ] Search query → nodes stream onto graph progressively via SSE
   - [ ] Click node → drawer opens with provenance (page/line)
   - [ ] Timeline slider → filters graph by ingestion date
   - [ ] Shift+drag lasso → summarise modal appears
   - [ ] Kill WSL server → status badge turns red within 3s
   - [ ] Restart WSL server → badge returns to green (auto-reconnect)

**Week 5 commit tag:** `week-5-complete` + release `v1.0.0`

---

## ACADEMIC DIFFERENTIATION NOTES
*(Include these points in architecture.md and code comments)*

- **ShaktiDB**: This project intentionally runs on ShaktiDB rather than stock
  PostgreSQL. ShaktiDB is a sovereign, hardened PostgreSQL 17 fork developed
  by IIT Madras Pravartak and C-DAC, funded by India's Ministry of Electronics
  and Information Technology. Its privacy-by-design and regulatory compliance
  properties directly match SemanticKeep's threat model: a local, air-gapped
  academic vault with no cloud dependencies.

- **Cross-document edges**: Most RAG pipelines treat documents in isolation.
  SemanticKeep builds a semantic bridge between documents at ingestion time,
  creating a living knowledge graph that reveals conceptual overlap the user
  did not explicitly request. This is the academic contribution of the project.

- **No orchestration frameworks**: LangChain and LlamaIndex are explicitly
  excluded. Every pipeline step — chunking, embedding, edge-building, socket
  framing, CTE traversal — is implemented from primitives. This demonstrates
  understanding of the mechanisms, not just API usage.

- **Hybrid query strategy**: Search combines pgvector approximate nearest-
  neighbour (IVFFlat cosine) for semantic relevance with a PostgreSQL recursive
  CTE for structural graph traversal. Neither alone gives the full picture —
  the combination is the design insight.
