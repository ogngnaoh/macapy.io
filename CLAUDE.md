# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**macapy.io** is an AI-powered personal meeting assistant that provides real-time transcription, intelligent summarization, and contextually-aware response suggestions during online meetings.

**Core Capabilities**:
- Real-time audio capture and transcription (using OpenAI Whisper)
- Platform-agnostic support for all major meeting platforms (Zoom, Google Meet, Microsoft Teams, Discord)
- Rolling conversation summaries (every 60s using GPT-4)
- Context-aware response suggestions based on uploaded documents (resume, project docs)
- Document processing with semantic search (PDF/DOCX parsing + embeddings)
- Interview optimization (suggests responses based on user's background)

**Architecture Pattern**: Event-driven microservices with real-time processing pipeline

**Platform Support**: Uses virtual audio device routing (VB-CABLE on Windows) to capture audio from any meeting platform without platform-specific integrations.

## Technology Stack

### Backend
- **Framework**: FastAPI (async Python web framework)
- **Language**: Python 3.11+
- **Database**: PostgreSQL 15+ with pgvector extension
- **ORM**: SQLAlchemy 2.0 (async)
- **Validation**: Pydantic 2.0

### Frontend
- **Framework**: React 18 with TypeScript 5+
- **Build Tool**: Vite
- **State Management**: Zustand
- **Styling**: TailwindCSS + shadcn/ui components
- **Real-time**: Socket.IO client (or native WebSockets)

### AI/ML Services
- **Transcription**: OpenAI Whisper API (alternative: faster-whisper for local)
- **LLM**: OpenAI GPT-4-turbo for summarization and response suggestions
- **Embeddings**: OpenAI Embeddings API or sentence-transformers (local)
- **Vector Search**: pgvector extension in PostgreSQL

### Audio Processing
- **Capture**: pyaudiowpatch (Windows), sounddevice (cross-platform)
- **Processing**: pydub, numpy
- **Virtual Audio**: VB-CABLE (Windows), BlackHole (macOS)

### Document Processing
- **PDF**: PyMuPDF (fitz)
- **DOCX**: python-docx
- **Chunking**: Custom text chunking with overlap (500-800 chars)

## Project Structure

```
agentic_assistant/
├── backend/
│   ├── app/
│   │   ├── api/              # REST API endpoints
│   │   ├── models/           # SQLAlchemy models
│   │   ├── services/         # Business logic
│   │   │   ├── audio_capture.py
│   │   │   ├── transcription.py
│   │   │   ├── document_service.py
│   │   │   ├── llm_service.py
│   │   │   └── meeting_service.py
│   │   └── main.py           # FastAPI app entry point
│   ├── tests/
│   ├── alembic/              # Database migrations
│   └── requirements.txt
├── frontend/
│   ├── src/
│   │   ├── components/       # React components
│   │   ├── hooks/            # Custom hooks (useWebSocket, etc.)
│   │   ├── store/            # Zustand state management
│   │   └── App.tsx
│   ├── public/
│   └── package.json
├── reference/
│   ├── ARCHITECTURE.md       # System architecture details
│   ├── ROADMAP.md           # Development stages and tasks
│   ├── DATABASE_SCHEMA.md   # PostgreSQL schema reference
│   └── CLARIFYING_QUESTIONS.md
├── TECHNOLOGY_STACK.md      # Comprehensive tech stack guide
├── .env.example             # Environment variables template
└── docker-compose.yml       # Multi-container orchestration
```

## Database Schema

**Core Tables**:
1. **meetings**: Meeting metadata (title, start_time, end_time, platform, status)
2. **transcripts**: Transcript segments with timestamps and speaker info
3. **summaries**: Rolling summaries for time ranges within meetings
4. **context_documents**: Uploaded documents (PDF, DOCX, TXT, MD)
5. **context_chunks**: Document chunks with vector embeddings for semantic search
6. **response_suggestions**: Logged AI-generated suggestions with usage tracking

**Key Features**:
- UUID primary keys throughout
- CASCADE deletes for child records
- VECTOR(384) columns for embeddings using pgvector
- JSONB for flexible metadata storage
- Optimized indexes for vector similarity search (IVFFlat)

See `reference/DATABASE_SCHEMA.md` for complete schema and example queries.

## Development Workflow

### Initial Setup

**Prerequisites**:
- Python 3.11+
- Node.js 18+
- PostgreSQL 15+ with pgvector extension
- Virtual audio device (VB-CABLE for Windows, BlackHole for macOS)

**Backend Setup**:
```bash
cd backend
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

**Database Setup**:
```bash
# Create database and install pgvector
createdb macapy_db
psql macapy_db -c "CREATE EXTENSION vector;"

# Run migrations
alembic upgrade head
```

**Frontend Setup**:
```bash
cd frontend
npm install
```

**Environment Variables**:
Create `.env` file in project root:
```
DATABASE_URL=postgresql://user:pass@localhost:5432/macapy_db
OPENAI_API_KEY=sk-...
SECRET_KEY=<random-secret>
DEBUG=true
```

### Running the Application

**Backend**:
```bash
cd backend
uvicorn app.main:app --reload --port 8000
```

**Frontend**:
```bash
cd frontend
npm run dev  # Runs on port 3000
```

**Access**:
- Frontend: http://localhost:3000
- Backend API docs: http://localhost:8000/docs

### Database Migrations

**Create new migration**:
```bash
cd backend
alembic revision --autogenerate -m "Description of changes"
```

**Apply migrations**:
```bash
alembic upgrade head
```

**Rollback migration**:
```bash
alembic downgrade -1
```

## Architecture Patterns

### Audio Processing Pipeline

```
System Audio → Virtual Device → Audio Capture (512ms-1s chunks) →
Preprocess (16kHz mono) → Whisper API → Transcript Text →
Database Storage + WebSocket Broadcast
```

**Key Service**: `backend/app/services/audio_capture.py`
- Async audio capture with buffering
- Error handling for device failures
- Audio level monitoring for UI feedback

### Document Processing Pipeline

```
File Upload → Validate (type, size) → Parse (PDF/DOCX) →
Chunk Text (500-800 chars with overlap) → Generate Embeddings →
Store in PostgreSQL (context_chunks with vector embeddings) →
Semantic Search (cosine similarity via pgvector)
```

**Key Service**: `backend/app/services/document_service.py`
- Text chunking with sentence boundary awareness
- Metadata extraction (page numbers, sections)
- Hybrid search: vector similarity + keyword matching

### AI Processing Flow

```
Transcript → Sliding Window (last 5-10 min) →
Question Detection → Context Retrieval (vector search) →
LLM (GPT-4) with context → Response Suggestions →
Database + WebSocket Broadcast
```

**Summarization** (periodic):
```
Transcript → Rolling Window (60s intervals) →
LLM (GPT-4) → Summary → Database + WebSocket Broadcast
```

**Key Service**: `backend/app/services/llm_service.py`
- Prompt template management
- Token counting to manage context window (128k for GPT-4-turbo)
- Streaming responses for lower latency

### Real-Time Communication

**WebSocket Events** (Server → Client):
- `transcript_update`: New transcript segment
- `summary_update`: New summary generated
- `suggestion_generated`: New response suggestions
- `audio_level`: Audio capture level monitoring
- `error`: Error messages

**WebSocket Events** (Client → Server):
- `join_meeting`: Connect to meeting room
- `leave_meeting`: Disconnect
- `mark_suggestion_used`: Track suggestion usage

**Implementation**: Room-based WebSocket server with automatic reconnection

## Key Configuration

### Audio Capture
```python
AUDIO_CONFIG = {
    "sample_rate": 16000,      # 16kHz for Whisper
    "channels": 1,             # Mono
    "chunk_duration": 1.0,     # 1 second chunks
    "format": "int16",         # 16-bit PCM
}
```

### Whisper API
```python
WHISPER_CONFIG = {
    "model": "whisper-1",
    "language": "en",
    "temperature": 0.0,        # Deterministic
}
```

### GPT-4 Configuration
```python
GPT_CONFIG = {
    "model": "gpt-4-turbo",
    "temperature": 0.7,
    "max_tokens": 200,         # For summaries
}
```

### Vector Search
```python
VECTOR_SEARCH_CONFIG = {
    "embedding_dimension": 384,    # For all-MiniLM-L6-v2
    "similarity_metric": "cosine",
    "top_k": 5,                    # Return top 5 chunks
    "index_type": "ivfflat",
}
```

## Performance Targets

| Operation | Target Latency | Strategy |
|-----------|---------------|----------|
| Audio capture | Real-time | Continuous streaming |
| Transcription | 3-5s | OpenAI Whisper API |
| Summary generation | <10s | GPT-4-turbo with streaming |
| Suggestion generation | 5-8s | Parallel context retrieval + LLM |
| WebSocket delivery | <100ms | Direct broadcast |
| Database queries | <200ms | Indexed queries + connection pooling |

## Common Tasks

### Add a New API Endpoint

1. Define Pydantic models in `backend/app/models/`
2. Create endpoint in `backend/app/api/`
3. Implement business logic in `backend/app/services/`
4. Update OpenAPI docs (automatic via FastAPI)

### Add a New UI Component

1. Create component in `frontend/src/components/`
2. Add TypeScript interfaces for props
3. Style with TailwindCSS utility classes
4. Connect to Zustand store if needed
5. Test real-time updates via WebSocket

### Modify Database Schema

1. Update SQLAlchemy models in `backend/app/models/`
2. Generate migration: `alembic revision --autogenerate -m "description"`
3. Review auto-generated migration in `alembic/versions/`
4. Apply migration: `alembic upgrade head`
5. Update `reference/DATABASE_SCHEMA.md` documentation

### Add Document Parser for New Format

1. Install required library (e.g., `openpyxl` for Excel)
2. Add parser function in `backend/app/services/document_service.py`
3. Update file type validation in upload endpoint
4. Add test with sample file

## Testing

### Backend Tests
```bash
cd backend
pytest tests/ -v
```

### Integration Tests
Test full audio pipeline with sample audio:
```bash
pytest tests/integration/test_audio_pipeline.py
```

### Frontend Tests
```bash
cd frontend
npm test
```

## Security Considerations

- **API Keys**: Never commit API keys; use `.env` files (gitignored)
- **Input Validation**: All API inputs validated via Pydantic
- **File Uploads**: 10MB size limit, type validation (PDF/DOCX/TXT/MD only)
- **SQL Injection**: Protected via SQLAlchemy ORM (parameterized queries)
- **CORS**: Configure allowed origins in FastAPI middleware
- **Audio Data**: Stored locally (consider encryption for sensitive recordings)

## Deployment

### Docker Compose (Recommended)

```bash
# Create .env file with API keys
cp .env.example .env

# Start all services
docker-compose up -d

# View logs
docker-compose logs -f

# Stop services
docker-compose down
```

### Manual Deployment

1. Set up PostgreSQL with pgvector
2. Run database migrations
3. Start backend with uvicorn
4. Build frontend: `npm run build`
5. Serve frontend build with nginx or similar

## Development Stages

The project follows a 7-stage development roadmap (see `reference/ROADMAP.md`):

1. **Foundation & Environment**: Project structure, dependencies, database setup
2. **Audio Pipeline**: Audio capture → transcription → display
3. **Document Processing**: Upload → parse → chunk → embed → search
4. **AI Integration**: Summarization + response suggestions
5. **UI Development**: Complete React dashboard
6. **Integration & Testing**: End-to-end workflows, performance testing
7. **Advanced Features**: Speaker diarization, local models, exports

**Current Status**: Project is in planning phase; implementation not yet started.

## Troubleshooting

### Audio Capture Issues
- **Windows**: Ensure pyaudiowpatch installed and virtual audio device (VB-CABLE) configured
- **macOS**: Use sounddevice + BlackHole virtual audio device
- **Check device**: List available devices with `sounddevice.query_devices()`

### Database Connection Errors
- Verify PostgreSQL is running: `pg_isready`
- Check DATABASE_URL in `.env`
- Ensure pgvector extension installed: `psql -c "CREATE EXTENSION vector;"`

### OpenAI API Errors
- Verify API key in `.env`
- Check rate limits and quota
- Monitor costs (Whisper charges per second, GPT-4 per token)

### WebSocket Connection Issues
- Check CORS configuration in FastAPI
- Verify WebSocket endpoint path matches client
- Check firewall/antivirus blocking WebSocket connections

## Additional Resources

- **Architecture Details**: `reference/ARCHITECTURE.md`
- **Development Roadmap**: `reference/ROADMAP.md`
- **Database Schema**: `reference/DATABASE_SCHEMA.md`
- **Technology Stack**: `TECHNOLOGY_STACK.md`
- **Clarifying Questions**: `reference/CLARIFYING_QUESTIONS.md`

## Notes for Claude Code

- When implementing features, follow the stage order in `reference/ROADMAP.md`
- Use async/await throughout the backend (FastAPI is async-first)
- All database operations should use SQLAlchemy ORM (avoid raw SQL)
- Vector similarity search uses cosine distance operator: `<=>`
- Pydantic models for API validation, SQLAlchemy models for database
- Frontend state management with Zustand (simpler than Redux)
- WebSocket for all real-time updates (transcripts, summaries, suggestions)
- Document chunks should overlap (50-100 chars) to preserve context
- LLM prompts stored as templates (see `reference/ARCHITECTURE.md` for examples)
- Token counting required to avoid exceeding GPT-4 context window (128k tokens)
