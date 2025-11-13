# macapy.io System Architecture

**Project**: macapy.io - AI-Powered Personal Meeting Assistant
**Last Updated**: 2025-10-09

This document provides a comprehensive overview of the macapy.io system architecture, including component design, data flow, and integration patterns.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [System Components](#system-components)
3. [Data Flow Diagrams](#data-flow-diagrams)
4. [Technology Stack](#technology-stack)
5. [Component Specifications](#component-specifications)
6. [Integration Patterns](#integration-patterns)
7. [Security Architecture](#security-architecture)
8. [Performance Considerations](#performance-considerations)
9. [Deployment Architecture](#deployment-architecture)

---

## Architecture Overview

### Architecture Pattern

**Event-Driven Microservices with Real-Time Processing Pipeline**

macapy.io follows an event-driven architecture where independent services communicate asynchronously through events and messages. This design enables:
- **Scalability**: Components scale independently
- **Resilience**: Failure in one component doesn't crash the system
- **Real-time Performance**: Stream processing for low-latency updates
- **Maintainability**: Clear separation of concerns

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Frontend (React)                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐ │
│  │  Dashboard   │  │ Transcript   │  │  Response Suggestions │ │
│  │   UI         │  │   Display    │  │       Panel           │ │
│  └──────────────┘  └──────────────┘  └──────────────────────┘ │
└───────────────┬─────────────────────────────────────────────────┘
                │  HTTP REST API / WebSocket
                │
┌───────────────▼─────────────────────────────────────────────────┐
│                      API Gateway (FastAPI)                      │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  REST Endpoints  │  WebSocket Server  │  Authentication  │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────┬─────────────────┬─────────────────┬──────────────────────┘
      │                 │                 │
      │                 │                 │
┌─────▼─────┐  ┌────────▼────────┐  ┌────▼────────────┐
│  Meeting  │  │  Audio Pipeline │  │  AI Processing  │
│  Service  │  │                 │  │     Core        │
└─────┬─────┘  └────────┬────────┘  └────┬────────────┘
      │                 │                 │
      │                 │                 │
┌─────▼─────────────────▼─────────────────▼────────────┐
│              Database Layer (PostgreSQL)             │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐ │
│  │ Meetings │  │Transcripts│  │ Context Documents  │ │
│  └──────────┘  └──────────┘  └────────────────────┘ │
└──────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────┐
│              External Services                       │
│  ┌──────────────┐  ┌──────────────┐                 │
│  │  OpenAI API  │  │  Virtual     │                 │
│  │  (GPT-4,     │  │  Audio       │                 │
│  │   Whisper)   │  │  Device      │                 │
│  └──────────────┘  └──────────────┘                 │
└──────────────────────────────────────────────────────┘
```

---

## System Components

### 1. Frontend (React)

**Purpose**: User interface for interaction
**Technology**: React 18, TypeScript, TailwindCSS, Zustand
**Port**: 3000

**Sub-components**:
- **Dashboard**: Main meeting view
- **Transcript Display**: Real-time transcript rendering
- **Summary Panel**: Rolling summaries
- **Suggestion Cards**: Response suggestions
- **Document Upload**: File upload interface
- **Meeting History**: Past meetings browser

**Communication**:
- REST API for CRUD operations
- WebSocket for real-time updates

---

### 2. API Gateway (FastAPI)

**Purpose**: Entry point for all client requests
**Technology**: FastAPI, Python 3.11+
**Port**: 8000

**Responsibilities**:
- Route HTTP requests to appropriate services
- Manage WebSocket connections
- Handle authentication (if implemented)
- Request validation (Pydantic)
- API documentation (automatic via FastAPI)

**Endpoints**:
```
REST API:
  POST   /api/meetings
  GET    /api/meetings
  GET    /api/meetings/{id}
  PATCH  /api/meetings/{id}
  DELETE /api/meetings/{id}
  POST   /api/meetings/{id}/documents
  GET    /api/meetings/{id}/documents
  DELETE /api/documents/{id}

WebSocket:
  /ws/meeting/{meeting_id}
```

---

### 3. Meeting Service

**Purpose**: Manage meeting lifecycle and state

**Responsibilities**:
- Create/update/delete meetings
- Track meeting status (in_progress, completed)
- Coordinate between audio, transcription, and AI services
- Persist meeting metadata

**Key Functions**:
```python
async def create_meeting(title: str, platform: str) -> Meeting
async def start_meeting(meeting_id: str) -> None
async def stop_meeting(meeting_id: str) -> None
async def get_meeting(meeting_id: str) -> Meeting
async def list_meetings() -> list[Meeting]
```

---

### 4. Audio Pipeline

**Purpose**: Capture, process, and transcribe audio

**Sub-components**:

#### 4.1 Audio Capture Module
- **Technology**: pyaudiowpatch (Windows primary), sounddevice (cross-platform)
- **Function**: Capture system audio from virtual audio device
- **Platform Support**: Works with all meeting platforms (Zoom, Google Meet, Teams, Discord) via virtual audio device routing
- **Output**: Raw audio chunks (512ms - 1s buffers)

#### 4.2 Audio Preprocessor
- **Technology**: pydub, numpy
- **Function**: Convert audio to Whisper format (16kHz, mono, WAV)
- **Optional**: Noise suppression

#### 4.3 Transcription Service
- **Technology**: OpenAI Whisper API (faster-whisper for local alternative)
- **Function**: Convert audio to text
- **Latency Target**: 3-5 seconds

**Data Flow**:
```
System Audio → Virtual Device → Audio Capture → Buffer →
Preprocess (convert to 16kHz mono) → Whisper API →
Transcript Text → Database + WebSocket Broadcast
```

**Key Functions**:
```python
async def start_audio_capture(meeting_id: str) -> None
async def stop_audio_capture(meeting_id: str) -> None
async def transcribe_audio_chunk(audio_data: bytes) -> str
async def broadcast_transcript(meeting_id: str, transcript: str) -> None
```

---

### 5. Document Processing Service

**Purpose**: Handle document uploads and context extraction

**Sub-components**:

#### 5.1 File Upload Handler
- **Function**: Accept and validate uploads (PDF, DOCX, TXT, MD)
- **Storage**: Local filesystem (`backend/uploads/{meeting_id}/`)

#### 5.2 Document Parser
- **Technology**: PyMuPDF (PDF), python-docx (DOCX)
- **Function**: Extract text from uploaded files

#### 5.3 Text Chunker
- **Function**: Split text into semantic chunks (500-800 chars)
- **Strategy**: Overlap chunks to preserve context

#### 5.4 Embedding Generator
- **Technology**: OpenAI Embeddings API or sentence-transformers
- **Function**: Generate vector embeddings for semantic search

#### 5.5 Context Retrieval
- **Technology**: pgvector (PostgreSQL extension)
- **Function**: Semantic search for relevant chunks

**Data Flow**:
```
File Upload → Validate → Parse (extract text) →
Chunk Text → Generate Embeddings → Store in Database →
Query → Vector Search → Relevant Chunks → AI Service
```

**Key Functions**:
```python
async def upload_document(meeting_id: str, file: UploadFile) -> Document
async def parse_document(file_path: str) -> str
async def chunk_text(text: str) -> list[str]
async def generate_embeddings(chunks: list[str]) -> list[list[float]]
async def retrieve_relevant_context(query: str, meeting_id: str) -> list[str]
```

---

### 6. AI Processing Core

**Purpose**: Generate summaries and response suggestions

**Sub-components**:

#### 6.1 Summarization Engine
- **Technology**: OpenAI GPT-4-turbo
- **Function**: Generate rolling summaries of conversation
- **Frequency**: Every 60 seconds
- **Input**: Last 5-10 minutes of transcript

#### 6.2 Question Detection
- **Function**: Identify questions in transcript
- **Approach**: Pattern matching + LLM verification

#### 6.3 Response Suggestion Generator
- **Technology**: OpenAI GPT-4-turbo
- **Function**: Generate contextually-aware response options
- **Input**: Question + recent transcript + relevant context from documents
- **Output**: 2-3 response suggestions with confidence scores

#### 6.4 Prompt Manager
- **Function**: Manage prompt templates
- **Storage**: Configuration file or database

**Data Flow**:
```
Transcript → Sliding Window (last 5-10 min) →
Question Detection → Context Retrieval (vector search) →
LLM (GPT-4) → Response Suggestions → WebSocket Broadcast

Transcript → Rolling Window (60s intervals) →
LLM (GPT-4) → Summary → Database + WebSocket Broadcast
```

**Key Functions**:
```python
async def generate_summary(transcript: str) -> str
async def detect_question(transcript_segment: str) -> Optional[str]
async def generate_response_suggestions(
    question: str,
    transcript: str,
    context: list[str]
) -> list[str]
```

---

### 7. Database Layer

**Purpose**: Persistent data storage

**Technology**: PostgreSQL 15+ with pgvector extension

**Key Tables**:
- **meetings**: Meeting metadata
- **transcripts**: Transcript segments with timestamps
- **summaries**: Generated summaries
- **context_documents**: Uploaded documents
- **context_chunks**: Document chunks with embeddings
- **response_suggestions**: Logged suggestions

**See**: [DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md) for full schema

---

### 8. WebSocket Server

**Purpose**: Real-time bidirectional communication

**Technology**: FastAPI WebSocket or Socket.IO

**Events** (Server → Client):
- `transcript_update`: New transcript segment
- `summary_update`: New summary generated
- `suggestion_generated`: New response suggestions
- `audio_level`: Audio capture level (for monitoring)
- `error`: Error messages

**Events** (Client → Server):
- `join_meeting`: Connect to meeting room
- `leave_meeting`: Disconnect from meeting
- `mark_suggestion_used`: Track suggestion usage

**Connection Management**:
- Room-based (one room per meeting)
- Automatic reconnection on disconnect
- Heartbeat for connection monitoring

---

## Data Flow Diagrams

### Pre-Meeting Setup Flow

```
User → Upload Document
  ↓
API Gateway → Document Service
  ↓
Parse File (PDF/DOCX) → Extract Text
  ↓
Chunk Text (500-800 chars with overlap)
  ↓
Generate Embeddings (OpenAI or local)
  ↓
Store in Database (context_chunks with pgvector)
  ↓
Return Success → User sees "Document uploaded"
```

### During-Meeting Flow (Real-Time)

```
Meeting Audio (Zoom/Meet) → Virtual Audio Device
  ↓
Audio Capture Module → Buffer (512ms chunks)
  ↓
Preprocess (16kHz, mono) → Whisper API
  ↓
Transcript Text
  ├─→ Store in Database (transcripts table)
  ├─→ WebSocket Broadcast → UI Update
  └─→ AI Processing Core
        ├─→ Summarization Engine (every 60s)
        │     ↓
        │   Summary → Database + WebSocket → UI
        │
        └─→ Question Detection
              ↓
            If Question Detected:
              ↓
            Context Retrieval (vector search on uploaded docs)
              ↓
            Response Suggestion Generator (GPT-4 + context)
              ↓
            Suggestions → Database + WebSocket → UI
```

### Post-Meeting Flow

```
User → Stop Meeting
  ↓
Stop Audio Capture
  ↓
Generate Final Summary
  ↓
Store Complete Meeting Record
  ↓
Cleanup Temporary Context
  ↓
Archive Meeting → Meeting History
```

---

## Technology Stack

**See**: [TECHNOLOGY_STACK.md](../TECHNOLOGY_STACK.md) for comprehensive details

### Backend
- **Framework**: FastAPI
- **Language**: Python 3.11+
- **Database**: PostgreSQL 15+ with pgvector
- **ORM**: SQLAlchemy 2.0
- **Validation**: Pydantic 2.0

### Frontend
- **Framework**: React 18
- **Language**: TypeScript 5+
- **State Management**: Zustand
- **Styling**: TailwindCSS + shadcn/ui
- **Build Tool**: Vite

### Audio Processing
- **Capture**: pyaudiowpatch (Windows), sounddevice (cross-platform)
- **Processing**: pydub, numpy
- **Transcription**: OpenAI Whisper API or faster-whisper

### AI/ML
- **LLM**: OpenAI GPT-4-turbo
- **Embeddings**: OpenAI Embeddings API or sentence-transformers
- **Vector Search**: pgvector

### Real-Time Communication
- **WebSocket**: FastAPI WebSocket or Socket.IO

### Document Processing
- **PDF**: PyMuPDF (fitz)
- **DOCX**: python-docx

---

## Component Specifications

### Audio Capture Configuration

```python
AUDIO_CONFIG = {
    "sample_rate": 16000,  # 16kHz for Whisper
    "channels": 1,         # Mono
    "chunk_duration": 1.0, # 1 second chunks
    "format": "int16",     # 16-bit PCM
    "buffer_size": 16000,  # 1 second at 16kHz
}
```

### Transcription Configuration

```python
WHISPER_CONFIG = {
    "model": "whisper-1",
    "language": "en",
    "response_format": "json",
    "temperature": 0.0,  # Deterministic
}
```

### LLM Configuration

```python
GPT_CONFIG = {
    "model": "gpt-4-turbo",
    "temperature": 0.7,
    "max_tokens": 200,  # For summaries
    "top_p": 1.0,
}

SUMMARIZATION_PROMPT = """
You are a meeting assistant. Summarize the following conversation.
Focus on: key decisions, action items, important questions.
Keep it under 3 bullet points. Be concise.

Transcript: {transcript}
"""

RESPONSE_SUGGESTION_PROMPT = """
You are helping a user in a job interview.

User's background (from uploaded documents):
{context}

Recent conversation:
{transcript}

Question detected:
{question}

Provide 2-3 response options. Make them sound conversational and relevant.
"""
```

### Vector Search Configuration

```python
VECTOR_SEARCH_CONFIG = {
    "embedding_dimension": 384,  # For all-MiniLM-L6-v2
    "similarity_metric": "cosine",
    "top_k": 5,  # Return top 5 most similar chunks
    "index_type": "ivfflat",  # IVFFlat for pgvector
}
```

---

## Integration Patterns

### 1. Audio-to-Transcript Pipeline

**Pattern**: Producer-Consumer with Queues

```python
# Audio producer (runs continuously during meeting)
async def audio_producer(meeting_id: str):
    while meeting_active(meeting_id):
        audio_chunk = capture_audio()
        await audio_queue.put((meeting_id, audio_chunk))

# Transcript consumer (processes audio chunks)
async def transcript_consumer():
    while True:
        meeting_id, audio_chunk = await audio_queue.get()
        transcript = await transcribe(audio_chunk)
        await store_transcript(meeting_id, transcript)
        await broadcast_transcript(meeting_id, transcript)
```

### 2. Real-Time Updates

**Pattern**: Publish-Subscribe via WebSocket

```python
# Server publishes events
async def publish_event(meeting_id: str, event_type: str, data: dict):
    await websocket_manager.broadcast_to_room(
        room=meeting_id,
        event=event_type,
        data=data
    )

# Client subscribes to events
socket.on('transcript_update', (data) => {
    store.addTranscript(data.text);
});
```

### 3. Context Retrieval

**Pattern**: Query-Augmented Generation (RAG)

```python
async def generate_response_with_context(question: str, meeting_id: str):
    # Retrieve relevant context
    context_chunks = await vector_search(question, meeting_id)

    # Augment prompt with context
    prompt = RESPONSE_PROMPT.format(
        question=question,
        context="\n".join(context_chunks)
    )

    # Generate response
    response = await llm_call(prompt)
    return response
```

---

## Security Architecture

### Data Protection

**Encryption**:
- ✅ API keys stored in environment variables (never committed)
- ✅ Database credentials in `.env` file
- ⚠️ Audio recordings stored locally (not encrypted by default)
- ⚠️ Consider encrypting sensitive data at rest

**Access Control**:
- Currently single-user (no authentication)
- For multi-user: Add JWT-based authentication

### API Key Management

```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    openai_api_key: str
    database_url: str
    secret_key: str

    class Config:
        env_file = ".env"

settings = Settings()  # Loads from .env
```

### Input Validation

- ✅ Pydantic models validate all API inputs
- ✅ File upload size limits (10MB)
- ✅ File type validation (PDF, DOCX, TXT, MD only)
- ✅ SQL injection protection (via SQLAlchemy ORM)

---

## Performance Considerations

### Latency Targets

| Operation | Target | Current Strategy |
|-----------|--------|------------------|
| Audio capture | Real-time | Continuous streaming |
| Transcription | 3-5s | OpenAI Whisper API |
| Summary generation | <10s | GPT-4-turbo with streaming |
| Suggestion generation | 5-8s | Parallel context retrieval + LLM |
| WebSocket message delivery | <100ms | Direct broadcast |
| Database queries | <200ms | Indexed queries |

### Optimization Strategies

**1. Caching**:
```python
from functools import lru_cache

@lru_cache(maxsize=100)
async def get_meeting_context(meeting_id: str):
    # Cache meeting context to avoid repeated DB queries
    pass
```

**2. Async Processing**:
```python
# Process summarization and suggestions in parallel
await asyncio.gather(
    generate_summary(transcript),
    generate_suggestions(question, transcript, meeting_id)
)
```

**3. Database Indexing**:
```sql
CREATE INDEX idx_transcripts_meeting_time
ON transcripts(meeting_id, start_timestamp);

CREATE INDEX idx_context_chunks_embedding
ON context_chunks USING ivfflat (embedding vector_cosine_ops);
```

**4. Connection Pooling**:
```python
from sqlalchemy.pool import QueuePool

engine = create_async_engine(
    DATABASE_URL,
    poolclass=QueuePool,
    pool_size=10,
    max_overflow=20
)
```

---

## Deployment Architecture

### Local Development

```
┌─────────────────────────────────────────┐
│           Developer Machine             │
│                                         │
│  ┌─────────────┐    ┌───────────────┐  │
│  │  Frontend   │    │   Backend     │  │
│  │  (Vite dev) │    │  (Uvicorn)    │  │
│  │  :3000      │    │  :8000        │  │
│  └─────────────┘    └───────────────┘  │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │  PostgreSQL (local)             │   │
│  │  :5432                          │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │  Virtual Audio Device           │   │
│  │  (VB-CABLE / BlackHole)         │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

### Docker Deployment (Recommended)

```yaml
# docker-compose.yml
services:
  backend:
    build: ./backend
    ports:
      - "8000:8000"
    environment:
      - DATABASE_URL=postgresql://user:pass@db:5432/macapy
      - OPENAI_API_KEY=${OPENAI_API_KEY}
    depends_on:
      - db

  frontend:
    build: ./frontend
    ports:
      - "3000:3000"
    depends_on:
      - backend

  db:
    image: ankane/pgvector:latest
    environment:
      - POSTGRES_DB=macapy
      - POSTGRES_USER=user
      - POSTGRES_PASSWORD=pass
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
```

**Deployment Steps**:
```bash
# 1. Clone repository
git clone <repo-url>
cd agentic_assistant

# 2. Create .env file
cp .env.example .env
# Edit .env with your API keys

# 3. Start services
docker-compose up -d

# 4. Access application
# Frontend: http://localhost:3000
# Backend API: http://localhost:8000/docs
```

---

## Error Handling Strategy

### Backend Error Handling

```python
from fastapi import HTTPException

@app.post("/api/meetings")
async def create_meeting(meeting: MeetingCreate):
    try:
        result = await meeting_service.create(meeting)
        return result
    except DatabaseError as e:
        logger.error(f"Database error: {e}")
        raise HTTPException(status_code=500, detail="Database error")
    except ValidationError as e:
        logger.warning(f"Validation error: {e}")
        raise HTTPException(status_code=400, detail=str(e))
```

### Frontend Error Handling

```typescript
const fetchMeeting = async (id: string) => {
  try {
    const response = await fetch(`/api/meetings/${id}`);
    if (!response.ok) {
      throw new Error(`HTTP error: ${response.status}`);
    }
    const data = await response.json();
    return data;
  } catch (error) {
    console.error('Failed to fetch meeting:', error);
    toast.error('Failed to load meeting. Please try again.');
    return null;
  }
};
```

### WebSocket Error Handling

```python
@app.websocket("/ws/meeting/{meeting_id}")
async def websocket_endpoint(websocket: WebSocket, meeting_id: str):
    await websocket.accept()
    try:
        while True:
            data = await websocket.receive_json()
            # Process data
    except WebSocketDisconnect:
        logger.info(f"Client disconnected from meeting {meeting_id}")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
        await websocket.close(code=1011, reason="Internal error")
```

---

## Monitoring & Logging

### Logging Strategy

```python
import logging

# Configure logger
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('logs/macapy.log'),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)

# Usage
logger.info("Meeting started", extra={"meeting_id": meeting_id})
logger.error("Transcription failed", exc_info=True)
```

### Performance Monitoring

```python
import time

async def monitor_latency(func):
    """Decorator to monitor function latency"""
    async def wrapper(*args, **kwargs):
        start = time.time()
        result = await func(*args, **kwargs)
        latency = time.time() - start
        logger.info(f"{func.__name__} latency: {latency:.2f}s")
        return result
    return wrapper

@monitor_latency
async def transcribe_audio(audio_data: bytes) -> str:
    # Implementation
    pass
```

---

## Testing Strategy

### Unit Tests

```python
import pytest

@pytest.mark.asyncio
async def test_generate_summary():
    transcript = "User: What is your experience? Candidate: I have 5 years..."
    summary = await generate_summary(transcript)
    assert len(summary) > 0
    assert "experience" in summary.lower()
```

### Integration Tests

```python
@pytest.mark.asyncio
async def test_full_audio_pipeline(test_audio_file):
    meeting_id = await create_meeting("Test Meeting")
    audio_data = load_audio(test_audio_file)

    transcript = await transcribe_audio(audio_data)
    await store_transcript(meeting_id, transcript)

    stored = await get_transcript(meeting_id)
    assert stored.text == transcript
```

### End-to-End Tests

```typescript
// Using Playwright or Cypress
test('full meeting workflow', async () => {
  await page.goto('http://localhost:3000');
  await page.click('button:has-text("New Meeting")');
  await page.fill('input[name="title"]', 'Test Meeting');
  await page.click('button:has-text("Start")');

  // Verify transcript appears
  await page.waitForSelector('.transcript-item', { timeout: 10000 });
});
```

---

## Future Architecture Enhancements

### 1. Microservices Separation

Split into independent services:
- **API Gateway**: FastAPI
- **Transcription Service**: Separate Python service
- **AI Service**: Separate Python service
- **Document Service**: Separate Python service

**Benefits**: Better scalability, independent deployment

### 2. Message Queue

Add RabbitMQ or Redis for async processing:
```
Audio Capture → Queue → Transcription Worker
Transcript → Queue → AI Processing Worker
```

**Benefits**: Better fault tolerance, load balancing

### 3. Caching Layer

Add Redis for:
- Session management
- Frequently accessed meeting data
- API response caching

### 4. CDN for Static Assets

For production deployment:
- Serve frontend via CDN (Cloudflare, AWS CloudFront)
- Reduce latency for static files

---

## Conclusion

This architecture provides:
- ✅ **Real-time performance** through async processing and WebSockets
- ✅ **Scalability** through modular component design
- ✅ **Maintainability** through clear separation of concerns
- ✅ **Extensibility** for future enhancements

**Next Steps**:
1. Review this architecture
2. Start implementation with Stage 1 (see ROADMAP.md)
3. Iterate and refine as you build

---

**Document Version**: 1.0
**Last Updated**: 2025-10-09
