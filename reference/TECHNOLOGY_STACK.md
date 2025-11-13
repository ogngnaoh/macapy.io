# macapy.io Technology Stack & Learning Guide

**Last Updated**: 2025-10-09
**Project**: macapy.io - AI-Powered Personal Meeting Assistant

This document provides a comprehensive overview of all technologies, libraries, frameworks, and concepts you need to understand to build macapy.io. Technologies are organized by system layer with learning priorities and recommended resources.

---

## Table of Contents

1. [Technology Overview](#technology-overview)
2. [Core Programming Languages](#core-programming-languages)
3. [Backend Stack](#backend-stack)
4. [Frontend Stack](#frontend-stack)
5. [Database & Data Storage](#database--data-storage)
6. [Audio Processing](#audio-processing)
7. [AI/ML & LLM Integration](#aiml--llm-integration)
8. [Real-Time Communication](#real-time-communication)
9. [Document Processing](#document-processing)
10. [DevOps & Deployment](#devops--deployment)
11. [Learning Roadmap](#learning-roadmap)
12. [Recommended Resources](#recommended-resources)

---

## Technology Overview

### System Architecture Pattern
- **Event-Driven Architecture**: Components communicate via events
- **Microservices Pattern**: Loosely coupled services
- **Real-Time Processing Pipeline**: Stream processing for audio

### Development Approach
- **API-First Design**: Backend exposes REST + WebSocket APIs
- **Component-Based UI**: React component architecture
- **Async Programming**: Non-blocking I/O for real-time performance

---

## Core Programming Languages

### 1. Python (Backend, AI/ML, Audio Processing)

**Version**: Python 3.11+
**Why**: Excellent AI/ML ecosystem, async support, audio processing libraries

**Key Concepts to Learn**:
- **Async/Await**: `asyncio`, `async def`, `await` - essential for FastAPI
- **Type Hints**: `typing` module - improves code quality and IDE support
- **Context Managers**: `with` statements, `__enter__`/`__exit__`
- **Generators**: `yield`, generator expressions - memory-efficient processing
- **Decorators**: Function/class decorators - used extensively in FastAPI

**Core Libraries**:
- Standard library: `asyncio`, `pathlib`, `dataclasses`, `typing`
- Package management: `pip`, `venv`, `requirements.txt` or `poetry`

**Learning Priority**: 🔴 **CRITICAL** - Start here
**Time Investment**: 2-3 weeks if new to Python, 1 week for async review

**Resources**:
- [Official Python Tutorial](https://docs.python.org/3/tutorial/)
- [Real Python - Async IO](https://realpython.com/async-io-python/)
- [Python Type Hints](https://realpython.com/python-type-checking/)

---

### 2. TypeScript (Frontend)

**Version**: TypeScript 5+
**Why**: Type safety for JavaScript, better IDE support, fewer runtime errors

**Key Concepts to Learn**:
- **Type System**: `interface`, `type`, generics, union types
- **React Integration**: `React.FC`, prop types, hooks typing
- **Async/Promises**: `Promise<T>`, `async/await`
- **Modules**: `import/export`, ES6 modules

**Core Syntax**:
```typescript
interface User {
  id: string;
  name: string;
}

const fetchUser = async (id: string): Promise<User> => {
  // implementation
};
```

**Learning Priority**: 🟡 **IMPORTANT** - Start after Python basics
**Time Investment**: 1-2 weeks if familiar with JavaScript

**Resources**:
- [TypeScript Handbook](https://www.typescriptlang.org/docs/handbook/intro.html)
- [React TypeScript Cheatsheet](https://react-typescript-cheatsheet.netlify.app/)

---

### 3. SQL (Database)

**Dialect**: PostgreSQL 15+
**Why**: Structured data storage, complex queries, vector extension support

**Key Concepts to Learn**:
- **CRUD Operations**: `SELECT`, `INSERT`, `UPDATE`, `DELETE`
- **Joins**: `INNER JOIN`, `LEFT JOIN`, foreign key relationships
- **Indexes**: Performance optimization for queries
- **Transactions**: ACID properties, `BEGIN`, `COMMIT`, `ROLLBACK`
- **JSON Support**: `JSONB` type in PostgreSQL

**Learning Priority**: 🟡 **IMPORTANT** - Learn alongside backend
**Time Investment**: 1 week for basics

**Resources**:
- [PostgreSQL Tutorial](https://www.postgresqltutorial.com/)
- [SQL for Data Analysis](https://mode.com/sql-tutorial/)

---

## Backend Stack

### 1. FastAPI

**Version**: FastAPI 0.100+
**Purpose**: High-performance async web framework

**Why FastAPI**:
- Built on modern Python (async/await)
- Automatic API documentation (OpenAPI/Swagger)
- Type validation via Pydantic
- WebSocket support built-in
- Excellent performance (comparable to Node.js)

**Key Concepts**:
- **Path Operations**: `@app.get()`, `@app.post()`, route decorators
- **Dependency Injection**: `Depends()` for shared logic
- **Pydantic Models**: Request/response validation
- **Background Tasks**: `BackgroundTasks` for async operations
- **WebSocket**: `WebSocket` endpoint handling

**Example**:
```python
from fastapi import FastAPI, WebSocket
from pydantic import BaseModel

app = FastAPI()

class Meeting(BaseModel):
    title: str
    platform: str

@app.post("/api/meetings")
async def create_meeting(meeting: Meeting):
    return {"id": "123", **meeting.dict()}

@app.websocket("/ws/meeting/{meeting_id}")
async def websocket_endpoint(websocket: WebSocket, meeting_id: str):
    await websocket.accept()
    # Handle real-time communication
```

**Learning Priority**: 🔴 **CRITICAL** - Core backend framework
**Time Investment**: 1-2 weeks

**Resources**:
- [FastAPI Official Tutorial](https://fastapi.tiangolo.com/tutorial/)
- [FastAPI Best Practices](https://github.com/zhanymkanov/fastapi-best-practices)

---

### 2. Pydantic

**Version**: Pydantic 2.0+
**Purpose**: Data validation and settings management

**Key Concepts**:
- **Models**: Data validation classes
- **Field Validation**: Type checking, constraints
- **Serialization**: `.dict()`, `.json()` methods
- **Settings Management**: Environment variable handling

**Example**:
```python
from pydantic import BaseModel, Field, validator

class TranscriptSegment(BaseModel):
    speaker: str
    text: str
    start_time: float = Field(gt=0)
    end_time: float

    @validator('end_time')
    def end_after_start(cls, v, values):
        if 'start_time' in values and v <= values['start_time']:
            raise ValueError('end_time must be after start_time')
        return v
```

**Learning Priority**: 🟡 **IMPORTANT** - Learn with FastAPI
**Time Investment**: 3-4 days

**Resources**:
- [Pydantic Documentation](https://docs.pydantic.dev/)

---

### 3. SQLAlchemy

**Version**: SQLAlchemy 2.0+
**Purpose**: SQL ORM and database toolkit

**Key Concepts**:
- **ORM Models**: Python classes mapped to tables
- **Sessions**: Database connection management
- **Queries**: Pythonic database queries
- **Async Support**: `asyncpg` driver integration
- **Migrations**: Schema versioning (with Alembic)

**Example**:
```python
from sqlalchemy import Column, String, Float, ForeignKey
from sqlalchemy.orm import declarative_base, relationship

Base = declarative_base()

class Meeting(Base):
    __tablename__ = "meetings"

    id = Column(String, primary_key=True)
    title = Column(String, nullable=False)

    transcripts = relationship("Transcript", back_populates="meeting")

class Transcript(Base):
    __tablename__ = "transcripts"

    id = Column(String, primary_key=True)
    meeting_id = Column(String, ForeignKey("meetings.id"))
    text = Column(String)
    start_time = Column(Float)

    meeting = relationship("Meeting", back_populates="transcripts")
```

**Learning Priority**: 🟠 **MODERATE** - Can start simple, learn incrementally
**Time Investment**: 1 week for basics, ongoing for advanced features

**Resources**:
- [SQLAlchemy Tutorial](https://docs.sqlalchemy.org/en/20/tutorial/)
- [SQLAlchemy ORM Guide](https://docs.sqlalchemy.org/en/20/orm/)

---

### 4. Alembic

**Version**: Alembic 1.12+
**Purpose**: Database migration tool for SQLAlchemy

**Key Concepts**:
- **Migrations**: Version-controlled schema changes
- **Revision History**: Track database changes over time
- **Upgrade/Downgrade**: Apply or revert migrations

**Learning Priority**: 🟢 **NICE-TO-HAVE** - Learn when needed
**Time Investment**: 2-3 days

---

## Frontend Stack

### 1. React

**Version**: React 18+
**Purpose**: UI library for building component-based interfaces

**Key Concepts**:
- **Components**: Functional components with JSX
- **Hooks**: `useState`, `useEffect`, `useContext`, `useRef`, `useMemo`, `useCallback`
- **Props**: Component communication
- **State Management**: Local state vs. global state
- **Lifecycle**: Component mounting, updating, unmounting

**Example**:
```typescript
import React, { useState, useEffect } from 'react';

interface TranscriptProps {
  meetingId: string;
}

export const TranscriptView: React.FC<TranscriptProps> = ({ meetingId }) => {
  const [transcript, setTranscript] = useState<string[]>([]);

  useEffect(() => {
    // Connect to WebSocket and update transcript
    const ws = new WebSocket(`ws://localhost:8000/ws/meeting/${meetingId}`);

    ws.onmessage = (event) => {
      const data = JSON.parse(event.data);
      setTranscript(prev => [...prev, data.text]);
    };

    return () => ws.close();
  }, [meetingId]);

  return (
    <div>
      {transcript.map((line, idx) => (
        <p key={idx}>{line}</p>
      ))}
    </div>
  );
};
```

**Learning Priority**: 🔴 **CRITICAL** - Core frontend framework
**Time Investment**: 2-3 weeks for solid foundation

**Resources**:
- [React Official Tutorial](https://react.dev/learn)
- [React Hooks Documentation](https://react.dev/reference/react)

---

### 2. Zustand

**Version**: Zustand 4+
**Purpose**: Lightweight state management library

**Why Zustand** (vs Redux):
- Simpler API, less boilerplate
- Better performance for real-time updates
- Built-in TypeScript support
- No context provider wrapping needed

**Key Concepts**:
- **Store Creation**: `create()` function
- **Hooks**: Auto-generated hooks for state access
- **Actions**: Functions that modify state
- **Selectors**: Optimized state selection

**Example**:
```typescript
import create from 'zustand';

interface MeetingStore {
  transcript: string[];
  summaries: string[];
  addTranscript: (text: string) => void;
  addSummary: (summary: string) => void;
}

export const useMeetingStore = create<MeetingStore>((set) => ({
  transcript: [],
  summaries: [],
  addTranscript: (text) => set((state) => ({
    transcript: [...state.transcript, text]
  })),
  addSummary: (summary) => set((state) => ({
    summaries: [...state.summaries, summary]
  })),
}));
```

**Learning Priority**: 🟠 **MODERATE** - Learn when building UI
**Time Investment**: 1-2 days

**Resources**:
- [Zustand Documentation](https://docs.pmnd.rs/zustand/getting-started/introduction)

---

### 3. TailwindCSS

**Version**: Tailwind 3+
**Purpose**: Utility-first CSS framework

**Key Concepts**:
- **Utility Classes**: `flex`, `p-4`, `text-lg`, `bg-blue-500`
- **Responsive Design**: `sm:`, `md:`, `lg:` prefixes
- **Dark Mode**: `dark:` prefix
- **Custom Configuration**: `tailwind.config.js`

**Example**:
```tsx
<div className="flex flex-col gap-4 p-6 bg-gray-100 rounded-lg shadow-md">
  <h2 className="text-2xl font-bold text-gray-800">Live Transcript</h2>
  <div className="overflow-y-auto h-96 bg-white p-4 rounded">
    {transcript.map((line, idx) => (
      <p key={idx} className="text-sm text-gray-700 mb-2">{line}</p>
    ))}
  </div>
</div>
```

**Learning Priority**: 🟠 **MODERATE** - Learn basics quickly
**Time Investment**: 2-3 days for productive use

**Resources**:
- [Tailwind Documentation](https://tailwindcss.com/docs)
- [Tailwind UI Components](https://tailwindui.com/) (paid)

---

### 4. shadcn/ui

**Version**: Latest (component library, not versioned traditionally)
**Purpose**: Copy-paste React component collection

**Why shadcn/ui**:
- Not an npm dependency - copy components directly
- Built on Radix UI (accessibility-first)
- Styled with TailwindCSS
- Fully customizable
- TypeScript-first

**Key Components for macapy.io**:
- **Card**: For summary and suggestion displays
- **ScrollArea**: For transcript display
- **Badge**: For speaker labels
- **Dialog**: For document upload modal
- **Toast**: For notifications
- **Button**: Standard buttons

**Learning Priority**: 🟢 **NICE-TO-HAVE** - Use as needed
**Time Investment**: 1 day to understand, ongoing as you use components

**Resources**:
- [shadcn/ui Documentation](https://ui.shadcn.com/)

---

### 5. Socket.IO Client

**Version**: Socket.IO 4+
**Purpose**: WebSocket communication with real-time updates

**Key Concepts**:
- **Connection Management**: Connect/disconnect handling
- **Event Emission**: Client → Server messages
- **Event Listening**: Server → Client messages
- **Reconnection**: Automatic reconnect on failure

**Example**:
```typescript
import { useEffect } from 'react';
import { io } from 'socket.io-client';

export const useWebSocket = (meetingId: string) => {
  useEffect(() => {
    const socket = io('http://localhost:8000');

    socket.emit('join_meeting', { meeting_id: meetingId });

    socket.on('transcript_update', (data) => {
      console.log('New transcript:', data);
    });

    socket.on('summary_update', (data) => {
      console.log('New summary:', data);
    });

    return () => {
      socket.disconnect();
    };
  }, [meetingId]);
};
```

**Learning Priority**: 🟡 **IMPORTANT** - Critical for real-time features
**Time Investment**: 2-3 days

**Resources**:
- [Socket.IO Client Documentation](https://socket.io/docs/v4/client-api/)

---

### 6. Vite

**Version**: Vite 5+
**Purpose**: Fast build tool and dev server

**Why Vite** (vs Create React App):
- Much faster development server
- Instant hot module replacement (HMR)
- Optimized production builds
- Native ES modules support

**Key Concepts**:
- **Dev Server**: `vite dev` - instant startup
- **Build**: `vite build` - production optimization
- **Configuration**: `vite.config.ts`
- **Plugins**: Extend functionality

**Learning Priority**: 🟢 **NICE-TO-HAVE** - Just use defaults initially
**Time Investment**: 1 day

**Resources**:
- [Vite Documentation](https://vitejs.dev/)

---

## Database & Data Storage

### 1. PostgreSQL

**Version**: PostgreSQL 15+
**Purpose**: Primary relational database

**Key Concepts**:
- **Tables & Relations**: Foreign keys, joins
- **JSONB**: Flexible schema storage
- **Indexes**: Query optimization
- **Transactions**: Data consistency
- **Extensions**: pgvector for vector storage

**Learning Priority**: 🟡 **IMPORTANT** - Learn with backend
**Time Investment**: 1-2 weeks

**Resources**:
- [PostgreSQL Documentation](https://www.postgresql.org/docs/15/)
- [PostgreSQL Tutorial](https://www.postgresqltutorial.com/)

---

### 2. pgvector

**Version**: pgvector 0.5+
**Purpose**: Vector similarity search in PostgreSQL

**Why pgvector**:
- Store embeddings directly in PostgreSQL
- Efficient similarity search
- No separate vector database needed
- SQL-based querying

**Key Concepts**:
- **Vector Type**: `VECTOR(dimension)` column type
- **Similarity Operators**: `<->` (L2), `<#>` (inner product), `<=>` (cosine)
- **Indexes**: IVFFlat, HNSW for fast search

**Example**:
```sql
-- Create table with vector column
CREATE TABLE context_chunks (
    id UUID PRIMARY KEY,
    text TEXT,
    embedding VECTOR(384)
);

-- Create index for fast similarity search
CREATE INDEX ON context_chunks
    USING ivfflat (embedding vector_cosine_ops);

-- Find similar chunks
SELECT text, embedding <=> '[0.1, 0.2, ...]'::vector AS distance
FROM context_chunks
ORDER BY distance
LIMIT 5;
```

**Learning Priority**: 🟠 **MODERATE** - Learn when implementing context retrieval
**Time Investment**: 2-3 days

**Resources**:
- [pgvector GitHub](https://github.com/pgvector/pgvector)
- [pgvector Guide](https://github.com/pgvector/pgvector/blob/master/README.md)

---

### 3. Alternative: SQLite + ChromaDB

**When to Use**: Simpler deployment, no PostgreSQL setup

**SQLite**: Lightweight file-based database
**ChromaDB**: Open-source vector database

**Learning Priority**: 🟢 **OPTIONAL** - Alternative approach
**Time Investment**: 1 week

---

## Audio Processing

### 1. PyAudio / sounddevice

**Version**: PyAudio 0.2+ or sounddevice 0.4+
**Purpose**: Audio capture and playback

**Key Concepts**:
- **Audio Streams**: Continuous audio input/output
- **Callbacks**: Process audio chunks in real-time
- **Sample Rate**: 16kHz recommended for Whisper
- **Channels**: Mono (1 channel) vs Stereo (2 channels)
- **Buffer Size**: Trade-off between latency and reliability

**Example** (sounddevice):
```python
import sounddevice as sd
import numpy as np

def audio_callback(indata, frames, time, status):
    """Called for each audio chunk"""
    audio_data = indata.copy()
    # Process audio chunk (e.g., send to transcription)
    print(f"Received {len(audio_data)} samples")

# Start recording
stream = sd.InputStream(
    samplerate=16000,
    channels=1,
    callback=audio_callback,
    blocksize=8000  # 0.5 seconds at 16kHz
)

stream.start()
```

**Learning Priority**: 🟡 **IMPORTANT** - Critical for audio capture
**Time Investment**: 3-5 days

**Resources**:
- [sounddevice Documentation](https://python-sounddevice.readthedocs.io/)
- [PyAudio Documentation](https://people.csail.mit.edu/hubert/pyaudio/docs/)

---

### 2. pyaudiowpatch (Windows-specific)

**Version**: Latest from PyPI
**Purpose**: Capture system audio (WASAPI loopback) on Windows

**Why Needed**:
- Standard PyAudio can't capture "what you hear" on Windows
- Captures output from other applications (Zoom, Meet, etc.)
- Uses WASAPI loopback mode

**Learning Priority**: 🔴 **CRITICAL** for Windows - Required for meeting audio
**Time Investment**: 2-3 days

**Resources**:
- [pyaudiowpatch GitHub](https://github.com/s0d3s/PyAudioWPatch)

---

### 3. Virtual Audio Devices

**Purpose**: Route audio between applications

**Options**:
- **Windows**: VB-CABLE, Virtual Audio Cable
- **macOS**: BlackHole
- **Linux**: PulseAudio loopback

**Key Concepts**:
- **Virtual Cable**: Software-based audio routing
- **Input/Output Pairing**: What you play to output appears on input
- **System Audio Routing**: Redirect meeting audio to virtual device

**Learning Priority**: 🟡 **IMPORTANT** - Setup required for testing
**Time Investment**: 1-2 days for setup and testing

**Resources**:
- [VB-CABLE](https://vb-audio.com/Cable/)
- [BlackHole (macOS)](https://github.com/ExistentialAudio/BlackHole)

---

### 4. pydub

**Version**: pydub 0.25+
**Purpose**: Audio file manipulation

**Key Concepts**:
- **Format Conversion**: MP3 → WAV, etc.
- **Audio Segments**: Slice and manipulate audio
- **Export**: Save processed audio

**Example**:
```python
from pydub import AudioSegment

# Load audio
audio = AudioSegment.from_file("meeting.mp3")

# Convert to mono, 16kHz (Whisper format)
audio = audio.set_channels(1).set_frame_rate(16000)

# Export
audio.export("meeting_processed.wav", format="wav")
```

**Learning Priority**: 🟢 **NICE-TO-HAVE** - Useful but not critical
**Time Investment**: 1 day

---

### 5. numpy (for audio processing)

**Version**: numpy 1.24+
**Purpose**: Numerical operations on audio data

**Key Concepts**:
- **Arrays**: Audio as numpy arrays
- **Operations**: Normalize, filter, transform
- **Integration**: Most audio libraries use numpy

**Learning Priority**: 🟠 **MODERATE** - Learn basics
**Time Investment**: 2-3 days for audio-specific usage

---

## AI/ML & LLM Integration

### 1. OpenAI Python SDK

**Version**: openai 1.0+
**Purpose**: Interface with OpenAI APIs (GPT-4, Whisper, Embeddings)

**Key APIs**:
- **Chat Completions**: GPT-4 for summarization and suggestions
- **Whisper**: Speech-to-text transcription
- **Embeddings**: Text embeddings for semantic search

**Example** (Chat Completions):
```python
from openai import AsyncOpenAI

client = AsyncOpenAI(api_key="your-api-key")

async def generate_summary(transcript: str) -> str:
    response = await client.chat.completions.create(
        model="gpt-4-turbo",
        messages=[
            {"role": "system", "content": "You are a meeting assistant."},
            {"role": "user", "content": f"Summarize this transcript:\n{transcript}"}
        ],
        temperature=0.7,
        max_tokens=200
    )
    return response.choices[0].message.content
```

**Example** (Whisper):
```python
async def transcribe_audio(audio_file_path: str) -> str:
    with open(audio_file_path, "rb") as audio_file:
        transcript = await client.audio.transcriptions.create(
            model="whisper-1",
            file=audio_file,
            language="en"
        )
    return transcript.text
```

**Example** (Embeddings):
```python
async def generate_embedding(text: str) -> list[float]:
    response = await client.embeddings.create(
        model="text-embedding-3-small",
        input=text
    )
    return response.data[0].embedding
```

**Learning Priority**: 🔴 **CRITICAL** - Core AI functionality
**Time Investment**: 1 week

**Resources**:
- [OpenAI Python SDK Documentation](https://github.com/openai/openai-python)
- [OpenAI API Reference](https://platform.openai.com/docs/api-reference)

---

### 2. Alternative: faster-whisper (Local Whisper)

**Version**: faster-whisper 1.0+
**Purpose**: Run Whisper locally for privacy/cost savings

**Why Use**:
- No API costs
- Faster than official Whisper
- Full privacy (no data sent to OpenAI)
- Trade-off: Requires GPU for real-time performance

**Learning Priority**: 🟢 **OPTIONAL** - Consider for Phase 2
**Time Investment**: 2-3 days

**Resources**:
- [faster-whisper GitHub](https://github.com/guillaumekln/faster-whisper)

---

### 3. sentence-transformers (Local Embeddings)

**Version**: sentence-transformers 2.2+
**Purpose**: Generate embeddings locally (no API costs)

**Popular Models**:
- `all-MiniLM-L6-v2`: Fast, 384 dimensions
- `all-mpnet-base-v2`: Better quality, 768 dimensions

**Example**:
```python
from sentence_transformers import SentenceTransformer

model = SentenceTransformer('all-MiniLM-L6-v2')

text = "This is a sample document."
embedding = model.encode(text)  # Returns numpy array
print(embedding.shape)  # (384,)
```

**Learning Priority**: 🟠 **MODERATE** - Good for cost savings
**Time Investment**: 2-3 days

**Resources**:
- [sentence-transformers Documentation](https://www.sbert.net/)

---

### 4. Prompt Engineering

**Purpose**: Craft effective prompts for LLMs

**Key Concepts**:
- **System Messages**: Set model behavior
- **Few-Shot Examples**: Provide examples in prompt
- **Temperature**: Control randomness (0.0 = deterministic, 1.0 = creative)
- **Max Tokens**: Limit response length
- **Prompt Templates**: Reusable prompt structures

**Example Prompt Template** (Summarization):
```python
SUMMARIZATION_PROMPT = """You are a meeting assistant. Summarize the following conversation excerpt.

Focus on:
- Key decisions made
- Action items assigned
- Important questions raised

Keep your summary to 3 bullet points maximum. Be concise and actionable.

Conversation:
{transcript}

Summary:"""

# Usage
prompt = SUMMARIZATION_PROMPT.format(transcript=recent_transcript)
```

**Learning Priority**: 🟡 **IMPORTANT** - Critical for quality output
**Time Investment**: Ongoing, 1-2 weeks for basics

**Resources**:
- [OpenAI Prompt Engineering Guide](https://platform.openai.com/docs/guides/prompt-engineering)
- [Prompt Engineering Guide](https://www.promptingguide.ai/)

---

### 5. LangChain (Optional Advanced)

**Version**: LangChain 0.1+
**Purpose**: Framework for building LLM applications

**When to Use**:
- Complex chains of LLM calls
- RAG (Retrieval-Augmented Generation) patterns
- Agent-based workflows

**Learning Priority**: 🟢 **OPTIONAL** - Not needed for MVP
**Time Investment**: 1-2 weeks

---

## Real-Time Communication

### 1. WebSockets (FastAPI)

**Purpose**: Bidirectional real-time communication

**Key Concepts**:
- **Connection Lifecycle**: Connect, message exchange, disconnect
- **Event-Based**: Send/receive messages asynchronously
- **Persistent Connection**: Unlike HTTP request-response

**Example** (FastAPI WebSocket):
```python
from fastapi import WebSocket, WebSocketDisconnect

@app.websocket("/ws/meeting/{meeting_id}")
async def websocket_endpoint(websocket: WebSocket, meeting_id: str):
    await websocket.accept()

    try:
        while True:
            # Receive data from client
            data = await websocket.receive_json()

            # Process data...

            # Send data to client
            await websocket.send_json({
                "type": "transcript_update",
                "text": "New transcript line"
            })
    except WebSocketDisconnect:
        print(f"Client disconnected from meeting {meeting_id}")
```

**Learning Priority**: 🔴 **CRITICAL** - Essential for real-time features
**Time Investment**: 3-5 days

**Resources**:
- [FastAPI WebSocket Documentation](https://fastapi.tiangolo.com/advanced/websockets/)
- [WebSocket Protocol](https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API)

---

### 2. Socket.IO (Python Server)

**Version**: python-socketio 5+
**Purpose**: Higher-level WebSocket abstraction with fallbacks

**Why Socket.IO**:
- Automatic reconnection
- Room/namespace support
- Fallback to HTTP polling
- Better developer experience

**Example**:
```python
import socketio

sio = socketio.AsyncServer(async_mode='asgi', cors_allowed_origins='*')

@sio.event
async def connect(sid, environ):
    print(f"Client {sid} connected")

@sio.event
async def join_meeting(sid, data):
    meeting_id = data['meeting_id']
    await sio.enter_room(sid, meeting_id)

@sio.event
async def disconnect(sid):
    print(f"Client {sid} disconnected")

# Emit to specific room (meeting)
async def broadcast_transcript(meeting_id: str, transcript: str):
    await sio.emit('transcript_update',
                   {'text': transcript},
                   room=meeting_id)
```

**Learning Priority**: 🟡 **IMPORTANT** - Alternative to plain WebSockets
**Time Investment**: 2-3 days

**Resources**:
- [python-socketio Documentation](https://python-socketio.readthedocs.io/)

---

## Document Processing

### 1. PyMuPDF (fitz)

**Version**: PyMuPDF 1.23+
**Purpose**: Extract text from PDF files

**Key Features**:
- Fast PDF parsing
- Text extraction with layout preservation
- Page-by-page processing
- Handles complex PDFs

**Example**:
```python
import fitz  # PyMuPDF

def extract_pdf_text(file_path: str) -> str:
    doc = fitz.open(file_path)
    text = ""

    for page_num in range(len(doc)):
        page = doc[page_num]
        text += f"\n--- Page {page_num + 1} ---\n"
        text += page.get_text()

    doc.close()
    return text
```

**Learning Priority**: 🟡 **IMPORTANT** - Needed for document processing
**Time Investment**: 2-3 days

**Resources**:
- [PyMuPDF Documentation](https://pymupdf.readthedocs.io/)

---

### 2. python-docx

**Version**: python-docx 1.0+
**Purpose**: Extract text from DOCX files

**Example**:
```python
from docx import Document

def extract_docx_text(file_path: str) -> str:
    doc = Document(file_path)
    text = ""

    for para in doc.paragraphs:
        text += para.text + "\n"

    return text
```

**Learning Priority**: 🟡 **IMPORTANT** - Needed for document processing
**Time Investment**: 1 day

**Resources**:
- [python-docx Documentation](https://python-docx.readthedocs.io/)

---

### 3. Text Chunking Strategies

**Purpose**: Split documents into semantic chunks for embedding

**Strategies**:
- **Fixed-size**: Split by character/token count
- **Paragraph-based**: Split by paragraphs
- **Semantic**: Split by meaning (using NLP)
- **Recursive**: Split hierarchically (chapters → sections → paragraphs)

**Example** (Simple fixed-size):
```python
def chunk_text(text: str, chunk_size: int = 500, overlap: int = 50) -> list[str]:
    chunks = []
    start = 0

    while start < len(text):
        end = start + chunk_size
        chunk = text[start:end]
        chunks.append(chunk)
        start = end - overlap  # Overlap to preserve context

    return chunks
```

**Learning Priority**: 🟠 **MODERATE** - Important for context quality
**Time Investment**: 2-3 days

**Resources**:
- [LangChain Text Splitters](https://python.langchain.com/docs/modules/data_connection/document_transformers/)

---

## DevOps & Deployment

### 1. Docker

**Version**: Docker 24+
**Purpose**: Containerization for consistent deployment

**Key Concepts**:
- **Images**: Blueprint for containers
- **Containers**: Running instances of images
- **Dockerfile**: Instructions to build image
- **Volumes**: Persistent data storage

**Example Dockerfile** (Backend):
```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Learning Priority**: 🟠 **MODERATE** - Useful for deployment
**Time Investment**: 3-5 days

**Resources**:
- [Docker Getting Started](https://docs.docker.com/get-started/)

---

### 2. Docker Compose

**Version**: Docker Compose 2.0+
**Purpose**: Multi-container orchestration

**Key Concepts**:
- **Services**: Define multiple containers
- **Networks**: Inter-container communication
- **Volumes**: Shared data between containers

**Example** (docker-compose.yml):
```yaml
version: '3.8'

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
    image: postgres:15
    environment:
      - POSTGRES_DB=macapy
      - POSTGRES_USER=user
      - POSTGRES_PASSWORD=pass
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
```

**Learning Priority**: 🟠 **MODERATE** - Simplifies local deployment
**Time Investment**: 2-3 days

**Resources**:
- [Docker Compose Documentation](https://docs.docker.com/compose/)

---

### 3. Environment Variables

**Purpose**: Configuration management without hardcoding

**Tools**:
- **python-dotenv**: Load `.env` files in Python
- **Pydantic Settings**: Type-safe environment variables

**Example** (.env file):
```
DATABASE_URL=postgresql://localhost:5432/macapy
OPENAI_API_KEY=sk-...
DEBUG=true
```

**Example** (Pydantic Settings):
```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    database_url: str
    openai_api_key: str
    debug: bool = False

    class Config:
        env_file = ".env"

settings = Settings()
```

**Learning Priority**: 🟡 **IMPORTANT** - Security best practice
**Time Investment**: 1 day

---

### 4. Git & GitHub

**Version**: Git 2.40+
**Purpose**: Version control

**Key Concepts**:
- **Commits**: Snapshots of code
- **Branches**: Parallel development
- **Merging**: Combine changes
- **Remote**: GitHub repository

**Learning Priority**: 🔴 **CRITICAL** - Essential for any project
**Time Investment**: 1 week for basics

**Resources**:
- [Git Documentation](https://git-scm.com/doc)
- [GitHub Guides](https://guides.github.com/)

---

## Learning Roadmap

### Phase 0: Prerequisites (Before Starting)

**Essential Skills**:
- ✅ Comfortable with command line/terminal
- ✅ Basic programming concepts (variables, functions, loops)
- ✅ Text editor/IDE setup (VS Code recommended)
- ✅ Git basics (clone, commit, push, pull)

**Recommended**: Complete "Python for Everybody" or equivalent

---

### Phase 1: Core Fundamentals (2-3 weeks)

**Focus**: Backend basics + Python async

**Learning Order**:
1. **Python fundamentals** (1 week)
   - Async/await, type hints, decorators
   - Practice: Build a simple async HTTP client

2. **FastAPI basics** (1 week)
   - Create REST API with CRUD operations
   - Pydantic models for validation
   - Practice: Build a TODO API

3. **PostgreSQL & SQLAlchemy** (1 week)
   - SQL basics: SELECT, JOIN, INSERT, UPDATE
   - SQLAlchemy ORM models
   - Practice: Add database to TODO API

**Milestone**: Build a simple REST API with database

---

### Phase 2: Frontend Foundations (2-3 weeks)

**Focus**: React + TypeScript

**Learning Order**:
1. **TypeScript basics** (3 days)
   - Type system, interfaces, generics
   - Practice: Convert JavaScript code to TypeScript

2. **React fundamentals** (1 week)
   - Components, props, state
   - Hooks: useState, useEffect, useContext
   - Practice: Build a dashboard UI

3. **React + API integration** (3 days)
   - Fetch data from API
   - Handle loading/error states
   - Practice: Connect dashboard to TODO API

4. **TailwindCSS** (2 days)
   - Utility classes, responsive design
   - Practice: Style the dashboard

**Milestone**: Build a responsive React app that talks to your API

---

### Phase 3: Real-Time Communication (1 week)

**Focus**: WebSockets

**Learning Order**:
1. **WebSocket concepts** (2 days)
   - Connection lifecycle
   - Bidirectional messaging

2. **FastAPI WebSockets** (2 days)
   - Implement WebSocket endpoint
   - Practice: Add real-time updates to TODO API

3. **Socket.IO (client & server)** (3 days)
   - Set up Socket.IO
   - Room-based messaging
   - Practice: Build a simple chat app

**Milestone**: Real-time updates between frontend and backend

---

### Phase 4: Audio & AI (2-3 weeks)

**Focus**: Audio capture + OpenAI APIs

**Learning Order**:
1. **Audio basics** (1 week)
   - Sound theory: sample rate, channels
   - sounddevice or PyAudio
   - Virtual audio device setup
   - Practice: Record and save audio

2. **OpenAI Whisper API** (3 days)
   - Audio transcription
   - Handle API responses
   - Practice: Transcribe an audio file

3. **OpenAI Chat API** (3 days)
   - GPT-4 for text generation
   - Prompt engineering basics
   - Practice: Build a simple chatbot

4. **Embeddings & vector search** (4 days)
   - Generate embeddings
   - Store in pgvector
   - Similarity search
   - Practice: Semantic search over documents

**Milestone**: Transcribe audio and generate AI responses

---

### Phase 5: Document Processing (3-5 days)

**Focus**: PDF/DOCX parsing + chunking

**Learning Order**:
1. **PyMuPDF & python-docx** (2 days)
   - Extract text from files
   - Practice: Parse resume and extract key info

2. **Text chunking** (2 days)
   - Implement chunking strategy
   - Generate embeddings per chunk
   - Practice: Chunk a long document and search it

**Milestone**: Upload document, chunk it, and retrieve relevant sections

---

### Phase 6: Integration & Polish (Ongoing)

**Focus**: Bring it all together

**Tasks**:
1. Integrate all components
2. Handle errors gracefully
3. Optimize performance
4. Write tests
5. Create documentation

**Milestone**: Fully functional macapy.io MVP

---

## Recommended Resources

### Online Courses

**Python**:
- [Python for Everybody (Coursera)](https://www.coursera.org/specializations/python) - Free
- [Real Python](https://realpython.com/) - Paid membership, excellent tutorials

**FastAPI**:
- [FastAPI Official Tutorial](https://fastapi.tiangolo.com/tutorial/) - Free, best resource

**React**:
- [React Official Tutorial](https://react.dev/learn) - Free, comprehensive
- [Epic React by Kent C. Dodds](https://epicreact.dev/) - Paid, in-depth

**Databases**:
- [PostgreSQL Tutorial](https://www.postgresqltutorial.com/) - Free
- [SQL for Data Analysis (Mode)](https://mode.com/sql-tutorial/) - Free

**Full Stack**:
- [Full Stack Open](https://fullstackopen.com/en/) - Free, comprehensive

---

### Books

**Python**:
- "Python Crash Course" by Eric Matthes - Beginner-friendly
- "Fluent Python" by Luciano Ramalho - Advanced

**JavaScript/TypeScript**:
- "JavaScript: The Good Parts" by Douglas Crockford
- "Effective TypeScript" by Dan Vanderkam

**System Design**:
- "Designing Data-Intensive Applications" by Martin Kleppmann

---

### Documentation (Bookmark These)

- [Python Docs](https://docs.python.org/3/)
- [FastAPI Docs](https://fastapi.tiangolo.com/)
- [React Docs](https://react.dev/)
- [PostgreSQL Docs](https://www.postgresql.org/docs/)
- [OpenAI API Docs](https://platform.openai.com/docs)
- [TailwindCSS Docs](https://tailwindcss.com/docs)

---

### Communities

**Get Help**:
- [Stack Overflow](https://stackoverflow.com/)
- [FastAPI Discord](https://discord.com/invite/VQjSZaeJmf)
- [Reactiflux Discord](https://www.reactiflux.com/)
- [r/learnpython Reddit](https://www.reddit.com/r/learnpython/)
- [r/reactjs Reddit](https://www.reddit.com/r/reactjs/)

---

## Summary: Priority Matrix

| Technology | Priority | When to Learn | Time Investment |
|------------|----------|---------------|-----------------|
| Python | 🔴 CRITICAL | Phase 1 | 2-3 weeks |
| FastAPI | 🔴 CRITICAL | Phase 1 | 1-2 weeks |
| React | 🔴 CRITICAL | Phase 2 | 2-3 weeks |
| TypeScript | 🔴 CRITICAL | Phase 2 | 1-2 weeks |
| WebSockets | 🔴 CRITICAL | Phase 3 | 1 week |
| OpenAI APIs | 🔴 CRITICAL | Phase 4 | 1 week |
| Audio Processing | 🔴 CRITICAL | Phase 4 | 1 week |
| PostgreSQL | 🟡 IMPORTANT | Phase 1 | 1 week |
| SQLAlchemy | 🟡 IMPORTANT | Phase 1 | 1 week |
| Socket.IO | 🟡 IMPORTANT | Phase 3 | 3-5 days |
| PyMuPDF | 🟡 IMPORTANT | Phase 5 | 2-3 days |
| python-docx | 🟡 IMPORTANT | Phase 5 | 1 day |
| Pydantic | 🟡 IMPORTANT | Phase 1 | 3-4 days |
| TailwindCSS | 🟠 MODERATE | Phase 2 | 2-3 days |
| Zustand | 🟠 MODERATE | Phase 2 | 1-2 days |
| pgvector | 🟠 MODERATE | Phase 4 | 2-3 days |
| Docker | 🟠 MODERATE | Phase 6 | 3-5 days |
| shadcn/ui | 🟢 NICE-TO-HAVE | As needed | 1 day |
| Alembic | 🟢 NICE-TO-HAVE | Phase 6 | 2-3 days |
| faster-whisper | 🟢 OPTIONAL | Phase 6+ | 2-3 days |
| LangChain | 🟢 OPTIONAL | Phase 6+ | 1-2 weeks |

---

## Quick Start Checklist

**Before you code**, ensure you understand:
- [ ] Python async/await
- [ ] TypeScript basics
- [ ] REST API concepts
- [ ] WebSocket concepts
- [ ] Git basics

**Development environment setup**:
- [ ] Python 3.11+ installed
- [ ] Node.js 18+ installed
- [ ] PostgreSQL 15+ installed
- [ ] VS Code or preferred IDE
- [ ] Git configured
- [ ] Virtual audio device installed (for testing)

**Start learning in this order**:
1. Python + FastAPI (2-3 weeks)
2. React + TypeScript (2-3 weeks)
3. WebSockets (1 week)
4. OpenAI APIs + Audio (2 weeks)
5. Integration (ongoing)

---

**Total estimated learning time before productive development**: 8-10 weeks

**Remember**: You don't need to master everything before starting. Learn the basics of each technology, then deepen your knowledge as you build.

Good luck building macapy.io! 🚀
