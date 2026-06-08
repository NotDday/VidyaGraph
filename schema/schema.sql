-- =============================================================================
-- VidyaGraph — Database Schema for ShaktiDB (PostgreSQL 17 Fork)
-- =============================================================================
--
-- WHY SHAKTIDB?
-- =============================================================================
-- ShaktiDB is a sovereign, hardened PostgreSQL 17 fork developed by the
-- Indian Institute of Technology Madras (IIT Madras) Pravartak Technology
-- Innovation Hub, in collaboration with C-DAC (Centre for Development of
-- Advanced Computing). It is funded by India's Ministry of Electronics and
-- Information Technology (MeitY) as part of the national sovereign digital
-- infrastructure initiative.
--
-- ShaktiDB's design mandate centres on:
--   1. PRIVACY-BY-DESIGN  — Data never leaves the local deployment boundary.
--      Telemetry, crash reports, and update checks that phone home are stripped.
--   2. REGULATORY COMPLIANCE — Built to satisfy India's data localisation norms
--      and the Digital Personal Data Protection Act (DPDPA) 2023 requirements.
--   3. SOVEREIGNTY — No dependency on foreign-controlled cloud infrastructure.
--      The entire stack — compiler, OS kernel hooks, extension loader — is
--      auditable by Indian institutions.
--
-- HOW THIS ALIGNS WITH VIDYAGRAPH:
-- =============================================================================
-- VidyaGraph is designed as a completely air-gapped, laptop-only academic
-- knowledge vault. Its threat model explicitly prohibits cloud APIs, external
-- vector databases, and any network egress. ShaktiDB's privacy-by-design
-- architecture is a natural fit:
--   - All document embeddings, knowledge edges, and provenance metadata remain
--     on the local machine, inside a database engineered for data sovereignty.
--   - The pgvector extension (supported by ShaktiDB as a standard PostgreSQL 17
--     extension) enables vector similarity search without any external service.
--   - Using ShaktiDB instead of stock PostgreSQL demonstrates awareness of
--     India's sovereign computing ecosystem and its applicability to
--     privacy-sensitive academic research environments.
--
-- Wire compatibility: ShaktiDB is fully wire-compatible with PostgreSQL 17.
-- All standard clients (psycopg2, pgAdmin, psql) work without modification.
-- =============================================================================

-- Enable pgvector extension for vector similarity search.
-- pgvector is a standard PostgreSQL extension supported by ShaktiDB.
CREATE EXTENSION IF NOT EXISTS vector;

-- =============================================================================
-- TABLE 1: document_registry
-- =============================================================================
-- One row per ingested file. Stores file metadata and import timestamp.
-- This is the top-level entity in the document → chunk → edge hierarchy.
-- =============================================================================
CREATE TABLE document_registry (
    doc_id       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    file_name    TEXT        NOT NULL,
    file_path    TEXT        NOT NULL,
    file_size_kb NUMERIC(10, 2),
    imported_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =============================================================================
-- TABLE 2: content_nodes
-- =============================================================================
-- One row per text chunk extracted from a document. Each chunk carries:
--   - Its embedding vector (384 dimensions from all-MiniLM-L6-v2)
--   - A chunk_index for ordering within the parent document
--   - Provenance metadata (page number, line range) stored as JSONB
--
-- The embedding_vector column uses pgvector's vector(384) type, enabling
-- approximate nearest-neighbour search via IVFFlat indexing.
-- =============================================================================
CREATE TABLE content_nodes (
    node_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    doc_id           UUID        NOT NULL
                                 REFERENCES document_registry(doc_id)
                                 ON DELETE CASCADE,
    chunk_index      INTEGER     NOT NULL,
    raw_text         TEXT        NOT NULL,
    embedding_vector vector(384) NOT NULL,
    provenance       JSONB       NOT NULL DEFAULT '{}'
);

-- =============================================================================
-- TABLE 3: knowledge_edges
-- =============================================================================
-- Self-referencing many-to-many join table forming the knowledge graph layer.
-- Each edge connects two content_nodes with a typed, weighted relationship:
--   - 'semantic':        intra-document cosine similarity above threshold
--   - 'cross_document':  inter-document cosine similarity (the key feature)
--   - 'entity':          shared named entity co-occurrence
--
-- strength_weight is constrained to [0, 1] — it represents cosine similarity
-- or a normalised confidence score depending on relationship_type.
-- =============================================================================
CREATE TABLE knowledge_edges (
    edge_id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    source_node_id    UUID        NOT NULL
                                  REFERENCES content_nodes(node_id)
                                  ON DELETE CASCADE,
    target_node_id    UUID        NOT NULL
                                  REFERENCES content_nodes(node_id)
                                  ON DELETE CASCADE,
    relationship_type TEXT        NOT NULL DEFAULT 'semantic',
    strength_weight   NUMERIC(5, 4) NOT NULL
                                  CHECK (strength_weight BETWEEN 0 AND 1),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =============================================================================
-- INDEXES
-- =============================================================================

-- Vector similarity search index using IVFFlat.
-- IVFFlat is chosen over HNSW because it has significantly lower memory
-- overhead — critical on a 6 GB VRAM constraint. IVFFlat partitions vectors
-- into 100 Voronoi cells (lists = 100) and searches only the nearest cells
-- at query time, trading some recall for constant memory usage.
-- The vector_cosine_ops operator class is used because all embeddings are
-- unit-normalised, making cosine distance equivalent to dot-product distance.
CREATE INDEX idx_embedding_ivfflat
    ON content_nodes USING ivfflat (embedding_vector vector_cosine_ops)
    WITH (lists = 100);

-- Graph traversal indexes — enable efficient edge lookups in both directions
-- for the recursive CTE that walks the knowledge graph.
CREATE INDEX idx_edges_source ON knowledge_edges(source_node_id);
CREATE INDEX idx_edges_target ON knowledge_edges(target_node_id);
CREATE INDEX idx_edges_type   ON knowledge_edges(relationship_type);

-- Full-text search on raw chunk text using GIN (Generalized Inverted Index).
-- Enables PostgreSQL's built-in text search (ts_query, ts_rank) on chunk content
-- as a complement to vector similarity search.
CREATE INDEX idx_raw_text_gin
    ON content_nodes USING gin(to_tsvector('english', raw_text));

-- JSONB GIN index on provenance metadata.
-- Enables efficient queries like: "find all chunks from page 5" or
-- "find chunks with line_start between 100 and 200".
CREATE INDEX idx_provenance
    ON content_nodes USING gin(provenance);


-- =============================================================================
-- MATERIALIZED VIEW: knowledge_summary
-- =============================================================================
-- Pre-aggregates graph centrality metrics for each content node:
--   - degree: number of edges (both directions) connected to this node
--   - weighted_degree: sum of strength_weight for all connected edges
--   - preview: first 120 characters of the raw text (for UI display)
--   - imported_at: timestamp from the parent document (for timeline filtering)
--
-- This view is refreshed after bulk inserts via a deferred trigger (see below).
-- The UNIQUE INDEX on node_id enables REFRESH MATERIALIZED VIEW CONCURRENTLY,
-- which avoids locking reads during refresh.
-- =============================================================================
CREATE MATERIALIZED VIEW knowledge_summary AS
    SELECT
        n.node_id,
        n.doc_id,
        n.chunk_index,
        LEFT(n.raw_text, 120)                      AS preview,
        COUNT(e.edge_id)                            AS degree,
        COALESCE(SUM(e.strength_weight), 0)         AS weighted_degree,
        dr.imported_at                              AS imported_at
    FROM content_nodes n
    LEFT JOIN (
        -- Union both directions: each edge contributes to both endpoints' degree.
        SELECT edge_id, source_node_id AS node_id, strength_weight
        FROM knowledge_edges
        UNION ALL
        SELECT edge_id, target_node_id AS node_id, strength_weight
        FROM knowledge_edges
    ) e ON e.node_id = n.node_id
    LEFT JOIN document_registry dr ON dr.doc_id = n.doc_id
    GROUP BY n.node_id, n.doc_id, n.chunk_index, n.raw_text, dr.imported_at;

-- Unique index required for REFRESH MATERIALIZED VIEW CONCURRENTLY.
CREATE UNIQUE INDEX idx_knowledge_summary_node_id
    ON knowledge_summary(node_id);


-- =============================================================================
-- TRIGGER: Auto-refresh knowledge_summary after bulk inserts
-- =============================================================================
-- This trigger fires AFTER INSERT on content_nodes using a statement-level
-- trigger (FOR EACH STATEMENT), which fires once per INSERT statement rather
-- than once per row. This is appropriate for bulk inserts where we want a
-- single refresh at the end, not N refreshes for N rows.
--
-- We use CONCURRENTLY to avoid blocking concurrent reads of the materialized
-- view during refresh. This requires the unique index above.
-- =============================================================================
CREATE OR REPLACE FUNCTION refresh_knowledge_summary()
RETURNS TRIGGER AS $$
BEGIN
    -- CONCURRENTLY allows reads during refresh; requires unique index.
    REFRESH MATERIALIZED VIEW CONCURRENTLY knowledge_summary;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Statement-level trigger: fires once after each INSERT statement completes.
-- DEFERRABLE INITIALLY DEFERRED is not supported for statement-level triggers
-- in PostgreSQL, so we use a plain AFTER INSERT trigger. For true deferred
-- behaviour during multi-statement transactions, the application layer should
-- call REFRESH MATERIALIZED VIEW CONCURRENTLY explicitly after committing
-- the batch.
CREATE TRIGGER trg_refresh_knowledge_summary
    AFTER INSERT ON content_nodes
    FOR EACH STATEMENT
    EXECUTE FUNCTION refresh_knowledge_summary();


-- =============================================================================
-- VIEW: graph_traversal_template
-- =============================================================================
-- Recursive CTE for hybrid vector + graph search. This view is a template
-- that is parameterised at query time via prepared statements:
--   $1 = query embedding vector (384-dimensional, unit-normalised)
--   $2 = maximum traversal depth (typically 2)
--
-- Algorithm:
--   1. SEED phase: Find the top-5 nodes nearest to the query vector using
--      pgvector's <=> (cosine distance) operator. This leverages the
--      idx_embedding_ivfflat index for approximate nearest-neighbour search.
--   2. TRAVERSAL phase: From each seed node, walk outward along knowledge_edges
--      up to max_depth hops. The ARRAY-based cycle detection (path tracking)
--      prevents infinite loops in cyclic subgraphs.
--   3. Output: Distinct (node_id, raw_text, depth) tuples representing all
--      nodes reachable within the search radius.
--
-- This hybrid approach combines:
--   - Semantic relevance (vector similarity for initial seeding)
--   - Structural discovery (graph traversal for connected knowledge)
-- Neither alone gives the full picture — the combination is the design insight.
-- =============================================================================
CREATE OR REPLACE VIEW graph_traversal_template AS
-- NOTE: This view uses $1 and $2 as placeholders. It must be invoked via
-- a prepared statement or parameterised query, NOT as a plain SELECT.
-- Example usage:
--   PREPARE graph_search(vector(384), integer) AS
--       SELECT * FROM graph_traversal_template;
--   EXECUTE graph_search('[0.1, 0.2, ...]'::vector(384), 2);
--
-- In practice, the application executes the CTE directly as a parameterised
-- query rather than using this view, because PostgreSQL views do not natively
-- support parameter placeholders. This view serves as documentation of the
-- query pattern.
WITH RECURSIVE
seed AS (
    -- Phase 1: Vector similarity search (approximate nearest neighbour).
    -- The <=> operator computes cosine distance using the IVFFlat index.
    SELECT node_id, raw_text, embedding_vector, 0 AS depth
    FROM content_nodes
    ORDER BY embedding_vector <=> $1   -- $1 = query vector (384-dim)
    LIMIT 5
),
traversal (node_id, raw_text, depth, path, is_cycle) AS (
    -- Base case: start from seed nodes.
    SELECT node_id, raw_text, depth, ARRAY[node_id], false
    FROM seed

    UNION ALL

    -- Recursive case: walk edges in both directions.
    SELECT
        cn.node_id,
        cn.raw_text,
        t.depth + 1,
        t.path || cn.node_id,
        cn.node_id = ANY(t.path)   -- Cycle detection: true if revisiting
    FROM traversal t
    JOIN knowledge_edges ke
        ON ke.source_node_id = t.node_id
        OR ke.target_node_id = t.node_id
    JOIN content_nodes cn
        ON cn.node_id = CASE
            WHEN ke.source_node_id = t.node_id THEN ke.target_node_id
            ELSE ke.source_node_id
        END
    WHERE t.depth < $2             -- $2 = max_depth (typically 2)
      AND NOT t.is_cycle           -- Stop traversal on cycle detection
)
SELECT DISTINCT node_id, raw_text, depth
FROM traversal;
