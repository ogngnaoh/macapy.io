# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**macapy.io** is an AI-powered desktop meeting assistant providing real-time transcription, intelligent summarization, and contextually-aware response suggestions during online meetings. The application leverages GPT-5 nano for reasoning and OpenAI Whisper for transcription, delivered through a compact Electron overlay.

### Target Users
- **Interview candidates**: Real-time coaching and response suggestions
- **Knowledge workers**: Meeting summaries and action item tracking
- **Students**: Lecture transcription and study aids

### Core Capabilities
1. Real-time audio capture from any meeting platform via native platform APIs
2. Live transcription with < 5s latency
3. Rolling summaries every 30 seconds (configurable)
4. Automatic question detection with AI-generated response suggestions
5. User query input for on-demand AI assistance with SSE streaming
6. Searchable meeting history with document management

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

### Frontend Development
```bash
cd frontend
npm install          # Install dependencies
npm run dev          # Dev server on http://localhost:5173
npm run build        # Production build
npm run test         # Vitest unit tests
npm run test:e2e     # Playwright E2E tests
```

## Windows Development Notes

### Service Startup (Recommended Order)
1. Start PostgreSQL (via Services.msc or docker-compose)
2. Activate virtual environment:
   - CMD: `.venv\Scripts\activate`
   - PowerShell: `.\.venv\Scripts\Activate.ps1`
3. Start backend (from `backend/` directory):
   ```bash
   python -m uvicorn app.main:app --reload --port 8000
   ```
4. Start frontend:
   ```bash
   cd frontend && npm run dev
   ```

### Common Windows Issues

| Issue | Solution |
|-------|----------|
| Port 8000 in use | `netstat -ano \| findstr :8000` then `taskkill /PID <pid> /F` |
| Port 5173 in use | `netstat -ano \| findstr :5173` then `taskkill /PID <pid> /F` |
| PostgreSQL not running | Check Windows Services (services.msc) |
| Module not found | Run uvicorn from `backend/` directory, not project root |
| npm permission errors | Run terminal as Administrator |

### Environment Variables
Windows uses `.env` file at project root. Ensure:
- No spaces around `=` signs
- No quotes around values unless they contain spaces
- Line endings can be CRLF or LF (both work)

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

| Service | Purpose | Status |
|---------|---------|--------|
| `audio_capture.py` | Captures system audio via native APIs (pyaudiowpatch/ScreenCaptureKit) | ✅ |
| `transcription.py` | OpenAI Whisper API integration with silence detection | ✅ |
| `document_service.py` | PDF/DOCX/TXT parsing and text chunking | ✅ |
| `embedding_service.py` | OpenAI embeddings for semantic search | ✅ |
| `context_service.py` | Document upload pipeline + vector retrieval | ✅ |
| `llm_service.py` | GPT-4 for summaries and response suggestions | ✅ |
| `meeting_service.py` | Orchestrates entire meeting processing pipeline | ✅ |
| `websocket_manager.py` | Room-based real-time broadcasting | ✅ |
| `token_service.py` | Token counting with tiktoken, context window management | ✅ |
| `query_service.py` | User queries with streaming, recaps, manual summaries | ✅ |

### Processing Pipelines

**Audio Pipeline**:
```
System Audio → ScreenCaptureKit (macOS) / WASAPI (Windows) → Capture (1s chunks) →
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
- **transcripts**: Transcript segments with timestamps and speaker identification
- **context_documents**: Uploaded documents (PDF, DOCX, TXT)
- **context_chunks**: Document chunks with Vector(1536) embeddings
- **summaries**: Rolling summaries (every 30s configurable)
- **suggestions**: AI-generated response options
- **token_usage**: Token consumption tracking per meeting/source
- **user_settings**: User preferences (summary interval, always-on-top, window bounds)

### API Endpoints

| Prefix | Purpose |
|--------|---------|
| `/api/meetings` | Meeting CRUD, pause/resume, status |
| `/api/transcripts` | Transcript CRUD |
| `/api/audio` | Audio device management, capture control |
| `/api/documents` | Document upload/retrieval |
| `/api/ai` | AI queries (SSE streaming), recaps, summaries, token usage |
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

## Frontend Architecture (Implemented)

### Technology Stack
| Layer | Technology | Status |
|-------|------------|--------|
| Framework | React 18 + TypeScript | ✅ |
| Desktop Shell | Electron 28+ | ✅ |
| Build Tool | Vite | ✅ |
| State Management | Zustand | ✅ |
| Styling | TailwindCSS + tailwind-merge | ✅ |
| Components | Custom + Radix UI primitives | ✅ |
| Virtualization | @tanstack/react-virtual | ✅ |

### Frontend Project Structure
```
frontend/
├── electron/
│   ├── main/              # Main process (window, IPC, storage)
│   └── preload/           # Context bridge definitions
├── src/
│   ├── components/
│   │   ├── layout/        # TitleBar, Sidebar
│   │   ├── meeting/       # MeetingView, TranscriptPanel, SummaryPanel, QueryInput, etc.
│   │   ├── history/       # HistoryView, MeetingList, MeetingDetail, SearchBar
│   │   └── common/        # Button, Input, Badge, Toast, Dialog, Spinner, etc.
│   ├── hooks/             # useKeyboardShortcuts
│   ├── lib/               # utils.ts (cn, formatters, debounce)
│   ├── store/             # Zustand slices (meeting, transcript, history, ui)
│   ├── services/          # API client (with SSE streaming), WebSocket manager
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

### Frontend Components

#### Layout Components
| Component | Purpose | Status |
|-----------|---------|--------|
| `TitleBar` | Custom draggable title bar with window controls | ✅ |
| `Sidebar` | Navigation sidebar with meeting/history tabs | ✅ |
| `App` | Root component with ToastProvider and routing | ✅ |

#### Common Components
| Component | Purpose | Status |
|-----------|---------|--------|
| `Button` | Terminal-styled button with variants (primary, ghost, danger) | ✅ |
| `Input` | Monospace input with terminal aesthetic | ✅ |
| `Badge` | Status badges (success, warning, error, info) | ✅ |
| `Spinner` | Loading indicator | ✅ |
| `ProgressBar` | Visual progress indicator | ✅ |
| `Toast` | Notification toasts with ToastProvider | ✅ |
| `Dialog` | Modal dialogs using Radix UI | ✅ |
| `DropZone` | Drag-and-drop file upload area | ✅ |
| `EmptyState` | Empty state placeholder with icon | ✅ |

#### Meeting Components
| Component | Purpose | Status |
|-----------|---------|--------|
| `MeetingView` | Main meeting interface with split layout | ✅ |
| `MeetingControls` | Start/stop/pause meeting, duration timer | ✅ |
| `TranscriptPanel` | Real-time dual-column transcript (system/user) | ✅ |
| `SummaryPanel` | Rolling summaries with manual trigger | ✅ |
| `QueryInput` | Terminal-style AI query with SSE streaming | ✅ |
| `SuggestionNotification` | Floating auto-generated response suggestions | ✅ |
| `TokenUsageIndicator` | Context window usage progress bar | ✅ |
| `DocumentPanel` | Document upload and management panel | ✅ |
| `RecapButton` | 30-second recap with modal display | ✅ |

#### History Components
| Component | Purpose | Status |
|-----------|---------|--------|
| `HistoryView` | Meeting history with search and detail view | ✅ |
| `MeetingList` | Virtualized list of past meetings | ✅ |
| `MeetingCard` | Meeting summary card with delete option | ✅ |
| `MeetingDetail` | Full meeting detail with transcript/summaries tabs | ✅ |
| `SearchBar` | Search input with result count | ✅ |

### Keyboard Shortcuts (Implemented)
| Action | Windows | macOS | Status |
|--------|---------|-------|--------|
| Start Meeting | Ctrl+Shift+M | Cmd+Shift+M | ✅ |
| End Meeting | Ctrl+Shift+E | Cmd+Shift+E | ✅ |
| Pause/Resume | Ctrl+Shift+P | Cmd+Shift+P | ✅ |
| Focus Query | Ctrl+K | Cmd+K | ✅ |
| 30s Recap | Ctrl+Shift+R | Cmd+Shift+R | ✅ |
| Toggle History | Ctrl+H | Cmd+H | ✅ |
| Toggle Always on Top | Ctrl+Shift+T | Cmd+Shift+T | ✅ |
| Dismiss Suggestion | Escape | Escape | ✅ |

## API Contracts

### WebSocket Events (Server → Client)
```json
{"type": "transcript_update", "data": {"id": "...", "text": "...", "timestamp": 45.5}}
{"type": "summary_update", "data": {"id": 1, "content": "- Key point\n- Decision made"}}
{"type": "suggestion_new", "data": {"question": "...", "suggestions": ["...", "..."]}}
{"type": "token_usage", "data": {"current_tokens": 45230, "max_tokens": 272000}}
{"type": "error", "data": {"code": "...", "message": "...", "recoverable": true}}
```

### AI API Endpoints (Implemented)
| Endpoint | Method | Purpose | Status |
|----------|--------|---------|--------|
| `/api/ai/query` | POST | Stream AI response via SSE | ✅ |
| `/api/ai/recap` | POST | Get 30-second recap | ✅ |
| `/api/meetings/{id}/summaries/generate` | POST | Trigger manual summary | ✅ |
| `/api/meetings/{id}/tokens` | GET | Get current token usage | ✅ |

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

### Recently Completed Services
| Service | Purpose | Status |
|---------|---------|--------|
| `token_service.py` | Token counting with tiktoken, context window management | ✅ |
| `query_service.py` | User queries with streaming, recaps, manual summaries | ✅ |

### Database Migrations (Completed)
- `token_usage` table: Track token usage per meeting/source ✅
- `user_settings` table: Store summary interval, always-on-top, window bounds ✅
- Migration file: `5a7b8c9d0e1f_add_token_usage_and_user_settings.py`

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

### File Placement Rules (IMPORTANT)

**NEVER put test files or scripts in the project root.** All files must be placed in their proper directories:

| File Type | Correct Location |
|-----------|------------------|
| Backend unit tests | `backend/tests/unit/` |
| Backend integration tests | `backend/tests/integration/` |
| Backend e2e tests | `backend/tests/e2e/` |
| Manual test/debug scripts | `backend/scripts/` |
| Frontend tests | `frontend/src/**/*.test.tsx` |
| Shared/workspace scripts | `scripts/` |

**Test file requirements:**
- All pytest test files must define tests inside functions (NOT at module level)
- Never run code at import time in test files - use fixtures instead
- Tests that require external services (API, browser) should use `pytest.mark.skipif` decorators
- Manual scripts should have `if __name__ == "__main__":` guard

## Implementation Status Summary

### Backend (~95% Complete)
| Feature | Status |
|---------|--------|
| Core Services (audio, transcription, LLM) | ✅ |
| Document Processing (upload, chunk, embed) | ✅ |
| Meeting Management (CRUD, pause/resume) | ✅ |
| Token Service | ✅ |
| Query Service (streaming) | ✅ |
| WebSocket Broadcasting | ✅ |
| Database Models & Migrations | ✅ |
| API Endpoints | ✅ |

### Frontend (~90% Complete)
| Feature | Status |
|---------|--------|
| Common UI Components | ✅ |
| Meeting View with Split Layout | ✅ |
| Transcript Panel (dual-column) | ✅ |
| Summary Panel with Manual Trigger | ✅ |
| Query Input with SSE Streaming | ✅ |
| Suggestion Notifications | ✅ |
| Token Usage Indicator | ✅ |
| Document Upload Panel | ✅ |
| 30-second Recap | ✅ |
| History View with Search | ✅ |
| Keyboard Shortcuts | ✅ |
| Electron IPC Integration | ⏳ Partial |

### Remaining Tasks
- Run backend tests to verify services
- Install frontend dependencies and verify build
- Complete Electron IPC handlers for window controls
- End-to-end integration testing

## Troubleshooting

### LLM Service Issues

**Blank AI Responses / Empty Summaries**

If the AI features return blank responses:

1. **Check model ID** in `backend/app/config.py` (line 48):
   ```python
   # Correct:
   GPT_MODEL: str = "gpt-5-nano-2025-08-07"

   # Wrong (missing date suffix):
   GPT_MODEL: str = "gpt-5-nano"
   ```

2. **Run the diagnostic script**:
   ```bash
   source .venv/bin/activate
   python backend/scripts/test_llm_responses_api.py
   ```
   This verifies: API key validity, model ID, response structure, streaming events.

3. **Enable debug logging**:
   ```bash
   uvicorn backend.app.main:app --reload --log-level debug
   ```
   Look for `llm_service` and `query_service` log messages.

4. **Check for transcripts**: Summary generation requires transcripts in the database.
   ```bash
   curl http://localhost:8000/api/transcripts?meeting_id={your-meeting-id}
   ```

**OpenAI Responses API Format**

The LLM service uses OpenAI's Responses API (not Chat Completions):

- **Non-streaming response structure**:
  ```python
  response.output[].type == "message" -> .content[].type == "output_text" -> .text
  ```

- **Streaming event type**: `response.output_text.delta` with `.delta` containing text chunk

- **JSON output**: Use `text={"format": {"type": "json_object"}}` parameter

**Common Errors**

| Error | Cause | Solution |
|-------|-------|----------|
| `InvalidRequestError` | Wrong model ID | Use `gpt-5-nano-2025-08-07` |
| `RateLimitError` | API quota exceeded | Wait or check billing |
| Empty response | Model returned nothing | Check prompt/context |
| `APIError` | OpenAI service issue | Retry after delay |

### WebSocket Connection Issues

If real-time updates (transcripts, summaries) aren't appearing:

1. Check browser console for WebSocket errors
2. Verify backend is running on port 8000
3. Check CORS settings in `backend/app/config.py`

### Database Issues

If meetings/transcripts aren't persisting:

```bash
# Check database connection
psql macapy_db -c "SELECT COUNT(*) FROM meetings;"

# Run migrations if tables are missing
cd backend && alembic upgrade head
```
