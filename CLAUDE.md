# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**macapy.io** is an AI-powered desktop meeting assistant providing real-time transcription, intelligent summarization, and contextually-aware response suggestions during online meetings. The application leverages GPT-5 nano for reasoning and OpenAI Whisper for transcription, delivered through a compact Electron overlay.

### Target Users
- **Interview candidates**: Real-time coaching and response suggestions
- **Knowledge workers**: Meeting summaries and action item tracking
- **Students**: Lecture transcription and study aids

### Core Capabilities
1. Real-time audio capture from any meeting platform via virtual audio devices
2. Live transcription with < 5s latency
3. Rolling summaries every 60 seconds
4. Automatic question detection with AI-generated response suggestions
5. User query input for on-demand AI assistance
6. Searchable meeting history

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

## Frontend Architecture (Planned)

### Technology Stack
| Layer | Technology |
|-------|------------|
| Framework | React 18 + TypeScript |
| Desktop Shell | Electron 28+ |
| Build Tool | Vite |
| State Management | Zustand |
| Styling | TailwindCSS |
| Components | Custom + Radix UI primitives |

### Frontend Project Structure (Planned)
```
frontend/
├── electron/
│   ├── main/              # Main process (window, IPC, storage)
│   └── preload/           # Context bridge definitions
├── src/
│   ├── components/
│   │   ├── layout/        # TitleBar, MainLayout
│   │   ├── meeting/       # MeetingControls, TranscriptPanel, SummaryPanel
│   │   ├── history/       # MeetingList, MeetingDetail
│   │   └── common/        # Button, Input, Modal, Toast
│   ├── hooks/             # useWebSocket, useMeeting, useKeyboard
│   ├── store/             # Zustand slices (meeting, transcript, history, ui)
│   ├── services/          # API client, WebSocket manager
│   └── types/             # TypeScript interfaces
└── package.json
```

### Design System
- **Primary color**: Black (#000000)
- **Accent color**: Light blue (#00D4FF / #4FC3F7)
- **Background**: Dark (#0D0D0D)
- **Text**: Light (#E0E0E0)
- **Typography**: JetBrains Mono or Fira Code (monospace)
- **Style**: CLI-like aesthetic, dark mode only, compact overlay design

### Key Frontend Components
| Component | Purpose |
|-----------|---------|
| `TitleBar` | Custom draggable title bar with window controls |
| `MeetingControls` | Start/stop meeting, status display, duration timer |
| `TranscriptPanel` | Real-time scrolling transcript with virtualization |
| `SummaryPanel` | Rolling summaries with "Summarize Now" button |
| `QueryInput` | User questions with AI response display |
| `SuggestionNotification` | Auto-generated response suggestions |
| `TokenUsageIndicator` | Context window usage visualization |

### Keyboard Shortcuts
| Action | Windows | macOS |
|--------|---------|-------|
| Start Meeting | Ctrl+Shift+M | Cmd+Shift+M |
| End Meeting | Ctrl+Shift+E | Cmd+Shift+E |
| Focus Query | Ctrl+K | Cmd+K |
| 30s Recap | Ctrl+Shift+R | Cmd+Shift+R |
| Toggle History | Ctrl+H | Cmd+H |
| Toggle Always on Top | Ctrl+Shift+T | Cmd+Shift+T |

## API Contracts

### WebSocket Events (Server → Client)
```json
{"type": "transcript_update", "data": {"id": "...", "text": "...", "timestamp": 45.5}}
{"type": "summary_update", "data": {"id": 1, "content": "- Key point\n- Decision made"}}
{"type": "suggestion_new", "data": {"question": "...", "suggestions": ["...", "..."]}}
{"type": "token_usage", "data": {"current_tokens": 45230, "max_tokens": 272000}}
{"type": "error", "data": {"code": "...", "message": "...", "recoverable": true}}
```

### New API Endpoints (To Implement)
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/ai/query` | POST | Stream AI response to user question |
| `/api/ai/recap` | POST | Get 30-second recap |
| `/api/meetings/{id}/summaries/generate` | POST | Trigger manual summary |

## Backend Updates (Completed)

### Audio Capture Changes
- `AudioChunk` now includes `source` field: `"system"` (loopback) or `"user"` (mic)
- `_capture_with_pyaudio_dual` yields **separate chunks** instead of mixing
- Supports two-column transcript display in frontend

### Meeting Service Changes
- Speaker field populated from `chunk.source` (not hardcoded)
- Added `pause_meeting()` and `resume_meeting()` methods for privacy
- Added `get_status()` method for frontend status queries
- Summarization interval now uses `settings.SUMMARY_INTERVAL` (30s)

### New API Endpoints
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/meetings/{id}/pause` | POST | Pause audio capture |
| `/api/meetings/{id}/resume` | POST | Resume audio capture |
| `/api/meetings/{id}/status` | GET | Get capture status |

### WebSocket Events (New)
- `meeting_status`: `{"status": "paused"/"recording", "meeting_id": "..."}` - Broadcast on pause/resume

### Still TODO
| Service | Purpose |
|---------|---------|
| `token_service.py` | Token counting and context window management |
| `query_service.py` | Handle user queries with transcript/document context |

### Database Migrations Needed
- `token_usage` table: Track token usage per meeting/source
- `user_settings` table: Store summary interval, always-on-top, window bounds

## Performance Requirements

| Metric | Target |
|--------|--------|
| Transcription Latency | < 5 seconds |
| Summary Generation | < 10 seconds |
| Suggestion Latency | < 8 seconds |
| UI Response Time | < 100ms |
| App Startup | < 3 seconds |
| Memory (Active) | < 500MB |

## Documentation Reference

Detailed specifications available in `/docs`:
- `PRD.md` - Product requirements and feature specs
- `FSD.md` - Functional specs, user flows, component interfaces
- `ARCHITECTURE.md` - System architecture and implementation details
- `CLARIFYING_QUESTIONS.md` - Open decisions requiring user input

## Notes for Claude

- **Async everywhere**: Use `async/await` for all I/O operations
- **No raw SQL**: Use SQLAlchemy ORM for all database queries
- **Service layer**: Business logic goes in `services/`, not API endpoints
- **Test markers**: Use `@pytest.mark.unit` or `@pytest.mark.integration`
- **Frontend patterns**: Use Zustand for state, React hooks for logic, Radix UI for accessibility
- **IPC security**: Use contextBridge, no nodeIntegration in renderer
- **Streaming responses**: Use async generators for LLM streaming
