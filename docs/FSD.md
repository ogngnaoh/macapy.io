# Functional Specification Document (FSD)
# macapy.io - Agentic Meeting Assistant

**Version**: 1.0
**Last Updated**: 2025-11-25
**Status**: Draft - Pre-Implementation

---

## 1. Overview

This document provides detailed functional specifications for the macapy.io Electron desktop application. It defines the exact behavior, user flows, component specifications, and API contracts required for implementation.

---

## 2. User Flows

### 2.1 Start Meeting Flow

```
[User opens app]
    |
    v
[Main Dashboard displayed]
    |
    v
[User enters meeting title (optional)]
    |
    v
[User clicks "Start Meeting"]
    |
    v
[System: Create meeting record in DB]
    |
    v
[System: Initialize audio capture]
    |
    v
[System: Establish WebSocket connection]
    |
    v
[UI: Update status to "Recording"]
    |
    v
[Audio capture begins -> Transcription pipeline active]
```

**Error States**:
- Audio device not found -> Show setup guide modal
- API connection failed -> Show retry option with error message
- Database error -> Show "Unable to start meeting" with details

### 2.2 Active Meeting Flow

```
[Audio captured (1s chunks)]
    |
    +---> [Whisper API transcription]
    |         |
    |         v
    |     [WebSocket: transcript_update event]
    |         |
    |         v
    |     [UI: Append to transcript panel]
    |
    +---> [Every 60s: Summary generation]
    |         |
    |         v
    |     [GPT-5 nano: Generate summary]
    |         |
    |         v
    |     [WebSocket: summary_update event]
    |         |
    |         v
    |     [UI: Add to summaries panel]
    |
    +---> [Question detection (per transcript)]
              |
              v
          [If question detected]
              |
              v
          [Retrieve document context]
              |
              v
          [GPT-5 nano: Generate suggestions]
              |
              v
          [WebSocket: suggestion_generated event]
              |
              v
          [UI: Show suggestion notification]
```

### 2.3 User Query Flow

```
[User types question in input field]
    |
    v
[User presses Enter or clicks Send]
    |
    v
[UI: Show loading state]
    |
    v
[Build context: recent transcript + summaries]
    |
    v
[GPT-5 nano API call with context + question]
    |
    v
[Stream response tokens]
    |
    v
[UI: Display response in conversation area]
    |
    v
[Track token usage]
```

### 2.4 End Meeting Flow

```
[User clicks "End Meeting"]
    |
    v
[Show confirmation dialog: "End this meeting?"]
    |
    +---> [Cancel] -> Return to active meeting
    |
    v [Confirm]
    |
[System: Stop audio capture]
    |
    v
[System: Generate final summary]
    |
    v
[System: Update meeting status to COMPLETED]
    |
    v
[UI: Show meeting summary view]
    |
    v
[Meeting added to history]
```

### 2.5 Meeting History Flow

```
[User clicks History icon or Ctrl+H]
    |
    v
[Navigate to History Dashboard]
    |
    v
[Load paginated meeting list]
    |
    v
[User selects a meeting]
    |
    v
[Display full transcript + summaries]
    |
    +---> [Search: Filter by keyword]
    |
    +---> [Delete: Confirm and remove]
    |
    +---> [Export: Generate markdown file]
```

---

## 3. Component Specifications

### 3.1 Main Window Components

#### 3.1.1 TitleBar Component

**Purpose**: Custom title bar with app branding and window controls

**Props**:
```typescript
interface TitleBarProps {
  title: string;
  isAlwaysOnTop: boolean;
  onMinimize: () => void;
  onMaximize: () => void;
  onClose: () => void;
  onToggleAlwaysOnTop: () => void;
}
```

**Behavior**:
- Draggable for window repositioning
- Double-click toggles maximize
- Custom styled window controls (minimize, maximize, close)
- Always-on-top toggle indicator

---

#### 3.1.2 MeetingControls Component

**Purpose**: Start/stop meeting and display status

**Props**:
```typescript
interface MeetingControlsProps {
  meetingId: string | null;
  meetingTitle: string;
  status: 'idle' | 'recording' | 'processing' | 'error';
  duration: number; // seconds
  onTitleChange: (title: string) => void;
  onStart: () => void;
  onStop: () => void;
}
```

**States**:
| State | Button Text | Button Style | Status Text |
|-------|-------------|--------------|-------------|
| idle | "Start Meeting" | Primary (blue) | "Ready" |
| recording | "End Meeting" | Danger (red) | "Recording 00:23:45" |
| processing | "Processing..." | Disabled | "Processing..." |
| error | "Retry" | Warning (yellow) | "Error: {message}" |

**Behavior**:
- Title input editable only when idle
- Duration timer updates every second when recording
- Visual pulse animation on recording status

---

#### 3.1.3 TranscriptPanel Component

**Purpose**: Display real-time scrolling transcript

**Props**:
```typescript
interface TranscriptPanelProps {
  segments: TranscriptSegment[];
  isAutoScroll: boolean;
  onScrollStateChange: (autoScroll: boolean) => void;
}

interface TranscriptSegment {
  id: string;
  text: string;
  timestamp: string;
  speaker: 'system' | 'user' | 'unknown';
  createdAt: Date;
}
```

**Behavior**:
- Auto-scroll enabled by default
- User scroll disables auto-scroll (indicator shown)
- Click "Resume auto-scroll" to re-enable
- Timestamps formatted as HH:MM:SS
- Different background tint for system vs. user audio
- Maximum 500 segments rendered (virtualized)

**Styling**:
```css
.segment-system { border-left: 2px solid #4FC3F7; }
.segment-user { border-left: 2px solid #81C784; }
.segment-unknown { border-left: 2px solid #9E9E9E; }
```

---

#### 3.1.4 SummaryPanel Component

**Purpose**: Display rolling summaries with timestamps

**Props**:
```typescript
interface SummaryPanelProps {
  summaries: Summary[];
  onSummarizeNow: () => void;
  isLoading: boolean;
}

interface Summary {
  id: string;
  content: string;
  startTime: Date;
  endTime: Date;
  createdAt: Date;
}
```

**Behavior**:
- Newest summary at top
- Collapsible older summaries
- "Summarize Now" button with cooldown (10s)
- Loading spinner during generation
- Click summary to scroll transcript to that time range

---

#### 3.1.5 QueryInput Component

**Purpose**: User input for AI questions

**Props**:
```typescript
interface QueryInputProps {
  value: string;
  onChange: (value: string) => void;
  onSend: () => void;
  onRecap: () => void;
  isLoading: boolean;
  disabled: boolean;
}
```

**Behavior**:
- Enter key sends (Shift+Enter for newline)
- Clear input after successful send
- Disabled when no active meeting
- Character limit: 2000
- "30s" button triggers recap

**Visual States**:
- Default: Placeholder "Ask about this meeting..."
- Focus: Blue border highlight
- Loading: Spinner replaces send icon
- Disabled: Grayed out with "Start a meeting to ask questions"

---

#### 3.1.6 QueryResponse Component

**Purpose**: Display AI responses in conversation format

**Props**:
```typescript
interface QueryResponseProps {
  exchanges: QueryExchange[];
}

interface QueryExchange {
  id: string;
  question: string;
  response: string;
  timestamp: Date;
  tokensUsed: number;
}
```

**Behavior**:
- Most recent exchange expanded, older collapsed
- Click to expand/collapse
- Copy response button
- Show tokens used per response

---

#### 3.1.7 SuggestionNotification Component

**Purpose**: Display auto-generated response suggestions

**Props**:
```typescript
interface SuggestionNotificationProps {
  suggestion: SuggestionData | null;
  onCopy: (text: string) => void;
  onDismiss: () => void;
  onUsed: (suggestionId: string, index: number) => void;
}

interface SuggestionData {
  id: string;
  question: string;
  suggestions: string[];
  createdAt: Date;
}
```

**Behavior**:
- Slides in from bottom when new suggestion
- Auto-dismiss after 30 seconds
- Manual dismiss via X button
- Click suggestion to copy to clipboard
- "Used" tracking when suggestion clicked
- Queue multiple suggestions (show one at a time)

**Animation**:
- Entry: Slide up 300ms ease-out
- Exit: Fade out 200ms
- Pulse border animation on new suggestion

---

#### 3.1.8 TokenUsageIndicator Component

**Purpose**: Display current context window usage

**Props**:
```typescript
interface TokenUsageIndicatorProps {
  currentTokens: number;
  maxTokens: number; // 272,000 for GPT-5 nano input
  warningThreshold: number; // default: 0.8 (80%)
}
```

**Behavior**:
- Progress bar visualization
- Color coding:
  - Green: < 60%
  - Yellow: 60-80%
  - Red: > 80%
- Tooltip shows exact numbers
- Flash warning when threshold exceeded

---

### 3.2 History Dashboard Components

#### 3.2.1 MeetingList Component

**Props**:
```typescript
interface MeetingListProps {
  meetings: MeetingListItem[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  onDelete: (id: string) => void;
  onSearch: (query: string) => void;
  searchQuery: string;
  isLoading: boolean;
}

interface MeetingListItem {
  id: string;
  title: string;
  startTime: Date;
  endTime: Date | null;
  duration: number;
  summaryCount: number;
  previewText: string;
}
```

**Behavior**:
- Virtualized list for performance
- Hover to show delete button
- Search filters by title and content
- Sort by date (newest first)
- Pagination: 20 items per page

---

#### 3.2.2 MeetingDetail Component

**Props**:
```typescript
interface MeetingDetailProps {
  meeting: MeetingFull | null;
  onExport: (format: 'txt' | 'md') => void;
  onBack: () => void;
}

interface MeetingFull {
  id: string;
  title: string;
  startTime: Date;
  endTime: Date;
  duration: number;
  transcripts: TranscriptSegment[];
  summaries: Summary[];
}
```

**Behavior**:
- Tab navigation: Transcript | Summaries | Full
- Ctrl+F to search within content
- Export button with format dropdown

---

## 4. API Contracts

### 4.1 REST API Endpoints

#### 4.1.1 Meetings API

**Create Meeting**
```
POST /api/meetings

Request Body:
{
  "title": "Interview @ Google",
  "platform": "google_meet" // optional
}

Response (201):
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "title": "Interview @ Google",
  "platform": "google_meet",
  "status": "PENDING",
  "start_time": "2025-11-25T10:30:00Z",
  "end_time": null
}
```

**Update Meeting Status**
```
PATCH /api/meetings/{meeting_id}

Request Body:
{
  "status": "IN_PROGRESS" // or "COMPLETED"
}

Response (200):
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "title": "Interview @ Google",
  "status": "IN_PROGRESS",
  "start_time": "2025-11-25T10:30:00Z",
  "end_time": null
}

Side Effects:
- IN_PROGRESS: Starts audio capture and transcription pipeline
- COMPLETED: Stops pipeline, generates final summary
```

**Get Meeting**
```
GET /api/meetings/{meeting_id}

Response (200):
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "title": "Interview @ Google",
  "status": "COMPLETED",
  "start_time": "2025-11-25T10:30:00Z",
  "end_time": "2025-11-25T11:15:00Z"
}
```

**List Meetings**
```
GET /api/meetings?skip=0&limit=20

Response (200):
[
  {
    "id": "...",
    "title": "Interview @ Google",
    "status": "COMPLETED",
    "start_time": "2025-11-25T10:30:00Z",
    "end_time": "2025-11-25T11:15:00Z"
  },
  ...
]
```

**Delete Meeting**
```
DELETE /api/meetings/{meeting_id}

Response (200):
{
  "id": "...",
  "title": "Interview @ Google",
  "deleted": true
}
```

---

#### 4.1.2 Transcripts API

**Get Transcripts for Meeting**
```
GET /api/meetings/{meeting_id}/transcripts?skip=0&limit=100

Response (200):
{
  "items": [
    {
      "id": "...",
      "meeting_id": "550e8400-...",
      "text": "Welcome to the interview.",
      "timestamp": 0.0,
      "speaker": "unknown",
      "created_at": "2025-11-25T10:30:05Z"
    },
    ...
  ],
  "total": 342,
  "skip": 0,
  "limit": 100
}
```

---

#### 4.1.3 Summaries API

**Get Summaries for Meeting**
```
GET /api/meetings/{meeting_id}/summaries

Response (200):
[
  {
    "id": 1,
    "meeting_id": "550e8400-...",
    "content": "- Discussed system design experience\n- Action: Follow up on scaling questions",
    "start_time": "2025-11-25T10:30:00Z",
    "end_time": "2025-11-25T10:31:00Z",
    "created_at": "2025-11-25T10:31:05Z"
  },
  ...
]
```

**Trigger Manual Summary**
```
POST /api/meetings/{meeting_id}/summaries/generate

Response (202):
{
  "status": "generating",
  "estimated_time": 10
}

// Summary delivered via WebSocket when ready
```

---

#### 4.1.4 AI Query API

**Submit Query**
```
POST /api/ai/query

Request Body:
{
  "meeting_id": "550e8400-...",
  "question": "What were the main topics discussed?",
  "include_documents": true
}

Response (200) - Streaming:
data: {"type": "start", "query_id": "..."}
data: {"type": "token", "content": "The"}
data: {"type": "token", "content": " main"}
data: {"type": "token", "content": " topics"}
...
data: {"type": "done", "tokens_used": 1234}
```

**Get 30-Second Recap**
```
POST /api/ai/recap

Request Body:
{
  "meeting_id": "550e8400-..."
}

Response (200):
{
  "recap": "In the last 30 seconds, the interviewer asked about distributed systems experience. You mentioned working on a microservices migration project."
}
```

---

### 4.2 WebSocket Events

#### 4.2.1 Connection

```
WS /ws/{meeting_id}

// Client sends on connect (handled automatically by server)
// Server confirms connection:
{
  "type": "connected",
  "meeting_id": "550e8400-...",
  "timestamp": "2025-11-25T10:30:00Z"
}
```

#### 4.2.2 Server -> Client Events

**Transcript Update**
```json
{
  "type": "transcript_update",
  "data": {
    "id": "transcript-uuid",
    "text": "Tell me about your experience with distributed systems.",
    "timestamp": 45.5,
    "speaker": "unknown",
    "created_at": "2025-11-25T10:30:45Z"
  }
}
```

**Summary Update**
```json
{
  "type": "summary_update",
  "data": {
    "id": 1,
    "content": "- Discussed distributed systems experience\n- Mentioned microservices migration project",
    "start_time": "2025-11-25T10:30:00Z",
    "end_time": "2025-11-25T10:31:00Z",
    "created_at": "2025-11-25T10:31:05Z"
  }
}
```

**Suggestion Generated**
```json
{
  "type": "suggestion_new",
  "data": {
    "id": 1,
    "question": "Tell me about your experience with distributed systems?",
    "suggestions": [
      "I led a microservices migration at my previous company, breaking down a monolith into 12 services...",
      "My experience includes designing event-driven architectures using Kafka...",
      "I've worked extensively with distributed databases, particularly Cassandra for high-throughput writes..."
    ],
    "created_at": "2025-11-25T10:30:50Z"
  }
}
```

**Audio Level**
```json
{
  "type": "audio_level",
  "data": {
    "level": 0.45,
    "timestamp": "2025-11-25T10:30:45Z"
  }
}
```

**Error**
```json
{
  "type": "error",
  "data": {
    "code": "TRANSCRIPTION_FAILED",
    "message": "Failed to transcribe audio chunk",
    "recoverable": true
  }
}
```

**Token Usage Update**
```json
{
  "type": "token_usage",
  "data": {
    "current_tokens": 45230,
    "max_tokens": 272000,
    "percentage": 16.6
  }
}
```

#### 4.2.3 Client -> Server Events

**Mark Suggestion Used**
```json
{
  "type": "suggestion_used",
  "data": {
    "suggestion_id": 1,
    "option_index": 0
  }
}
```

---

## 5. Data Models

### 5.1 Frontend State (Zustand Store)

```typescript
interface AppState {
  // Meeting State
  currentMeeting: Meeting | null;
  meetingStatus: 'idle' | 'recording' | 'processing' | 'error';
  meetingDuration: number;

  // Transcript State
  transcripts: TranscriptSegment[];
  isAutoScroll: boolean;

  // Summary State
  summaries: Summary[];
  isSummarizing: boolean;

  // Query State
  queryInput: string;
  queryExchanges: QueryExchange[];
  isQuerying: boolean;

  // Suggestion State
  pendingSuggestions: SuggestionData[];
  activeSuggestion: SuggestionData | null;

  // Token State
  currentTokens: number;
  tokenWarningShown: boolean;

  // UI State
  activeView: 'meeting' | 'history';
  isAlwaysOnTop: boolean;

  // History State
  meetingHistory: MeetingListItem[];
  selectedHistoryMeeting: MeetingFull | null;
  historySearchQuery: string;

  // Actions
  startMeeting: (title: string) => Promise<void>;
  endMeeting: () => Promise<void>;
  sendQuery: (question: string) => Promise<void>;
  getRecap: () => Promise<void>;
  dismissSuggestion: () => void;
  loadHistory: () => Promise<void>;
  selectHistoryMeeting: (id: string) => Promise<void>;
  deleteMeeting: (id: string) => Promise<void>;
}
```

### 5.2 Database Schema Updates

The existing backend schema covers most needs. New/updated models:

**TokenUsage Table** (New)
```sql
CREATE TABLE token_usage (
  id SERIAL PRIMARY KEY,
  meeting_id UUID REFERENCES meetings(id) ON DELETE CASCADE,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  source VARCHAR(50) NOT NULL, -- 'transcription', 'summary', 'query', 'suggestion'
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_token_usage_meeting ON token_usage(meeting_id);
```

**Settings Table** (New)
```sql
CREATE TABLE user_settings (
  id SERIAL PRIMARY KEY,
  summary_interval INTEGER DEFAULT 60, -- seconds
  auto_suggestion BOOLEAN DEFAULT true,
  always_on_top BOOLEAN DEFAULT false,
  window_bounds JSONB, -- {x, y, width, height}
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
```

---

## 6. Error Handling

### 6.1 Error Categories

| Category | Handling Strategy | User Feedback |
|----------|-------------------|---------------|
| Network | Retry with backoff | Toast: "Connection issue. Retrying..." |
| API Rate Limit | Queue and retry | Toast: "API busy. Request queued." |
| Audio Device | Guide to setup | Modal: Setup instructions |
| Transcription | Skip chunk, continue | Silent (logged) |
| Database | Critical error | Modal: "Database error. Meeting saved locally." |
| Token Overflow | Prune context | Warning: "Context limit reached. Older content pruned." |

### 6.2 Error Codes

```typescript
enum ErrorCode {
  // Network Errors (1000-1999)
  NETWORK_DISCONNECTED = 1001,
  WEBSOCKET_FAILED = 1002,
  API_TIMEOUT = 1003,

  // Audio Errors (2000-2999)
  AUDIO_DEVICE_NOT_FOUND = 2001,
  AUDIO_CAPTURE_FAILED = 2002,
  AUDIO_PERMISSION_DENIED = 2003,

  // API Errors (3000-3999)
  TRANSCRIPTION_FAILED = 3001,
  SUMMARY_FAILED = 3002,
  QUERY_FAILED = 3003,
  SUGGESTION_FAILED = 3004,
  RATE_LIMITED = 3005,

  // Database Errors (4000-4999)
  DB_CONNECTION_FAILED = 4001,
  DB_WRITE_FAILED = 4002,
  MEETING_NOT_FOUND = 4003,

  // Token Errors (5000-5999)
  TOKEN_LIMIT_EXCEEDED = 5001,
  CONTEXT_BUILD_FAILED = 5002,
}
```

### 6.3 Recovery Strategies

**Transcription Failure**:
1. Log error and chunk details
2. Continue capturing subsequent audio
3. Mark gap in transcript UI
4. Retry chunk if API returns 429 (rate limit)

**WebSocket Disconnection**:
1. Attempt reconnection with exponential backoff
2. Maximum 5 retry attempts
3. Show reconnection indicator in UI
4. On success, fetch missed events via REST API
5. On final failure, prompt user to restart meeting

**Token Overflow**:
1. Calculate excess tokens
2. Remove oldest transcript segments (preserve summaries)
3. Update token counter
4. Log pruned content (keep in DB, exclude from context)

---

## 7. Security Considerations

### 7.1 Data Security

| Data Type | Storage | Encryption |
|-----------|---------|------------|
| API Keys | OS Keychain | Yes |
| Meeting Transcripts | Local DB | At-rest (optional) |
| Audio Chunks | Memory only | N/A |
| User Settings | Local file | No |

### 7.2 API Key Management

- Store OpenAI API key in OS-level secure storage (Electron safeStorage)
- Never log or display full API key
- Validate key on startup with test API call
- Prompt for re-entry if invalid

### 7.3 IPC Security

- Use contextBridge for renderer-main communication
- Whitelist allowed IPC channels
- Validate all data crossing IPC boundary
- No nodeIntegration in renderer

---

## 8. Performance Specifications

### 8.1 Memory Management

**Transcript Pruning**:
- Keep last 500 segments in UI state
- All segments persisted to DB
- Lazy load older segments on scroll

**Audio Buffer**:
- Maximum 10 seconds of audio in memory
- Processed chunks immediately discarded
- Clear buffer on meeting end

### 8.2 Render Optimization

**Virtualized Lists**:
- Transcript panel: react-window with fixed row height
- Meeting history: Virtualized with variable height

**Debounced Updates**:
- Token usage: Update UI at most every 5 seconds
- Audio level: Update at most 10 times per second

### 8.3 API Call Optimization

**Batching**:
- Token counting: Batch with summary requests
- Suggestion generation: Debounce question detection (500ms)

**Caching**:
- Meeting list: Cache for 5 minutes
- Completed meeting details: Cache indefinitely

---

## 9. Accessibility

### 9.1 Keyboard Navigation

All components must be keyboard accessible:
- Tab order follows visual layout
- Focus indicators clearly visible
- Enter/Space activates buttons
- Escape closes modals/notifications

### 9.2 Screen Reader Support

- All interactive elements have aria-labels
- Live regions for real-time updates (aria-live="polite")
- Status messages announced

### 9.3 Visual Accessibility

- Minimum contrast ratio: 4.5:1 (WCAG AA)
- Text resizable to 200% without loss
- No information conveyed by color alone

---

## 10. Testing Requirements

### 10.1 Unit Tests

- All Zustand store actions
- All utility functions (token counting, text processing)
- Component rendering with various props

### 10.2 Integration Tests

- API client functions
- WebSocket connection and event handling
- IPC communication

### 10.3 E2E Tests

- Start/stop meeting flow
- Real-time transcript display
- Query and response flow
- Meeting history navigation

### 10.4 Performance Tests

- UI responsiveness with 1000+ transcript segments
- Memory usage over 2-hour meeting simulation
- WebSocket latency under load

---

## Appendix A: UI Mockups Reference

Detailed mockups to be created in Figma. Key screens:

1. Main Dashboard - Idle State
2. Main Dashboard - Recording State
3. Main Dashboard - With Suggestion
4. Meeting History - List View
5. Meeting History - Detail View
6. Settings Modal
7. Audio Setup Guide Modal
8. Error States

---

## Appendix B: Keyboard Shortcuts Reference

| Action | Windows | macOS |
|--------|---------|-------|
| Start Meeting | Ctrl+Shift+M | Cmd+Shift+M |
| End Meeting | Ctrl+Shift+E | Cmd+Shift+E |
| Focus Query | Ctrl+K | Cmd+K |
| Send Query | Ctrl+Enter | Cmd+Enter |
| 30s Recap | Ctrl+Shift+R | Cmd+Shift+R |
| Copy Suggestion | Ctrl+C (when focused) | Cmd+C |
| Dismiss Suggestion | Escape | Escape |
| Toggle History | Ctrl+H | Cmd+H |
| Toggle Always on Top | Ctrl+Shift+T | Cmd+Shift+T |
| Search (in History) | Ctrl+F | Cmd+F |
