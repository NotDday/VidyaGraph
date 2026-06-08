-- =============================================================================
-- VidyaGraph — Seed Test Data
-- =============================================================================
-- Inserts synthetic test data for verifying the schema without running the
-- full embedding pipeline. Contains:
--   - 2 documents (simulating two academic papers)
--   - 3 chunks per document (6 content_nodes total)
--   - 3 intra-document semantic edges
--   - 2 cross-document edges (the key feature)
--
-- Embedding vectors are random 384-dimensional unit vectors. They will NOT
-- produce meaningful similarity results, but they validate schema constraints,
-- index creation, and the materialized view refresh trigger.
--
-- Usage:
--   psql -U vidyagraph -d vidyagraph -f schema/seed_test.sql
--
-- Prerequisites:
--   schema/schema.sql must be applied first.
-- =============================================================================

-- Temporarily disable the materialized view refresh trigger during bulk insert.
-- We will refresh manually at the end to avoid multiple refreshes.
ALTER TABLE content_nodes DISABLE TRIGGER trg_refresh_knowledge_summary;

-- =============================================================================
-- Document 1: "Attention Is All You Need" (synthetic)
-- =============================================================================
INSERT INTO document_registry (doc_id, file_name, file_path, file_size_kb)
VALUES (
    'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
    'attention_is_all_you_need.txt',
    '/home/user/papers/attention_is_all_you_need.txt',
    42.50
);

-- Chunk 1: Abstract
INSERT INTO content_nodes (node_id, doc_id, chunk_index, raw_text, embedding_vector, provenance)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
    0,
    'The dominant sequence transduction models are based on complex recurrent or convolutional neural networks that include an encoder and a decoder. The best performing models also connect the encoder and decoder through an attention mechanism. We propose a new simple network architecture, the Transformer, based solely on attention mechanisms, dispensing with recurrence and convolutions entirely.',
    -- Random 384-dim vector (truncated representation — pgvector accepts array syntax)
    ('[' || array_to_string(ARRAY(SELECT round(random()::numeric, 6) FROM generate_series(1, 384)), ',') || ']')::vector(384),
    '{"page": 1, "line_start": 1, "line_end": 8}'::jsonb
);

-- Chunk 2: Architecture overview
INSERT INTO content_nodes (node_id, doc_id, chunk_index, raw_text, embedding_vector, provenance)
VALUES (
    '22222222-2222-2222-2222-222222222222',
    'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
    1,
    'The Transformer follows an encoder-decoder structure using stacked self-attention and point-wise fully connected layers for both the encoder and decoder. The encoder maps an input sequence of symbol representations to a sequence of continuous representations. The decoder then generates an output sequence of symbols one element at a time.',
    ('[' || array_to_string(ARRAY(SELECT round(random()::numeric, 6) FROM generate_series(1, 384)), ',') || ']')::vector(384),
    '{"page": 2, "line_start": 9, "line_end": 16}'::jsonb
);

-- Chunk 3: Multi-head attention
INSERT INTO content_nodes (node_id, doc_id, chunk_index, raw_text, embedding_vector, provenance)
VALUES (
    '33333333-3333-3333-3333-333333333333',
    'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
    2,
    'Multi-head attention allows the model to jointly attend to information from different representation subspaces at different positions. Instead of performing a single attention function, we linearly project the queries, keys and values multiple times with different learned projections.',
    ('[' || array_to_string(ARRAY(SELECT round(random()::numeric, 6) FROM generate_series(1, 384)), ',') || ']')::vector(384),
    '{"page": 3, "line_start": 17, "line_end": 24}'::jsonb
);

-- =============================================================================
-- Document 2: "BERT: Pre-training of Deep Bidirectional Transformers" (synthetic)
-- =============================================================================
INSERT INTO document_registry (doc_id, file_name, file_path, file_size_kb)
VALUES (
    'b2c3d4e5-f6a7-8901-bcde-f12345678901',
    'bert_pretraining.txt',
    '/home/user/papers/bert_pretraining.txt',
    38.75
);

-- Chunk 1: Abstract
INSERT INTO content_nodes (node_id, doc_id, chunk_index, raw_text, embedding_vector, provenance)
VALUES (
    '44444444-4444-4444-4444-444444444444',
    'b2c3d4e5-f6a7-8901-bcde-f12345678901',
    0,
    'We introduce a new language representation model called BERT, which stands for Bidirectional Encoder Representations from Transformers. Unlike recent language representation models, BERT is designed to pre-train deep bidirectional representations from unlabeled text by jointly conditioning on both left and right context.',
    ('[' || array_to_string(ARRAY(SELECT round(random()::numeric, 6) FROM generate_series(1, 384)), ',') || ']')::vector(384),
    '{"page": 1, "line_start": 1, "line_end": 7}'::jsonb
);

-- Chunk 2: Pre-training objectives
INSERT INTO content_nodes (node_id, doc_id, chunk_index, raw_text, embedding_vector, provenance)
VALUES (
    '55555555-5555-5555-5555-555555555555',
    'b2c3d4e5-f6a7-8901-bcde-f12345678901',
    1,
    'BERT uses two unsupervised pre-training objectives. The first is masked language modeling where random tokens are replaced with a mask token and the model predicts the original token. The second is next sentence prediction where the model learns to predict whether two sentences are consecutive in the original text.',
    ('[' || array_to_string(ARRAY(SELECT round(random()::numeric, 6) FROM generate_series(1, 384)), ',') || ']')::vector(384),
    '{"page": 2, "line_start": 8, "line_end": 15}'::jsonb
);

-- Chunk 3: Fine-tuning and attention
INSERT INTO content_nodes (node_id, doc_id, chunk_index, raw_text, embedding_vector, provenance)
VALUES (
    '66666666-6666-6666-6666-666666666666',
    'b2c3d4e5-f6a7-8901-bcde-f12345678901',
    2,
    'The BERT model architecture is based on the multi-layer bidirectional Transformer encoder. The attention mechanism in BERT allows each token to attend to all other tokens in the input sequence, capturing long-range dependencies that are crucial for natural language understanding tasks.',
    ('[' || array_to_string(ARRAY(SELECT round(random()::numeric, 6) FROM generate_series(1, 384)), ',') || ']')::vector(384),
    '{"page": 3, "line_start": 16, "line_end": 22}'::jsonb
);

-- =============================================================================
-- KNOWLEDGE EDGES
-- =============================================================================

-- Intra-document semantic edges (Document 1: Transformer paper)
-- Chunk 0 ↔ Chunk 1: Both discuss transformer architecture
INSERT INTO knowledge_edges (source_node_id, target_node_id, relationship_type, strength_weight)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    'semantic',
    0.7200
);

-- Chunk 1 ↔ Chunk 2: Encoder-decoder and multi-head attention connection
INSERT INTO knowledge_edges (source_node_id, target_node_id, relationship_type, strength_weight)
VALUES (
    '22222222-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333',
    'semantic',
    0.6500
);

-- Intra-document semantic edge (Document 2: BERT paper)
-- Chunk 0 ↔ Chunk 2: Both discuss attention/transformer fundamentals
INSERT INTO knowledge_edges (source_node_id, target_node_id, relationship_type, strength_weight)
VALUES (
    '44444444-4444-4444-4444-444444444444',
    '66666666-6666-6666-6666-666666666666',
    'semantic',
    0.6800
);

-- =============================================================================
-- CROSS-DOCUMENT EDGES (The primary "wow-factor" feature)
-- =============================================================================
-- These edges bridge different papers that share conceptual overlap.
-- In the real pipeline, they are discovered automatically when a new document
-- is uploaded and its chunk embeddings are compared against all existing chunks.

-- Transformer abstract ↔ BERT abstract: both discuss attention-based models
INSERT INTO knowledge_edges (source_node_id, target_node_id, relationship_type, strength_weight)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    '44444444-4444-4444-4444-444444444444',
    'cross_document',
    0.8100
);

-- Transformer multi-head attention ↔ BERT attention mechanism: directly related
INSERT INTO knowledge_edges (source_node_id, target_node_id, relationship_type, strength_weight)
VALUES (
    '33333333-3333-3333-3333-333333333333',
    '66666666-6666-6666-6666-666666666666',
    'cross_document',
    0.8500
);

-- =============================================================================
-- Re-enable trigger and refresh materialized view
-- =============================================================================
ALTER TABLE content_nodes ENABLE TRIGGER trg_refresh_knowledge_summary;

-- Manually refresh the materialized view with all seed data.
REFRESH MATERIALIZED VIEW CONCURRENTLY knowledge_summary;

-- =============================================================================
-- Verification queries — run these to confirm seed data is correct
-- =============================================================================

-- Count documents (expect 2)
SELECT 'document_registry' AS table_name, COUNT(*) AS row_count
FROM document_registry;

-- Count content nodes (expect 6)
SELECT 'content_nodes' AS table_name, COUNT(*) AS row_count
FROM content_nodes;

-- Count edges (expect 5: 3 semantic + 2 cross_document)
SELECT 'knowledge_edges' AS table_name, COUNT(*) AS row_count
FROM knowledge_edges;

-- Verify edge type distribution
SELECT relationship_type, COUNT(*) AS edge_count
FROM knowledge_edges
GROUP BY relationship_type;

-- Verify materialized view was refreshed (expect 6 rows)
SELECT node_id, preview, degree, weighted_degree, imported_at
FROM knowledge_summary
ORDER BY weighted_degree DESC;

-- Verify cross-document edges specifically (the key feature)
SELECT
    ke.relationship_type,
    ke.strength_weight,
    LEFT(src.raw_text, 60) AS source_preview,
    LEFT(tgt.raw_text, 60) AS target_preview
FROM knowledge_edges ke
JOIN content_nodes src ON src.node_id = ke.source_node_id
JOIN content_nodes tgt ON tgt.node_id = ke.target_node_id
WHERE ke.relationship_type = 'cross_document';
