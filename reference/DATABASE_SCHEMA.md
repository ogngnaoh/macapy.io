# macapy.io Database Schema

**Project**: macapy.io - AI-Powered Personal Meeting Assistant
**Last Updated**: 2025-10-09
**Database**: PostgreSQL 15+ with pgvector extension

This document provides the complete database schema for macapy.io, including table structures, relationships, indexes, and example queries.

---

## Table of Contents

1. [Schema Overview](#schema-overview)
2. [Table Definitions](#table-definitions)
3. [Relationships](#relationships)
4. [Indexes](#indexes)
5. [Example Queries](#example-queries)
6. [Migration Strategy](#migration-strategy)

---

## Schema Overview

### Entity-Relationship Diagram

```
┌─────────────────┐
│    meetings     │
│─────────────────│
│ id (PK)         │
│ title           │
│ start_time      │
│ end_time        │
│ platform        │
│ status          │
│ created_at      │
│ updated_at      │
└────────┬────────┘
         │ 1
         │
         │ N
    ┌────┴─────────────────────────────────┐
    │                                      │
┌───▼──────────────┐              ┌───────▼──────────────┐
│   transcripts    │              │ context_documents    │
│──────────────────│              │──────────────────────│
│ id (PK)          │              │ id (PK)              │
│ meeting_id (FK)  │              │ meeting_id (FK)      │
│ speaker          │              │ filename             │
│ text             │              │ file_type            │
│ start_timestamp  │              │ file_path            │
│ end_timestamp    │              │ extracted_text       │
│ confidence       │              │ upload_timestamp     │
│ created_at       │              │ is_active            │
└──────────────────┘              └───────┬──────────────┘
                                          │ 1
    ┌─────────────────┐                   │
    │   summaries     │                   │ N
    │─────────────────│           ┌───────▼──────────────┐
    │ id (PK)         │           │  context_chunks      │
    │ meeting_id (FK) │           │──────────────────────│
    │ summary_text    │           │ id (PK)              │
    │ time_range_start│           │ document_id (FK)     │
    │ time_range_end  │           │ chunk_text           │
    │ created_at      │           │ chunk_index          │
    └─────────────────┘           │ embedding (vector)   │
                                  │ metadata (JSONB)     │
    ┌──────────────────────┐      └──────────────────────┘
    │ response_suggestions │
    │──────────────────────│
    │ id (PK)              │
    │ meeting_id (FK)      │
    │ question_text        │
    │ suggestion_text      │
    │ context_used (JSONB) │
    │ timestamp            │
    │ was_used             │
    │ created_at           │
    └──────────────────────┘
```

---

## Table Definitions

### 1. meetings

**Purpose**: Store metadata for each meeting session

```sql
CREATE TABLE meetings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(255) NOT NULL,
    start_time TIMESTAMP NOT NULL,
    end_time TIMESTAMP,
    platform VARCHAR(50),  -- 'zoom', 'google_meet', 'teams', 'other'
    status VARCHAR(20) DEFAULT 'in_progress',  -- 'in_progress', 'completed', 'archived'
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_meetings_status ON meetings(status);
CREATE INDEX idx_meetings_start_time ON meetings(start_time DESC);

-- Comments
COMMENT ON TABLE meetings IS 'Stores metadata for each meeting session';
COMMENT ON COLUMN meetings.platform IS 'Meeting platform: zoom, google_meet, teams, other';
COMMENT ON COLUMN meetings.status IS 'Meeting status: in_progress, completed, archived';
```

**Columns**:
- `id`: UUID primary key, auto-generated
- `title`: User-provided meeting title (e.g., "Interview with ABC Corp")
- `start_time`: Timestamp when meeting started
- `end_time`: Timestamp when meeting ended (null while in progress)
- `platform`: Meeting platform name
- `status`: Current status of the meeting
- `created_at`: Record creation timestamp
- `updated_at`: Last update timestamp

---

### 2. transcripts

**Purpose**: Store transcript segments with timestamps and speaker information

```sql
CREATE TABLE transcripts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id UUID NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    speaker VARCHAR(50) DEFAULT 'unknown',  -- 'user', 'participant_1', etc.
    text TEXT NOT NULL,
    start_timestamp FLOAT NOT NULL,  -- Seconds from meeting start
    end_timestamp FLOAT NOT NULL,    -- Seconds from meeting start
    confidence FLOAT,  -- Transcription confidence score (0.0-1.0)
    created_at TIMESTAMP DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_transcripts_meeting ON transcripts(meeting_id, start_timestamp);
CREATE INDEX idx_transcripts_speaker ON transcripts(meeting_id, speaker);

-- Comments
COMMENT ON TABLE transcripts IS 'Stores transcript segments with timestamps';
COMMENT ON COLUMN transcripts.start_timestamp IS 'Seconds elapsed from meeting start';
COMMENT ON COLUMN transcripts.confidence IS 'Transcription confidence score from Whisper API';
```

**Columns**:
- `id`: UUID primary key
- `meeting_id`: Foreign key to meetings table
- `speaker`: Speaker identifier (for future speaker diarization)
- `text`: Transcript text content
- `start_timestamp`: Start time in seconds from meeting start
- `end_timestamp`: End time in seconds from meeting start
- `confidence`: Whisper API confidence score
- `created_at`: Record creation timestamp

**Notes**:
- `ON DELETE CASCADE`: When meeting is deleted, all transcripts are deleted
- Timestamps are relative to meeting start (easier for playback)

---

### 3. summaries

**Purpose**: Store generated summaries for time ranges within meetings

```sql
CREATE TABLE summaries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id UUID NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    summary_text TEXT NOT NULL,
    time_range_start FLOAT NOT NULL,  -- Seconds from meeting start
    time_range_end FLOAT NOT NULL,    -- Seconds from meeting start
    created_at TIMESTAMP DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_summaries_meeting ON summaries(meeting_id, created_at DESC);

-- Comments
COMMENT ON TABLE summaries IS 'Stores rolling summaries for meeting time ranges';
COMMENT ON COLUMN summaries.time_range_start IS 'Start of summarized period (seconds from meeting start)';
COMMENT ON COLUMN summaries.time_range_end IS 'End of summarized period (seconds from meeting start)';
```

**Columns**:
- `id`: UUID primary key
- `meeting_id`: Foreign key to meetings table
- `summary_text`: Generated summary content
- `time_range_start`: Start of summarized time range
- `time_range_end`: End of summarized time range
- `created_at`: When summary was generated

**Example**:
A summary covering minutes 10-15 of a meeting would have:
- `time_range_start`: 600.0
- `time_range_end`: 900.0

---

### 4. context_documents

**Purpose**: Store uploaded documents for each meeting

```sql
CREATE TABLE context_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id UUID REFERENCES meetings(id) ON DELETE SET NULL,
    filename VARCHAR(255) NOT NULL,
    file_type VARCHAR(20) NOT NULL,  -- 'pdf', 'docx', 'txt', 'md'
    file_path TEXT NOT NULL,  -- Local file system path
    extracted_text TEXT,  -- Full extracted text content
    upload_timestamp TIMESTAMP DEFAULT NOW(),
    is_active BOOLEAN DEFAULT TRUE  -- For temporary context during call
);

-- Indexes
CREATE INDEX idx_context_documents_meeting ON context_documents(meeting_id);
CREATE INDEX idx_context_documents_active ON context_documents(is_active) WHERE is_active = TRUE;

-- Comments
COMMENT ON TABLE context_documents IS 'Stores uploaded context documents for meetings';
COMMENT ON COLUMN context_documents.is_active IS 'Whether document is active for current meeting';
```

**Columns**:
- `id`: UUID primary key
- `meeting_id`: Foreign key to meetings table (nullable for reusable docs)
- `filename`: Original filename
- `file_type`: File extension (pdf, docx, txt, md)
- `file_path`: Path to stored file on local filesystem
- `extracted_text`: Full text content extracted from file
- `upload_timestamp`: When file was uploaded
- `is_active`: Whether document is currently active

**Notes**:
- `ON DELETE SET NULL`: If meeting is deleted, document persists (can be reused)
- Set `is_active = FALSE` when meeting ends to cleanup temporary context

---

### 5. context_chunks

**Purpose**: Store document chunks with embeddings for semantic search

```sql
-- Install pgvector extension first
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE context_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID NOT NULL REFERENCES context_documents(id) ON DELETE CASCADE,
    chunk_text TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,  -- Order within document
    embedding VECTOR(384),  -- 384 dimensions for all-MiniLM-L6-v2
    metadata JSONB  -- Store page number, section title, etc.
);

-- Indexes
CREATE INDEX idx_context_chunks_document ON context_chunks(document_id, chunk_index);
CREATE INDEX idx_context_chunks_embedding ON context_chunks
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

-- Comments
COMMENT ON TABLE context_chunks IS 'Stores document chunks with embeddings for semantic search';
COMMENT ON COLUMN context_chunks.embedding IS 'Vector embedding (384-dim) for semantic similarity search';
COMMENT ON COLUMN context_chunks.metadata IS 'JSONB: page_number, section_title, etc.';
```

**Columns**:
- `id`: UUID primary key
- `document_id`: Foreign key to context_documents table
- `chunk_text`: Text content of this chunk
- `chunk_index`: Sequential index within document (0, 1, 2, ...)
- `embedding`: Vector embedding (384 dimensions)
- `metadata`: JSON object with additional info

**Metadata Example**:
```json
{
  "page_number": 2,
  "section_title": "Work Experience",
  "char_start": 150,
  "char_end": 650
}
```

**Notes**:
- Vector dimension must match embedding model (384 for all-MiniLM-L6-v2)
- IVFFlat index for fast approximate nearest neighbor search
- `lists = 100`: Number of clusters for IVFFlat (tune based on data size)

---

### 6. response_suggestions

**Purpose**: Log generated response suggestions for analytics and debugging

```sql
CREATE TABLE response_suggestions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id UUID NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    question_text TEXT,  -- Detected question
    suggestion_text TEXT NOT NULL,  -- Generated suggestion
    context_used JSONB,  -- References to chunks used
    timestamp FLOAT NOT NULL,  -- Seconds from meeting start
    was_used BOOLEAN DEFAULT FALSE,  -- Did user click/use it?
    created_at TIMESTAMP DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_response_suggestions_meeting ON response_suggestions(meeting_id, timestamp);
CREATE INDEX idx_response_suggestions_used ON response_suggestions(was_used);

-- Comments
COMMENT ON TABLE response_suggestions IS 'Logs generated response suggestions';
COMMENT ON COLUMN response_suggestions.context_used IS 'JSONB array of chunk IDs used for context';
COMMENT ON COLUMN response_suggestions.was_used IS 'Whether user clicked or used this suggestion';
```

**Columns**:
- `id`: UUID primary key
- `meeting_id`: Foreign key to meetings table
- `question_text`: The question that triggered suggestion
- `suggestion_text`: The generated suggestion
- `context_used`: JSON array of context chunk IDs
- `timestamp`: When suggestion was generated (seconds from meeting start)
- `was_used`: Whether user used this suggestion
- `created_at`: Record creation timestamp

**Context Used Example**:
```json
{
  "chunk_ids": ["uuid-1", "uuid-2"],
  "relevance_scores": [0.85, 0.78]
}
```

---

## Relationships

### One-to-Many Relationships

1. **meetings → transcripts** (1:N)
   - One meeting has many transcript segments
   - Cascade delete: Deleting meeting deletes all transcripts

2. **meetings → summaries** (1:N)
   - One meeting has many summaries (rolling summaries)
   - Cascade delete: Deleting meeting deletes all summaries

3. **meetings → context_documents** (1:N)
   - One meeting can have multiple uploaded documents
   - Set null on delete: Documents persist after meeting deleted

4. **meetings → response_suggestions** (1:N)
   - One meeting has many suggestions generated
   - Cascade delete: Deleting meeting deletes all suggestions

5. **context_documents → context_chunks** (1:N)
   - One document has many chunks
   - Cascade delete: Deleting document deletes all chunks

---

## Indexes

### Purpose and Rationale

**1. Query Performance**:
```sql
-- Fast lookup of meetings by status
CREATE INDEX idx_meetings_status ON meetings(status);

-- Fast lookup of recent meetings
CREATE INDEX idx_meetings_start_time ON meetings(start_time DESC);
```

**2. Foreign Key Queries**:
```sql
-- Fast retrieval of transcripts for a meeting, ordered by time
CREATE INDEX idx_transcripts_meeting ON transcripts(meeting_id, start_timestamp);

-- Fast vector similarity search
CREATE INDEX idx_context_chunks_embedding ON context_chunks
    USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
```

**3. Conditional Indexes** (for frequent filters):
```sql
-- Only index active documents (smaller, faster)
CREATE INDEX idx_context_documents_active ON context_documents(is_active)
    WHERE is_active = TRUE;
```

---

## Example Queries

### 1. Get All Transcripts for a Meeting

```sql
SELECT
    t.speaker,
    t.text,
    t.start_timestamp,
    t.end_timestamp,
    t.confidence
FROM transcripts t
WHERE t.meeting_id = 'meeting-uuid-here'
ORDER BY t.start_timestamp ASC;
```

### 2. Get Recent Summary for a Meeting

```sql
SELECT
    s.summary_text,
    s.time_range_start,
    s.time_range_end,
    s.created_at
FROM summaries s
WHERE s.meeting_id = 'meeting-uuid-here'
ORDER BY s.created_at DESC
LIMIT 1;
```

### 3. Vector Similarity Search for Context

```sql
-- Find top 5 most similar chunks to query embedding
SELECT
    cc.chunk_text,
    cc.metadata,
    cd.filename,
    cc.embedding <=> '[0.1, 0.2, ..., 0.9]'::vector AS distance
FROM context_chunks cc
JOIN context_documents cd ON cc.document_id = cd.id
WHERE cd.meeting_id = 'meeting-uuid-here'
  AND cd.is_active = TRUE
ORDER BY cc.embedding <=> '[0.1, 0.2, ..., 0.9]'::vector
LIMIT 5;
```

**Operators**:
- `<=>`: Cosine distance (0 = identical, 2 = opposite)
- `<->`: L2 distance (Euclidean)
- `<#>`: Inner product

### 4. Get Full Meeting Context

```sql
SELECT
    m.id AS meeting_id,
    m.title,
    m.start_time,
    m.end_time,
    m.platform,
    COUNT(DISTINCT t.id) AS transcript_count,
    COUNT(DISTINCT s.id) AS summary_count,
    COUNT(DISTINCT cd.id) AS document_count
FROM meetings m
LEFT JOIN transcripts t ON m.id = t.meeting_id
LEFT JOIN summaries s ON m.id = s.meeting_id
LEFT JOIN context_documents cd ON m.id = cd.meeting_id
WHERE m.id = 'meeting-uuid-here'
GROUP BY m.id, m.title, m.start_time, m.end_time, m.platform;
```

### 5. Get Meeting History (Last 30 Days)

```sql
SELECT
    m.id,
    m.title,
    m.start_time,
    m.platform,
    m.status,
    EXTRACT(EPOCH FROM (m.end_time - m.start_time)) / 60 AS duration_minutes,
    COUNT(t.id) AS transcript_segments
FROM meetings m
LEFT JOIN transcripts t ON m.id = t.meeting_id
WHERE m.start_time >= NOW() - INTERVAL '30 days'
GROUP BY m.id, m.title, m.start_time, m.platform, m.status, m.end_time
ORDER BY m.start_time DESC;
```

### 6. Analytics: Suggestion Usage Rate

```sql
SELECT
    m.title,
    COUNT(rs.id) AS total_suggestions,
    SUM(CASE WHEN rs.was_used THEN 1 ELSE 0 END) AS used_suggestions,
    ROUND(
        100.0 * SUM(CASE WHEN rs.was_used THEN 1 ELSE 0 END) / COUNT(rs.id),
        2
    ) AS usage_rate_percent
FROM meetings m
JOIN response_suggestions rs ON m.id = rs.meeting_id
GROUP BY m.id, m.title
ORDER BY usage_rate_percent DESC;
```

---

## Migration Strategy

### Using Alembic

**1. Initialize Alembic**:
```bash
cd backend
alembic init alembic
```

**2. Configure Alembic**:

Edit `alembic/env.py`:
```python
from app.models import Base  # Import your SQLAlchemy Base
target_metadata = Base.metadata
```

Edit `alembic.ini`:
```ini
sqlalchemy.url = postgresql://user:pass@localhost:5432/macapy
```

**3. Create Initial Migration**:
```bash
alembic revision --autogenerate -m "Initial schema"
```

**4. Review Generated Migration**:
```python
# alembic/versions/xxxxx_initial_schema.py

def upgrade():
    # Create tables
    op.create_table('meetings', ...)
    op.create_table('transcripts', ...)
    # ... etc

def downgrade():
    # Drop tables in reverse order
    op.drop_table('transcripts')
    op.drop_table('meetings')
```

**5. Run Migration**:
```bash
alembic upgrade head
```

**6. Add pgvector Extension**:

Create manual migration:
```bash
alembic revision -m "Add pgvector extension"
```

Edit migration file:
```python
def upgrade():
    op.execute('CREATE EXTENSION IF NOT EXISTS vector')

def downgrade():
    op.execute('DROP EXTENSION IF EXISTS vector')
```

Run:
```bash
alembic upgrade head
```

### Migration Best Practices

1. **Always review auto-generated migrations** before running
2. **Test migrations on a copy of production data**
3. **Create backups before running migrations**
4. **Version control all migration files**
5. **Never edit applied migrations** (create new ones instead)

---

## Database Initialization Script

```sql
-- init.sql - Run this to set up database from scratch

-- Create database (run as postgres superuser)
CREATE DATABASE macapy_db;

-- Connect to database
\c macapy_db

-- Install pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Create tables (in order to respect foreign keys)

CREATE TABLE meetings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(255) NOT NULL,
    start_time TIMESTAMP NOT NULL,
    end_time TIMESTAMP,
    platform VARCHAR(50),
    status VARCHAR(20) DEFAULT 'in_progress',
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE transcripts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id UUID NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    speaker VARCHAR(50) DEFAULT 'unknown',
    text TEXT NOT NULL,
    start_timestamp FLOAT NOT NULL,
    end_timestamp FLOAT NOT NULL,
    confidence FLOAT,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE summaries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id UUID NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    summary_text TEXT NOT NULL,
    time_range_start FLOAT NOT NULL,
    time_range_end FLOAT NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE context_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id UUID REFERENCES meetings(id) ON DELETE SET NULL,
    filename VARCHAR(255) NOT NULL,
    file_type VARCHAR(20) NOT NULL,
    file_path TEXT NOT NULL,
    extracted_text TEXT,
    upload_timestamp TIMESTAMP DEFAULT NOW(),
    is_active BOOLEAN DEFAULT TRUE
);

CREATE TABLE context_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID NOT NULL REFERENCES context_documents(id) ON DELETE CASCADE,
    chunk_text TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    embedding VECTOR(384),
    metadata JSONB
);

CREATE TABLE response_suggestions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id UUID NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    question_text TEXT,
    suggestion_text TEXT NOT NULL,
    context_used JSONB,
    timestamp FLOAT NOT NULL,
    was_used BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Create indexes
CREATE INDEX idx_meetings_status ON meetings(status);
CREATE INDEX idx_meetings_start_time ON meetings(start_time DESC);
CREATE INDEX idx_transcripts_meeting ON transcripts(meeting_id, start_timestamp);
CREATE INDEX idx_summaries_meeting ON summaries(meeting_id, created_at DESC);
CREATE INDEX idx_context_documents_meeting ON context_documents(meeting_id);
CREATE INDEX idx_context_chunks_document ON context_chunks(document_id, chunk_index);
CREATE INDEX idx_context_chunks_embedding ON context_chunks
    USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX idx_response_suggestions_meeting ON response_suggestions(meeting_id, timestamp);

-- Grant permissions (adjust username as needed)
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO macapy_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO macapy_user;
```

---

## Performance Tuning

### 1. Vacuum and Analyze

```sql
-- Regular maintenance
VACUUM ANALYZE meetings;
VACUUM ANALYZE transcripts;
VACUUM ANALYZE context_chunks;
```

### 2. Connection Pooling

Use pgBouncer or SQLAlchemy connection pooling:
```python
from sqlalchemy import create_engine

engine = create_engine(
    DATABASE_URL,
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True
)
```

### 3. Query Optimization

**Explain Query Plans**:
```sql
EXPLAIN ANALYZE
SELECT * FROM transcripts WHERE meeting_id = 'uuid';
```

**Add Indexes for Slow Queries**:
```sql
-- If you frequently filter by speaker
CREATE INDEX idx_transcripts_speaker ON transcripts(speaker);
```

### 4. Partitioning (for Large Datasets)

If transcripts grow very large, consider partitioning by meeting_id or date:
```sql
-- Partition transcripts by meeting_id (advanced)
CREATE TABLE transcripts_partitioned (
    id UUID,
    meeting_id UUID,
    -- ... other columns
) PARTITION BY HASH (meeting_id);
```

---

## Backup and Recovery

### 1. Backup Database

```bash
# Full backup
pg_dump -U macapy_user -h localhost macapy_db > macapy_backup.sql

# Backup specific table
pg_dump -U macapy_user -h localhost -t meetings macapy_db > meetings_backup.sql
```

### 2. Restore Database

```bash
# Restore from backup
psql -U macapy_user -h localhost -d macapy_db < macapy_backup.sql
```

### 3. Automated Backups

```bash
# Add to crontab for daily backups
0 2 * * * pg_dump -U macapy_user macapy_db > /backups/macapy_$(date +\%Y\%m\%d).sql
```

---

## Summary

**Total Tables**: 6
- meetings
- transcripts
- summaries
- context_documents
- context_chunks
- response_suggestions

**Total Indexes**: 10+
**Extensions Required**: pgvector

**Key Features**:
- ✅ UUID primary keys for distributed systems
- ✅ CASCADE delete for child records
- ✅ Vector embeddings with pgvector
- ✅ JSONB for flexible metadata
- ✅ Timestamp tracking
- ✅ Optimized indexes for common queries

---

**Document Version**: 1.0
**Last Updated**: 2025-10-09
