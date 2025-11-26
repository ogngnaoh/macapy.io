# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**macapy.io** is an AI-powered meeting assistant providing real-time transcription, rolling summaries, and context-aware response suggestions. It captures audio from any meeting platform (Zoom, Teams, Meet, Discord) via virtual audio device routing.

## Build & Run Commands

### Backend Setup
```bash
# From project root
python -m venv .venv
.venv\Scripts\activate  # Windows
source .venv/bin/activate  # macOS/Linux
pip install -r backend/requirements.txt
```

### Database Setup
```bash
# Create database with pgvector
createdb macapy_db
psql macapy_db -c "CREATE EXTENSION vector;"

# Run migrations
cd backend && alembic upgrade head
```

### Running the Backend
```bash
# From project root (with venv activated)
uvicorn backend.app.main:app --reload --port 8000

# Or from backend directory
cd backend && uvicorn app.main:app --reload
```

API docs available at: http://localhost:8000/docs

### Running Tests
```bash
# All tests
pytest backend/tests/ -v

# Unit tests only (fast, no external deps)
pytest backend/tests/unit/ -v -m unit

# Integration tests (requires OpenAI API key)
pytest backend/tests/integration/ -v -m integration

# Single test file
pytest backend/tests/unit/test_meeting_service.py -v

# With coverage
pytest backend/tests/ --cov=backend/app --cov-report=html
```

### Database Migrations
```bash
cd backend

# Create migration from model changes
alembic revision --autogenerate -m "Description"

# Apply migrations
alembic upgrade head

# Rollback one migration
alembic downgrade -1
```

### Docker Compose
```bash
docker-compose up -d        # Start services
docker-compose logs -f      # View logs
docker-compose down         # Stop services
```

## Architecture

### Project Structure
```
backend/
├── app/
│   ├── main.py           # FastAPI entry point
│   ├── config.py         # Pydantic Settings (loads .env)
│   ├── api/              # REST endpoints + WebSocket
│   ├── db/               # Database session factory
│   ├── models/           # SQLAlchemy ORM models
│   ├── schemas/          # Pydantic validation schemas
│   └── services/         # Business logic layer
├── tests/
│   ├── unit/             # Fast tests, no external deps
│   └── integration/      # Tests requiring OpenAI/DB
└── alembic/              # Database migrations
```

### Core Services

| Service | Purpose |
|---------|---------|
| `audio_capture.py` | Captures system audio via virtual devices (pyaudiowpatch/sounddevice) |
| `transcription.py` | OpenAI Whisper API integration with silence detection |
| `document_service.py` | PDF/DOCX/TXT parsing and text chunking |
| `embedding_service.py` | OpenAI embeddings for semantic search |
| `context_service.py` | Document upload pipeline + vector retrieval |
| `llm_service.py` | GPT-4 for summaries and response suggestions |
| `meeting_service.py` | Orchestrates entire meeting processing pipeline |
| `websocket_manager.py` | Room-based real-time broadcasting |

### Processing Pipelines

**Audio Pipeline**:
```
System Audio → Virtual Device → Capture (1s chunks) →
Whisper API → Transcript → DB + WebSocket Broadcast
```

**Document Pipeline**:
```
Upload → Parse (PDF/DOCX) → Chunk (1000 chars, 200 overlap) →
Embed → Store in pgvector → Semantic Search
```

**AI Pipeline**:
```
Transcript → Question Detection → Context Retrieval →
GPT-4 Suggestions → DB + WebSocket Broadcast
```

### Database Models

- **meetings**: Meeting metadata with status (PENDING → IN_PROGRESS → COMPLETED)
- **transcripts**: Transcript segments with timestamps
- **context_documents**: Uploaded documents
- **context_chunks**: Document chunks with Vector(1536) embeddings
- **summaries**: Rolling summaries (every 60s)
- **suggestions**: AI-generated response options

### API Endpoints

| Prefix | Purpose |
|--------|---------|
| `/api/meetings` | Meeting CRUD |
| `/api/transcripts` | Transcript CRUD |
| `/api/audio` | Audio device management, capture control |
| `/api/documents` | Document upload/retrieval |
| `/api/ws/meeting/{id}` | WebSocket for real-time updates |

## Key Patterns

### Async/Await
All database and I/O operations use async patterns. FastAPI is async-first.

### Dependency Injection
```python
from app.db.session import get_db
db: AsyncSession = Depends(get_db)
```

### Model/Schema Separation
- **Models** (`app/models/`): SQLAlchemy ORM for database
- **Schemas** (`app/schemas/`): Pydantic for API validation

### Vector Search
Uses pgvector cosine distance operator:
```python
query.order_by(ContextChunk.embedding.cosine_distance(query_vector))
```

## Configuration

Copy `.env.example` to `.env` and configure:

| Variable | Required | Description |
|----------|----------|-------------|
| `DATABASE_URL` | Yes | PostgreSQL connection (asyncpg) |
| `OPENAI_API_KEY` | Yes | OpenAI API key |
| `SECRET_KEY` | Yes | Application secret |
| `DEBUG` | No | Debug mode (default: true) |

## Notes for Claude

- **Async everywhere**: Use `async/await` for all I/O operations
- **No raw SQL**: Use SQLAlchemy ORM for all database queries
- **Service layer**: Business logic goes in `services/`, not API endpoints
- **Test markers**: Use `@pytest.mark.unit` or `@pytest.mark.integration`
- **Frontend**: Not yet implemented (React + TypeScript planned)
