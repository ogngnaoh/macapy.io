# Application Architecture Document
# macapy.io - Agentic Meeting Assistant

**Version**: 1.0
**Last Updated**: 2025-11-25
**Status**: Draft - Pre-Implementation

---

## 1. Architecture Overview

### 1.1 High-Level System Architecture

```
+------------------------------------------------------------------+
|                      ELECTRON APPLICATION                         |
|  +------------------------------------------------------------+  |
|  |                    RENDERER PROCESS                         |  |
|  |  +------------------+  +------------------+  +------------+ |  |
|  |  |   React + TS     |  |  Zustand Store   |  | WebSocket  | |  |
|  |  |   Components     |  |  State Manager   |  | Client     | |  |
|  |  +--------+---------+  +--------+---------+  +-----+------+ |  |
|  |           |                     |                  |        |  |
|  |           +----------+----------+------------------+        |  |
|  |                      |                                      |  |
|  |              contextBridge (IPC)                            |  |
|  +------------------------+-----------------------------------+  |
|                           |                                      |
|  +------------------------+-----------------------------------+  |
|  |                    MAIN PROCESS                             |  |
|  |  +------------------+  +------------------+  +------------+ |  |
|  |  |  Window Manager  |  |  IPC Handlers    |  | Tray/Menu  | |  |
|  |  +------------------+  +------------------+  +------------+ |  |
|  |  +------------------+  +------------------+                 |  |
|  |  |  Auto Updater    |  |  Secure Storage  |                 |  |
|  |  +------------------+  +------------------+                 |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
           |                    |                    |
           | HTTP/REST          | WebSocket          | HTTP/REST
           v                    v                    v
+------------------------------------------------------------------+
|                      BACKEND SERVER (FastAPI)                     |
|  +------------------+  +------------------+  +------------------+ |
|  |   REST API       |  |  WebSocket       |  |  Background      | |
|  |   Endpoints      |  |  Manager         |  |  Tasks           | |
|  +--------+---------+  +--------+---------+  +--------+---------+ |
|           |                     |                     |           |
|  +--------+---------------------+---------------------+--------+  |
|  |                     SERVICE LAYER                           |  |
|  |  +------------------+  +------------------+  +------------+ |  |
|  |  | MeetingService   |  | TranscriptionSvc |  | LLMService | |  |
|  |  +------------------+  +------------------+  +------------+ |  |
|  |  +------------------+  +------------------+  +------------+ |  |
|  |  | AudioCapture     |  | ContextService   |  | EmbeddingSvc| |  |
|  |  +------------------+  +------------------+  +------------+ |  |
|  +-------------------------------------------------------------+  |
|           |                     |                     |           |
|           v                     v                     v           |
|  +------------------+  +------------------+  +------------------+ |
|  |   PostgreSQL     |  |    pgvector      |  |   File Storage   | |
|  |   (SQLAlchemy)   |  |   (Embeddings)   |  |   (Uploads)      | |
|  +------------------+  +------------------+  +------------------+ |
+------------------------------------------------------------------+
           |                                         |
           v                                         v
+------------------+                     +------------------+
|   OpenAI APIs    |                     |  Virtual Audio   |
| Whisper/GPT-5    |                     | (VB-CABLE/etc)   |
+------------------+                     +------------------+
```

### 1.2 Process Architecture

| Process | Role | Technologies |
|---------|------|--------------|
| **Electron Main** | Window management, native APIs, IPC bridge | Node.js, Electron Main APIs |
| **Electron Renderer** | UI rendering, user interaction | React, TypeScript, Zustand |
| **Backend Server** | Business logic, API, real-time events | FastAPI, Python, asyncio |
| **Database** | Data persistence, vector search | PostgreSQL, pgvector |

---

## 2. Frontend Architecture

### 2.1 Technology Stack Recommendation

After analyzing the requirements, I recommend the following stack:

| Layer | Technology | Rationale |
|-------|------------|-----------|
| Framework | **React 18** | Mature ecosystem, excellent TypeScript support, large talent pool |
| Build Tool | **Vite** | Fast HMR, modern bundling, excellent Electron support |
| State Management | **Zustand** | Simple API, minimal boilerplate, good for real-time updates |
| Styling | **TailwindCSS** | Utility-first, fast development, excellent for custom dark themes |
| Components | **Custom + Radix UI** | Accessible primitives, full styling control |
| Real-time | **Native WebSocket** | Lightweight, no Socket.IO overhead needed |

**Why React over Vue/Svelte?**
- Existing React code mentioned in CLAUDE.md (frontend structure planned)
- Larger ecosystem for Electron integrations
- Better TypeScript tooling and type inference
- More community resources for real-time applications

### 2.2 Project Structure

```
frontend/
├── electron/
│   ├── main/
│   │   ├── index.ts           # Main process entry
│   │   ├── window.ts          # Window creation/management
│   │   ├── ipc-handlers.ts    # IPC channel handlers
│   │   ├── tray.ts            # System tray management
│   │   ├── menu.ts            # Application menu
│   │   ├── auto-update.ts     # Electron updater
│   │   └── storage.ts         # Secure storage (API keys)
│   └── preload/
│       └── index.ts           # Context bridge definitions
├── src/
│   ├── main.tsx               # React entry point
│   ├── App.tsx                # Root component
│   ├── components/
│   │   ├── layout/
│   │   │   ├── TitleBar.tsx
│   │   │   ├── MainLayout.tsx
│   │   │   └── SidePanel.tsx
│   │   ├── meeting/
│   │   │   ├── MeetingControls.tsx
│   │   │   ├── TranscriptPanel.tsx
│   │   │   ├── SummaryPanel.tsx
│   │   │   ├── QueryInput.tsx
│   │   │   └── SuggestionNotification.tsx
│   │   ├── history/
│   │   │   ├── MeetingList.tsx
│   │   │   ├── MeetingDetail.tsx
│   │   │   └── SearchBar.tsx
│   │   └── common/
│   │       ├── Button.tsx
│   │       ├── Input.tsx
│   │       ├── Modal.tsx
│   │       ├── Toast.tsx
│   │       └── VirtualList.tsx
│   ├── hooks/
│   │   ├── useWebSocket.ts    # WebSocket connection hook
│   │   ├── useMeeting.ts      # Meeting state and actions
│   │   ├── useTranscript.ts   # Transcript management
│   │   ├── useKeyboard.ts     # Keyboard shortcuts
│   │   └── useApi.ts          # REST API client hook
│   ├── store/
│   │   ├── index.ts           # Zustand store
│   │   ├── meetingSlice.ts    # Meeting state slice
│   │   ├── transcriptSlice.ts # Transcript state slice
│   │   ├── historySlice.ts    # History state slice
│   │   └── uiSlice.ts         # UI state slice
│   ├── services/
│   │   ├── api.ts             # REST API client
│   │   ├── websocket.ts       # WebSocket manager
│   │   └── tokenCounter.ts    # Token estimation utility
│   ├── styles/
│   │   ├── globals.css        # Global styles
│   │   └── theme.ts           # Theme configuration
│   ├── types/
│   │   ├── api.ts             # API response types
│   │   ├── meeting.ts         # Meeting domain types
│   │   └── electron.ts        # Electron IPC types
│   └── utils/
│       ├── formatters.ts      # Date, duration formatters
│       ├── validators.ts      # Input validation
│       └── constants.ts       # Application constants
├── index.html
├── package.json
├── tsconfig.json
├── vite.config.ts
├── electron-builder.yml       # Build configuration
└── tailwind.config.js
```

### 2.3 State Management Architecture

```typescript
// store/index.ts - Zustand Store Structure

import { create } from 'zustand';
import { devtools, persist } from 'zustand/middleware';
import { immer } from 'zustand/middleware/immer';

interface AppStore {
  // Meeting Slice
  meeting: {
    current: Meeting | null;
    status: MeetingStatus;
    duration: number;
  };
  meetingActions: {
    start: (title: string) => Promise<void>;
    stop: () => Promise<void>;
    updateDuration: () => void;
  };

  // Transcript Slice
  transcript: {
    segments: TranscriptSegment[];
    isAutoScroll: boolean;
  };
  transcriptActions: {
    addSegment: (segment: TranscriptSegment) => void;
    setAutoScroll: (enabled: boolean) => void;
    clear: () => void;
  };

  // Summary Slice
  summary: {
    items: Summary[];
    isLoading: boolean;
  };
  summaryActions: {
    addSummary: (summary: Summary) => void;
    triggerManual: () => Promise<void>;
  };

  // Query Slice
  query: {
    input: string;
    exchanges: QueryExchange[];
    isLoading: boolean;
  };
  queryActions: {
    setInput: (value: string) => void;
    send: () => Promise<void>;
    getRecap: () => Promise<void>;
  };

  // Suggestion Slice
  suggestion: {
    queue: SuggestionData[];
    active: SuggestionData | null;
  };
  suggestionActions: {
    add: (suggestion: SuggestionData) => void;
    dismiss: () => void;
    markUsed: (id: string, index: number) => void;
  };

  // Token Slice
  tokens: {
    current: number;
    max: number;
  };
  tokenActions: {
    update: (count: number) => void;
  };

  // History Slice
  history: {
    meetings: MeetingListItem[];
    selected: MeetingFull | null;
    searchQuery: string;
    isLoading: boolean;
  };
  historyActions: {
    load: () => Promise<void>;
    select: (id: string) => Promise<void>;
    search: (query: string) => void;
    delete: (id: string) => Promise<void>;
  };

  // UI Slice
  ui: {
    activeView: 'meeting' | 'history';
    isAlwaysOnTop: boolean;
  };
  uiActions: {
    setView: (view: 'meeting' | 'history') => void;
    toggleAlwaysOnTop: () => void;
  };
}
```

### 2.4 IPC Communication Patterns

```typescript
// electron/preload/index.ts

import { contextBridge, ipcRenderer } from 'electron';

// Define allowed channels
const validChannels = {
  send: ['window:minimize', 'window:maximize', 'window:close', 'window:always-on-top'],
  invoke: ['storage:get', 'storage:set', 'storage:delete'],
  on: ['window:focused', 'shortcut:triggered'],
};

// Expose safe API to renderer
contextBridge.exposeInMainWorld('electronAPI', {
  // Window Controls
  window: {
    minimize: () => ipcRenderer.send('window:minimize'),
    maximize: () => ipcRenderer.send('window:maximize'),
    close: () => ipcRenderer.send('window:close'),
    setAlwaysOnTop: (value: boolean) =>
      ipcRenderer.send('window:always-on-top', value),
  },

  // Secure Storage (for API keys)
  storage: {
    get: (key: string) => ipcRenderer.invoke('storage:get', key),
    set: (key: string, value: string) =>
      ipcRenderer.invoke('storage:set', key, value),
    delete: (key: string) => ipcRenderer.invoke('storage:delete', key),
  },

  // Event Listeners
  on: {
    windowFocused: (callback: (focused: boolean) => void) => {
      ipcRenderer.on('window:focused', (_, focused) => callback(focused));
    },
    shortcutTriggered: (callback: (shortcut: string) => void) => {
      ipcRenderer.on('shortcut:triggered', (_, shortcut) => callback(shortcut));
    },
  },

  // Cleanup
  removeAllListeners: (channel: string) => {
    ipcRenderer.removeAllListeners(channel);
  },
});

// Type declarations for renderer
declare global {
  interface Window {
    electronAPI: {
      window: {
        minimize: () => void;
        maximize: () => void;
        close: () => void;
        setAlwaysOnTop: (value: boolean) => void;
      };
      storage: {
        get: (key: string) => Promise<string | null>;
        set: (key: string, value: string) => Promise<void>;
        delete: (key: string) => Promise<void>;
      };
      on: {
        windowFocused: (callback: (focused: boolean) => void) => void;
        shortcutTriggered: (callback: (shortcut: string) => void) => void;
      };
      removeAllListeners: (channel: string) => void;
    };
  }
}
```

### 2.5 Real-Time Data Flow

```
+-------------------+     +-------------------+     +-------------------+
|   AudioCapture    |     |   Transcription   |     |    LLM Service    |
|   (Backend)       |     |   (Backend)       |     |    (Backend)      |
+--------+----------+     +--------+----------+     +--------+----------+
         |                         |                         |
         | Audio chunks            | Text                    | Summary/Suggestion
         v                         v                         v
+--------+-------------------------+-------------------------+----------+
|                        WebSocket Manager (Backend)                     |
+--------+---------------------------------------------------------------+
         |
         | JSON Events
         v
+--------+---------------------------------------------------------------+
|                         WebSocket (Client)                              |
+--------+---------------------------------------------------------------+
         |
         | Parsed events
         v
+--------+---------------------------------------------------------------+
|                          Zustand Store                                  |
|  +----------------+  +----------------+  +----------------+            |
|  | transcriptSlice|  | summarySlice   |  | suggestionSlice|            |
|  +----------------+  +----------------+  +----------------+            |
+--------+---------------------------------------------------------------+
         |
         | React subscription
         v
+--------+---------------------------------------------------------------+
|                         React Components                                |
|  +----------------+  +----------------+  +----------------+            |
|  | TranscriptPanel|  | SummaryPanel   |  | SuggestionNotif|            |
|  +----------------+  +----------------+  +----------------+            |
+------------------------------------------------------------------------+
```

---

## 3. Backend Architecture

### 3.1 Current Backend Assessment

The existing backend (`backend/app/`) provides a solid foundation:

**Available Services**:
- `audio_capture.py` - Audio capture from virtual devices
- `transcription.py` - Whisper API integration
- `llm_service.py` - GPT integration (needs update for GPT-5 nano)
- `meeting_service.py` - Meeting orchestration pipeline
- `websocket_manager.py` - Real-time event broadcasting
- `context_service.py` - Document context retrieval
- `embedding_service.py` - Vector embeddings

**Recommended Updates**:

| Component | Change | Priority |
|-----------|--------|----------|
| `llm_service.py` | Update to GPT-5 nano model | P0 |
| `llm_service.py` | Add streaming response support | P0 |
| `llm_service.py` | Add reasoning_effort parameter | P1 |
| `meeting_service.py` | Add token tracking | P0 |
| `websocket_manager.py` | Add token_usage event | P1 |
| New: `token_service.py` | Token counting and management | P0 |
| New: `query_service.py` | Handle user queries with context | P0 |

### 3.2 Updated LLM Service Design

```python
# backend/app/services/llm_service.py (updated)

import openai
from typing import AsyncGenerator, List, Optional
import tiktoken
from app.config import settings

class LLMService:
    def __init__(self):
        self.client = openai.AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
        self.model = "gpt-5-nano"  # Updated to GPT-5 nano
        self.max_input_tokens = 272_000
        self.max_output_tokens = 128_000
        self.encoding = tiktoken.encoding_for_model("gpt-4")  # Approximate

    async def generate_summary_stream(
        self,
        transcript_text: str,
        reasoning_effort: str = "low"  # low/medium/high
    ) -> AsyncGenerator[str, None]:
        """Stream summary generation for lower perceived latency."""
        prompt = self._build_summary_prompt(transcript_text)

        response = await self.client.chat.completions.create(
            model=self.model,
            messages=[
                {"role": "system", "content": SUMMARY_SYSTEM_PROMPT},
                {"role": "user", "content": prompt}
            ],
            temperature=0.5,
            max_tokens=500,
            stream=True,
            extra_body={"reasoning_effort": reasoning_effort}
        )

        async for chunk in response:
            if chunk.choices[0].delta.content:
                yield chunk.choices[0].delta.content

    async def answer_query_stream(
        self,
        question: str,
        transcript_context: str,
        summary_context: str,
        document_context: List[str],
        reasoning_effort: str = "medium"
    ) -> AsyncGenerator[str, None]:
        """Stream answer to user query with full context."""
        context = self._build_query_context(
            transcript_context,
            summary_context,
            document_context
        )

        response = await self.client.chat.completions.create(
            model=self.model,
            messages=[
                {"role": "system", "content": QUERY_SYSTEM_PROMPT},
                {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {question}"}
            ],
            temperature=0.7,
            max_tokens=1000,
            stream=True,
            extra_body={"reasoning_effort": reasoning_effort}
        )

        async for chunk in response:
            if chunk.choices[0].delta.content:
                yield chunk.choices[0].delta.content

    def count_tokens(self, text: str) -> int:
        """Count tokens in text using tiktoken."""
        return len(self.encoding.encode(text))

    def build_context_within_limit(
        self,
        transcripts: List[str],
        summaries: List[str],
        max_tokens: int = 200_000
    ) -> tuple[str, str]:
        """Build context that fits within token limit, prioritizing recent content."""
        # Always include all summaries (more valuable, smaller)
        summary_text = "\n\n".join(summaries)
        summary_tokens = self.count_tokens(summary_text)

        # Calculate remaining budget for transcripts
        remaining_tokens = max_tokens - summary_tokens - 5000  # Buffer

        # Build transcript from most recent, going backwards
        transcript_chunks = []
        current_tokens = 0

        for transcript in reversed(transcripts):
            chunk_tokens = self.count_tokens(transcript)
            if current_tokens + chunk_tokens > remaining_tokens:
                break
            transcript_chunks.insert(0, transcript)
            current_tokens += chunk_tokens

        transcript_text = "\n".join(transcript_chunks)
        return transcript_text, summary_text
```

### 3.3 New Query Service

```python
# backend/app/services/query_service.py (new)

from typing import AsyncGenerator, Optional
from datetime import datetime, timedelta
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, desc

from app.services.llm_service import LLMService
from app.services.context_service import ContextService
from app.models.transcript import Transcript
from app.models.summary import Summary

class QueryService:
    def __init__(self, db: AsyncSession):
        self.db = db
        self.llm = LLMService()
        self.context_service = ContextService(db)

    async def process_query(
        self,
        meeting_id: str,
        question: str,
        include_documents: bool = True
    ) -> AsyncGenerator[str, None]:
        """Process user query and stream response."""

        # 1. Get recent transcripts (last 30 minutes)
        cutoff = datetime.utcnow() - timedelta(minutes=30)
        result = await self.db.execute(
            select(Transcript)
            .where(Transcript.meeting_id == meeting_id)
            .where(Transcript.created_at >= cutoff)
            .order_by(Transcript.created_at)
        )
        transcripts = [t.text for t in result.scalars().all()]

        # 2. Get all summaries for this meeting
        result = await self.db.execute(
            select(Summary)
            .where(Summary.meeting_id == meeting_id)
            .order_by(Summary.created_at)
        )
        summaries = [s.content for s in result.scalars().all()]

        # 3. Get relevant document context (if enabled)
        document_chunks = []
        if include_documents:
            document_chunks = await self.context_service.retrieve_relevant_context(
                meeting_id, question
            )

        # 4. Build context within token limits
        transcript_context, summary_context = self.llm.build_context_within_limit(
            transcripts, summaries
        )

        # 5. Stream response
        async for token in self.llm.answer_query_stream(
            question=question,
            transcript_context=transcript_context,
            summary_context=summary_context,
            document_context=document_chunks,
            reasoning_effort="medium"
        ):
            yield token

    async def get_30s_recap(self, meeting_id: str) -> str:
        """Generate quick recap of last 30 seconds."""
        cutoff = datetime.utcnow() - timedelta(seconds=30)
        result = await self.db.execute(
            select(Transcript)
            .where(Transcript.meeting_id == meeting_id)
            .where(Transcript.created_at >= cutoff)
            .order_by(Transcript.created_at)
        )
        recent_text = " ".join([t.text for t in result.scalars().all()])

        if not recent_text.strip():
            return "No recent conversation to recap."

        # Quick, low-effort recap
        recap_parts = []
        async for token in self.llm.generate_summary_stream(
            recent_text, reasoning_effort="low"
        ):
            recap_parts.append(token)

        return "".join(recap_parts)
```

### 3.4 Token Service

```python
# backend/app/services/token_service.py (new)

import tiktoken
from typing import Dict
from datetime import datetime
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func

from app.models.transcript import Transcript
from app.models.summary import Summary

class TokenService:
    def __init__(self):
        self.encoding = tiktoken.encoding_for_model("gpt-4")
        self.max_input = 272_000

    def count_tokens(self, text: str) -> int:
        """Count tokens in text."""
        if not text:
            return 0
        return len(self.encoding.encode(text))

    async def get_meeting_token_usage(
        self,
        db: AsyncSession,
        meeting_id: str
    ) -> Dict[str, int]:
        """Calculate current token usage for a meeting."""

        # Count transcript tokens
        result = await db.execute(
            select(Transcript.text)
            .where(Transcript.meeting_id == meeting_id)
        )
        transcripts = result.scalars().all()
        transcript_tokens = sum(self.count_tokens(t) for t in transcripts)

        # Count summary tokens
        result = await db.execute(
            select(Summary.content)
            .where(Summary.meeting_id == meeting_id)
        )
        summaries = result.scalars().all()
        summary_tokens = sum(self.count_tokens(s) for s in summaries)

        total = transcript_tokens + summary_tokens

        return {
            "transcript_tokens": transcript_tokens,
            "summary_tokens": summary_tokens,
            "total_tokens": total,
            "max_tokens": self.max_input,
            "percentage": round((total / self.max_input) * 100, 1)
        }
```

---

## 4. Database Architecture

### 4.1 Schema Diagram

```
+------------------+       +------------------+       +------------------+
|     meetings     |       |   transcripts    |       |    summaries     |
+------------------+       +------------------+       +------------------+
| id (UUID) PK     |<------| meeting_id FK    |       | id (INT) PK      |
| title            |       | id (UUID) PK     |<------| meeting_id FK    |
| start_time       |       | text             |       | content          |
| end_time         |       | timestamp        |       | start_time       |
| platform         |       | speaker          |       | end_time         |
| status           |       | created_at       |       | created_at       |
+------------------+       +------------------+       +------------------+
        |
        |                  +------------------+       +------------------+
        |                  |   suggestions    |       | context_documents|
        |                  +------------------+       +------------------+
        +----------------->| meeting_id FK    |       | id (INT) PK      |
        |                  | id (INT) PK      |       | meeting_id FK    |
        |                  | question         |<------| filename         |
        |                  | suggestions_json |       | file_type        |
        |                  | context_used     |       | file_path        |
        |                  | created_at       |       | created_at       |
        |                  +------------------+       +------------------+
        |                                                     |
        |                  +------------------+               |
        |                  |  token_usage     |       +-------v----------+
        |                  +------------------+       |  context_chunks  |
        +----------------->| meeting_id FK    |       +------------------+
                           | id (INT) PK      |       | id (INT) PK      |
                           | input_tokens     |       | document_id FK   |
                           | output_tokens    |       | chunk_text       |
                           | source           |       | chunk_index      |
                           | created_at       |       | embedding VECTOR |
                           +------------------+       | metadata_json    |
                                                      +------------------+

+------------------+
|  user_settings   |
+------------------+
| id (INT) PK      |
| summary_interval |
| auto_suggestion  |
| always_on_top    |
| window_bounds    |
| updated_at       |
+------------------+
```

### 4.2 New Migrations Required

```python
# backend/alembic/versions/xxx_add_token_usage.py

"""Add token usage tracking

Revision ID: xxx
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID, JSONB

def upgrade():
    # Token usage table
    op.create_table(
        'token_usage',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('meeting_id', UUID(as_uuid=True),
                  sa.ForeignKey('meetings.id', ondelete='CASCADE'),
                  nullable=False),
        sa.Column('input_tokens', sa.Integer(), nullable=False, default=0),
        sa.Column('output_tokens', sa.Integer(), nullable=False, default=0),
        sa.Column('source', sa.String(50), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True),
                  server_default=sa.func.now()),
    )
    op.create_index('idx_token_usage_meeting', 'token_usage', ['meeting_id'])

    # User settings table
    op.create_table(
        'user_settings',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('summary_interval', sa.Integer(), default=60),
        sa.Column('auto_suggestion', sa.Boolean(), default=True),
        sa.Column('always_on_top', sa.Boolean(), default=False),
        sa.Column('window_bounds', JSONB, nullable=True),
        sa.Column('updated_at', sa.DateTime(timezone=True),
                  server_default=sa.func.now()),
    )

def downgrade():
    op.drop_table('user_settings')
    op.drop_index('idx_token_usage_meeting')
    op.drop_table('token_usage')
```

---

## 5. Integration Patterns

### 5.1 Backend-Frontend Integration

**Option A: Direct HTTP/WebSocket (Recommended)**
```
Electron Renderer <--HTTP/WS--> FastAPI Backend <--> Database
```

**Rationale**:
- Reuses existing FastAPI backend
- Single source of truth for business logic
- Easier testing and debugging
- Backend can be run separately for development

**Configuration**:
```typescript
// frontend/src/services/api.ts
const API_BASE = import.meta.env.VITE_API_URL || 'http://localhost:8000';
const WS_BASE = import.meta.env.VITE_WS_URL || 'ws://localhost:8000';
```

### 5.2 Deployment Architecture

**Development**:
```
[Electron App] --> [FastAPI @ localhost:8000] --> [PostgreSQL @ localhost:5432]
```

**Production (Standalone)**:
```
[Electron App]
      |
      +--> [Bundled FastAPI (via pyinstaller or subprocess)]
      |
      +--> [SQLite or bundled PostgreSQL]
```

**Production (Server-backed)**:
```
[Electron App]
      |
      +--> [FastAPI @ api.macapy.io]
      |
      +--> [PostgreSQL @ cloud DB]
```

### 5.3 Audio Capture Integration

The existing `AudioCaptureService` handles audio through pyaudiowpatch. For the Electron frontend:

1. **Backend maintains audio capture** (no change)
2. **Frontend receives audio level updates** via WebSocket
3. **No audio streaming to frontend** (reduces latency and bandwidth)

```python
# Enhanced websocket event for audio feedback
{
    "type": "audio_level",
    "data": {
        "level": 0.45,  # RMS level 0-1
        "is_speaking": true,  # Above silence threshold
        "timestamp": "2025-11-25T10:30:45Z"
    }
}
```

---

## 6. Security Architecture

### 6.1 API Key Storage

```typescript
// electron/main/storage.ts

import { safeStorage } from 'electron';
import Store from 'electron-store';

const store = new Store();

export const secureStorage = {
  async setApiKey(key: string): Promise<void> {
    if (safeStorage.isEncryptionAvailable()) {
      const encrypted = safeStorage.encryptString(key);
      store.set('openai_api_key', encrypted.toString('base64'));
    } else {
      // Fallback: store in plain text (warn user)
      store.set('openai_api_key_plain', key);
    }
  },

  async getApiKey(): Promise<string | null> {
    const encrypted = store.get('openai_api_key') as string;
    if (encrypted && safeStorage.isEncryptionAvailable()) {
      const buffer = Buffer.from(encrypted, 'base64');
      return safeStorage.decryptString(buffer);
    }
    return store.get('openai_api_key_plain') as string || null;
  },

  async deleteApiKey(): Promise<void> {
    store.delete('openai_api_key');
    store.delete('openai_api_key_plain');
  }
};
```

### 6.2 Electron Security Configuration

```typescript
// electron/main/window.ts

import { BrowserWindow } from 'electron';

export function createMainWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 600,
    height: 800,
    minWidth: 400,
    minHeight: 500,
    frame: false,  // Custom title bar
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, '../preload/index.js'),
      sandbox: true,
    },
  });

  // Security headers
  win.webContents.session.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [
          "default-src 'self'",
          "script-src 'self'",
          "style-src 'self' 'unsafe-inline'",
          "connect-src 'self' http://localhost:8000 ws://localhost:8000",
          "img-src 'self' data:",
        ].join('; '),
      },
    });
  });

  return win;
}
```

---

## 7. Performance Optimization

### 7.1 Frontend Optimizations

**Virtualized Transcript List**:
```typescript
// Using react-window for large lists
import { FixedSizeList } from 'react-window';

<FixedSizeList
  height={400}
  width="100%"
  itemCount={transcripts.length}
  itemSize={60}
>
  {({ index, style }) => (
    <TranscriptSegment
      key={transcripts[index].id}
      segment={transcripts[index]}
      style={style}
    />
  )}
</FixedSizeList>
```

**Debounced Updates**:
```typescript
// Debounce token usage updates
const updateTokens = useMemo(
  () => debounce((count: number) => tokenActions.update(count), 5000),
  []
);
```

### 7.2 Backend Optimizations

**Connection Pooling**:
```python
# backend/app/db/session.py
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker

engine = create_async_engine(
    settings.DATABASE_URL,
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,
)
```

**Async Batch Operations**:
```python
# Batch transcript inserts
async def batch_insert_transcripts(
    db: AsyncSession,
    transcripts: List[dict]
) -> None:
    await db.execute(
        Transcript.__table__.insert(),
        transcripts
    )
    await db.commit()
```

---

## 8. Testing Strategy

### 8.1 Frontend Testing

```typescript
// Example: TranscriptPanel.test.tsx
import { render, screen } from '@testing-library/react';
import { TranscriptPanel } from './TranscriptPanel';

describe('TranscriptPanel', () => {
  it('renders transcript segments', () => {
    const segments = [
      { id: '1', text: 'Hello', timestamp: '10:00:00', speaker: 'system' },
      { id: '2', text: 'Hi there', timestamp: '10:00:05', speaker: 'user' },
    ];

    render(<TranscriptPanel segments={segments} isAutoScroll={true} />);

    expect(screen.getByText('Hello')).toBeInTheDocument();
    expect(screen.getByText('Hi there')).toBeInTheDocument();
  });

  it('disables auto-scroll on user scroll', () => {
    // Test implementation
  });
});
```

### 8.2 Backend Testing

```python
# backend/tests/test_query_service.py
import pytest
from app.services.query_service import QueryService

@pytest.mark.asyncio
async def test_process_query(db_session, mock_llm):
    service = QueryService(db_session)

    response_parts = []
    async for token in service.process_query(
        meeting_id="test-meeting",
        question="What was discussed?"
    ):
        response_parts.append(token)

    response = "".join(response_parts)
    assert len(response) > 0
```

### 8.3 E2E Testing

```typescript
// e2e/meeting-flow.spec.ts (Playwright)
import { test, expect } from '@playwright/test';

test('complete meeting flow', async ({ page }) => {
  await page.goto('/');

  // Start meeting
  await page.fill('[data-testid="meeting-title"]', 'Test Meeting');
  await page.click('[data-testid="start-meeting"]');

  // Wait for recording indicator
  await expect(page.locator('[data-testid="recording-status"]')).toBeVisible();

  // Simulate transcript update (via mock WebSocket)
  // ...

  // End meeting
  await page.click('[data-testid="end-meeting"]');
  await page.click('[data-testid="confirm-end"]');

  // Verify meeting saved
  await page.click('[data-testid="history-tab"]');
  await expect(page.locator('text=Test Meeting')).toBeVisible();
});
```

---

## 9. Build and Deployment

### 9.1 Electron Builder Configuration

```yaml
# electron-builder.yml
appId: io.macapy.app
productName: macapy
directories:
  output: dist
  buildResources: build
files:
  - electron/dist/**/*
  - dist/**/*
  - package.json
win:
  target:
    - target: nsis
      arch:
        - x64
  icon: build/icon.ico
nsis:
  oneClick: false
  allowToChangeInstallationDirectory: true
  createDesktopShortcut: true
  createStartMenuShortcut: true
mac:
  target:
    - target: dmg
      arch:
        - x64
        - arm64
  icon: build/icon.icns
  hardenedRuntime: true
  gatekeeperAssess: false
publish:
  provider: github
  releaseType: release
```

### 9.2 Build Scripts

```json
// package.json
{
  "scripts": {
    "dev": "vite",
    "dev:electron": "concurrently \"vite\" \"wait-on tcp:3000 && electron .\"",
    "build": "vite build && tsc -p electron/tsconfig.json",
    "build:win": "npm run build && electron-builder --win",
    "build:mac": "npm run build && electron-builder --mac",
    "build:all": "npm run build && electron-builder --win --mac",
    "test": "vitest",
    "test:e2e": "playwright test",
    "lint": "eslint src electron --ext .ts,.tsx"
  }
}
```

---

## 10. Implementation Roadmap

### Phase 1: Foundation (Week 1-2)

- [ ] Initialize Electron + React + TypeScript project
- [ ] Configure Vite for Electron development
- [ ] Set up Zustand store with initial slices
- [ ] Create IPC bridge and preload scripts
- [ ] Implement custom title bar
- [ ] Basic window management (min/max/close)

### Phase 2: Backend Integration (Week 2-3)

- [ ] Update LLMService for GPT-5 nano
- [ ] Implement QueryService
- [ ] Implement TokenService
- [ ] Add new API endpoints (query, recap)
- [ ] WebSocket enhancements (token usage events)
- [ ] Database migrations

### Phase 3: Core UI (Week 3-4)

- [ ] MeetingControls component
- [ ] TranscriptPanel with virtualization
- [ ] SummaryPanel component
- [ ] QueryInput and response display
- [ ] WebSocket connection in frontend
- [ ] Real-time state updates

### Phase 4: AI Features (Week 4-5)

- [ ] Question detection integration
- [ ] SuggestionNotification component
- [ ] 30-second recap feature
- [ ] Token usage display
- [ ] Context window management

### Phase 5: History & Polish (Week 5-6)

- [ ] Meeting history dashboard
- [ ] Search functionality
- [ ] Keyboard shortcuts
- [ ] System tray integration
- [ ] Auto-update setup
- [ ] Performance optimization

### Phase 6: Testing & Release (Week 6-8)

- [ ] Unit tests (>80% coverage)
- [ ] Integration tests
- [ ] E2E tests
- [ ] Performance testing
- [ ] Security audit
- [ ] Documentation
- [ ] Windows installer build
- [ ] Beta release

---

## Appendix A: Technology Decisions

| Decision | Choice | Alternatives Considered | Rationale |
|----------|--------|------------------------|-----------|
| UI Framework | React | Vue, Svelte | Ecosystem maturity, TypeScript support |
| State Management | Zustand | Redux, MobX, Jotai | Simplicity, good real-time support |
| Styling | TailwindCSS | styled-components, CSS modules | Rapid development, design system |
| WebSocket | Native | Socket.IO | Lighter weight, no extra features needed |
| Build Tool | Vite | Webpack, esbuild | Speed, excellent Electron support |
| Backend | Keep FastAPI | Embed Node.js | Existing code, Python ML ecosystem |

---

## Appendix B: File Size Estimates

| Component | Estimated Size |
|-----------|---------------|
| Electron binary | ~150 MB |
| React bundle | ~500 KB |
| Assets | ~5 MB |
| **Total installed** | **~160 MB** |

---

## Appendix C: External Dependencies

### Frontend (package.json)

```json
{
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "zustand": "^4.4.0",
    "@radix-ui/react-dialog": "^1.0.0",
    "@radix-ui/react-dropdown-menu": "^2.0.0",
    "react-window": "^1.8.0",
    "clsx": "^2.0.0"
  },
  "devDependencies": {
    "electron": "^28.0.0",
    "electron-builder": "^24.0.0",
    "vite": "^5.0.0",
    "@vitejs/plugin-react": "^4.0.0",
    "typescript": "^5.0.0",
    "tailwindcss": "^3.4.0",
    "@types/react": "^18.2.0",
    "vitest": "^1.0.0",
    "@playwright/test": "^1.40.0"
  }
}
```

### Backend (additions to requirements.txt)

```
tiktoken==0.5.0  # Token counting
```
