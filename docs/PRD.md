# Product Requirements Document (PRD)
# macapy.io - Agentic Meeting Assistant

**Version**: 1.0
**Last Updated**: 2025-11-25
**Status**: Draft - Pre-Implementation

---

## 1. Executive Summary

### 1.1 Product Vision

macapy.io is an AI-powered desktop meeting assistant that provides real-time transcription, intelligent summarization, and contextually-aware response suggestions during online meetings. The application leverages GPT-5 nano as its reasoning engine and OpenAI Whisper for transcription, delivered through a compact, always-accessible Electron overlay.

### 1.2 Problem Statement

Professionals face several challenges during online meetings:
- **Cognitive overload**: Tracking complex discussions while preparing thoughtful responses
- **Missing information**: Forgetting key points or losing context in long meetings
- **Interview anxiety**: Difficulty articulating relevant experience under pressure
- **Post-meeting gaps**: Incomplete notes and forgotten action items

### 1.3 Solution Overview

A lightweight desktop application that:
1. Captures and transcribes meeting audio in real-time
2. Provides periodic rolling summaries to maintain context
3. Detects questions and offers AI-generated response suggestions
4. Enables users to query the AI about meeting content on-demand
5. Maintains searchable history of all past meetings

---

## 2. Product Goals and Success Metrics

### 2.1 Primary Goals

| Goal | Description | Priority |
|------|-------------|----------|
| G1 | Real-time transcription with < 5s latency | P0 |
| G2 | Accurate, actionable rolling summaries | P0 |
| G3 | Contextual response suggestions when questions detected | P0 |
| G4 | Minimal UI footprint with maximum accessibility | P1 |
| G5 | Persistent meeting history with search | P1 |
| G6 | Cross-platform support (Windows first, macOS later) | P2 |

### 2.2 Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Transcription Latency | < 5 seconds | Time from speech to displayed text |
| Summary Generation | < 10 seconds | Time from interval end to summary |
| Suggestion Latency | < 8 seconds | Time from question detection to display |
| UI Response Time | < 100ms | All user interactions |
| Token Efficiency | < 30% of context window per hour | Rolling management |
| User Satisfaction | > 4.0/5.0 | Post-session feedback |

### 2.3 Non-Goals (Out of Scope for V1)

- Speaker diarization (identifying who said what)
- Video capture or screen recording
- Calendar integrations
- Multi-user/team features
- Mobile applications
- Offline AI processing (requires API)

---

## 3. User Personas

### 3.1 Primary Persona: Interview Candidate (Alex)

**Demographics**: Software engineer, 5 years experience, job hunting

**Goals**:
- Articulate technical experience clearly under pressure
- Reference specific projects and achievements accurately
- Stay focused on conversation while having backup support

**Pain Points**:
- Blanks out when asked unexpected questions
- Forgets to mention key achievements
- Struggles to recall specific project details

**Usage Pattern**: 2-5 interview meetings per week, 30-60 minutes each

### 3.2 Secondary Persona: Knowledge Worker (Jordan)

**Demographics**: Product manager, frequent stakeholder meetings

**Goals**:
- Never miss action items or decisions
- Quick reference to earlier discussion points
- Efficient post-meeting documentation

**Pain Points**:
- Back-to-back meetings with no time for notes
- Important details lost in lengthy discussions
- Manual note-taking disrupts engagement

**Usage Pattern**: 4-8 meetings daily, 15-60 minutes each

### 3.3 Tertiary Persona: Student (Riley)

**Demographics**: Graduate student, virtual lectures and group projects

**Goals**:
- Capture lecture content accurately
- Focus on understanding vs. note-taking
- Review and study from meeting transcripts

**Pain Points**:
- Difficulty keeping up with fast-paced lectures
- Missing content while taking notes

**Usage Pattern**: 3-5 class sessions weekly, 1-2 hours each

---

## 4. Feature Requirements

### 4.1 Core Features (P0 - Must Have)

#### F1: Meeting Session Control

**Description**: Users can start and stop meeting recording sessions

**Requirements**:
- F1.1: "Start Meeting" button creates new session and begins audio capture
- F1.2: "End Meeting" button stops capture and finalizes session
- F1.3: Meeting status clearly indicated (Idle, Recording, Processing)
- F1.4: Confirmation dialog before ending active meeting
- F1.5: Auto-stop if no audio detected for configurable duration (default: 5 min)

**Acceptance Criteria**:
- Session starts within 2 seconds of button press
- All audio from start to stop is captured
- Meeting is persisted to database with metadata

---

#### F2: Real-Time Transcription Display

**Description**: Live transcript of meeting audio displayed in scrolling view

**Requirements**:
- F2.1: Transcript segments appear within 5 seconds of speech
- F2.2: Auto-scroll to latest segment (with manual scroll override)
- F2.3: Timestamps visible for each segment
- F2.4: Visual distinction between system audio and user microphone
- F2.5: Clear visual feedback during silence/processing

**Acceptance Criteria**:
- Transcript updates in real-time via WebSocket
- Performance remains smooth with 1000+ segments
- Scroll position preserved when user scrolls up

---

#### F3: Periodic Rolling Summaries

**Description**: AI-generated summaries at configurable intervals

**Requirements**:
- F3.1: Generate summary every N seconds (configurable, default: 60s)
- F3.2: Summary covers content since last summary
- F3.3: Display summaries in dedicated panel
- F3.4: Include key points, decisions, and action items
- F3.5: Manual "Summarize Now" button for on-demand summary

**Acceptance Criteria**:
- Summary appears within 10 seconds of interval
- Summaries are concise (3-5 bullet points max)
- Token usage tracked and displayed

---

#### F4: User Query Input

**Description**: Text input for user to ask questions about meeting content

**Requirements**:
- F4.1: Always-visible input field during active meeting
- F4.2: Send question to GPT-5 nano with transcript/summary context
- F4.3: Response displayed in conversation-style UI
- F4.4: Context window management to prevent overflow
- F4.5: Keyboard shortcut for quick access (Ctrl+Enter to send)

**Acceptance Criteria**:
- Response within 5-8 seconds
- Context includes relevant transcript and summaries
- Clear loading state during AI processing

---

#### F5: Question Detection and Auto-Suggestions

**Description**: Detect questions in transcript and offer response suggestions

**Requirements**:
- F5.1: Automatically detect questions directed at user
- F5.2: Generate 2-3 response options using GPT-5 nano
- F5.3: Display suggestions in prominent notification area
- F5.4: One-click copy to clipboard
- F5.5: Keyboard shortcut to trigger suggestion (e.g., Ctrl+Shift+S)

**Acceptance Criteria**:
- Question detected within 3 seconds of transcript
- Suggestions appear within 8 seconds
- Suggestions are contextually relevant

---

### 4.2 Important Features (P1 - Should Have)

#### F6: 30-Second Audio Recap

**Description**: Quick AI-generated recap of last 30 seconds of conversation

**Requirements**:
- F6.1: Button or keyboard shortcut triggers recap
- F6.2: Process last 30s of transcript through LLM
- F6.3: Display as temporary notification/tooltip
- F6.4: Auto-dismiss after 10 seconds or user action

**Acceptance Criteria**:
- Recap appears within 5 seconds
- Content is accurate to recent discussion

---

#### F7: Meeting History Dashboard

**Description**: Browse and search past meeting sessions

**Requirements**:
- F7.1: List view of all past meetings with metadata
- F7.2: Display: title, date, duration, summary preview
- F7.3: Click to expand full transcript and summaries
- F7.4: Search across all meeting content
- F7.5: Delete meetings (with confirmation)
- F7.6: Accessible at any time (not just during meetings)

**Acceptance Criteria**:
- List loads within 2 seconds
- Search returns results within 1 second
- New meetings appear immediately after completion

---

#### F8: Context Window Management

**Description**: Intelligent management of GPT-5 nano's context window

**Requirements**:
- F8.1: Track token usage across transcript and summaries
- F8.2: Automatic pruning of old transcript when approaching limit
- F8.3: Prioritize recent content and summaries
- F8.4: Display current token usage to user
- F8.5: Warning when approaching 80% capacity

**Acceptance Criteria**:
- Never exceed 272,000 input tokens
- Context includes last 30 min of content minimum
- Summaries preserved over raw transcript

---

### 4.3 Nice-to-Have Features (P2 - Could Have)

#### F9: Document Context Integration

**Description**: Upload documents to provide additional context for AI

**Requirements**:
- F9.1: Upload PDF, DOCX, TXT, MD files
- F9.2: Parse and chunk documents for embedding
- F9.3: Retrieve relevant chunks for suggestions
- F9.4: Manage uploaded documents per meeting or globally

**Note**: Backend infrastructure already exists for this feature.

---

#### F10: Custom Prompt Templates

**Description**: Allow users to customize AI prompt behavior

**Requirements**:
- F10.1: Edit system prompts for summaries
- F10.2: Define custom suggestion styles
- F10.3: Save and load prompt presets

---

#### F11: Export Functionality

**Description**: Export meeting data to various formats

**Requirements**:
- F11.1: Export transcript as TXT, Markdown
- F11.2: Export summaries separately
- F11.3: Copy full meeting to clipboard

---

## 5. User Experience Requirements

### 5.1 Design System

**Visual Identity**:
- Primary color: Black (#000000)
- Accent color: Light blue (#00D4FF / #4FC3F7)
- Background: Dark (#0D0D0D)
- Text: Light (#E0E0E0)

**Typography**:
- Primary font: JetBrains Mono or Fira Code (monospace)
- Headings: 14-18px, semibold
- Body: 12-13px, regular
- Transcript: 11-12px, regular

**UI Style**:
- CLI-like aesthetic with modern polish
- Compact overlay design (always on top option)
- Minimal chrome, maximum content
- Dynamic elements (animations, transitions)
- Dark mode only (V1)

### 5.2 Layout Specifications

**Main Meeting Dashboard**:
```
+------------------------------------------+
|  [macapy.io]     [=] [-] [X]   <- Title bar
+------------------------------------------+
|  Meeting: [Title Input]   [Start] [End]  |
+------------------------------------------+
|  +-----------------+ +-----------------+ |
|  | LIVE TRANSCRIPT | |   SUMMARIES     | |
|  |                 | |                 | |
|  | [auto-scroll]   | | - Point 1       | |
|  |                 | | - Point 2       | |
|  | 10:31 Speaker.. | | - Point 3       | |
|  | 10:32 Response..| |                 | |
|  +-----------------+ +-----------------+ |
+------------------------------------------+
|  > Ask a question...        [Send] [30s] |
+------------------------------------------+
|  [Suggestion Alert]                      |
|  Q: "Tell me about your experience..."   |
|  - Option 1 [Copy]                       |
|  - Option 2 [Copy]                       |
+------------------------------------------+
|  Tokens: 45,230 / 272,000  |  00:23:45   |
+------------------------------------------+
```

**Meeting History Dashboard**:
```
+------------------------------------------+
|  [<- Back]   Meeting History    [Search] |
+------------------------------------------+
|  +--------------------------------------+|
|  | Nov 24, 2025 - Interview @ Google   ||
|  | Duration: 45 min | 3 summaries       ||
|  | Preview: Discussion about system... ||
|  +--------------------------------------+|
|  | Nov 23, 2025 - Team Standup         ||
|  | Duration: 15 min | 2 summaries       ||
|  +--------------------------------------+|
+------------------------------------------+
```

### 5.3 Interaction Patterns

**Keyboard Shortcuts**:
| Action | Shortcut |
|--------|----------|
| Start Meeting | Ctrl+Shift+M |
| End Meeting | Ctrl+Shift+E |
| Focus Query Input | Ctrl+K |
| Send Query | Ctrl+Enter |
| Get 30s Recap | Ctrl+Shift+R |
| Toggle Suggestions | Ctrl+Shift+S |
| Toggle Always on Top | Ctrl+Shift+T |
| Switch to History | Ctrl+H |

**Window Behavior**:
- Resizable (min: 400x500, default: 600x800)
- Always-on-top toggle
- System tray minimization
- Remember position/size between sessions

---

## 6. Technical Constraints

### 6.1 Platform Requirements

- **Primary**: Windows 10/11 (64-bit)
- **Secondary**: macOS 12+ (future)
- **Runtime**: Electron 28+
- **Node.js**: 20 LTS

### 6.2 API Dependencies

| Service | Purpose | Rate Limits | Costs |
|---------|---------|-------------|-------|
| OpenAI Whisper | Transcription | None (pay per second) | ~$0.006/min |
| GPT-5 nano | Reasoning | None | $0.05/1M in, $0.40/1M out |
| OpenAI Embeddings | Document search | None | $0.02/1M tokens |

### 6.3 Performance Requirements

| Metric | Target |
|--------|--------|
| App Startup | < 3 seconds |
| Memory Usage (Idle) | < 200MB |
| Memory Usage (Active) | < 500MB |
| CPU Usage (Idle) | < 2% |
| CPU Usage (Active) | < 15% |
| WebSocket Latency | < 100ms |

### 6.4 Audio Requirements

- Virtual audio device: VB-CABLE (Windows), BlackHole (macOS)
- Sample rate: 16kHz (Whisper optimal)
- Channels: Mono
- Format: 16-bit PCM

---

## 7. Assumptions and Dependencies

### 7.1 Assumptions

1. User has stable internet connection for API calls
2. User has installed virtual audio device for system audio capture
3. OpenAI API remains available and pricing stable
4. GPT-5 nano model ID and capabilities as specified

### 7.2 Dependencies

| Component | Dependency | Risk Level |
|-----------|------------|------------|
| Backend | Existing FastAPI services | Low |
| Database | PostgreSQL + pgvector | Low |
| Transcription | OpenAI Whisper API | Medium |
| Reasoning | GPT-5 nano | Medium |
| Audio | pyaudiowpatch / VB-CABLE | Medium |

### 7.3 Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| API rate limits during heavy use | Service degradation | Implement queuing, backoff |
| High API costs for long meetings | User expense | Token usage warnings, auto-pause |
| Audio device compatibility issues | No capture | Clear setup guide, fallback options |
| Context window overflow | Lost context | Aggressive summarization, pruning |

---

## 8. Release Plan

### 8.1 Milestones

| Phase | Scope | Target |
|-------|-------|--------|
| Alpha | Core transcription + summaries | Week 3 |
| Beta | Full feature set, internal testing | Week 6 |
| RC | Bug fixes, performance optimization | Week 8 |
| V1.0 | Public release (Windows) | Week 10 |

### 8.2 Feature Rollout

**Alpha (MVP)**:
- Meeting start/stop
- Real-time transcription
- Basic summaries
- Electron shell

**Beta**:
- Query input
- Question detection
- Response suggestions
- Meeting history
- Token management

**V1.0**:
- 30-second recap
- UI polish
- Keyboard shortcuts
- Performance optimization

---

## 9. Open Questions

1. **Summary interval**: What is the optimal default interval for rolling summaries? (30s, 60s, 90s?)

2. **Question detection sensitivity**: How aggressively should we detect questions? (High sensitivity = more false positives)

3. **Token budget allocation**: What percentage of context should be reserved for user queries vs. transcript?

4. **Audio mixing**: Should system audio and microphone be processed separately or mixed?

5. **Data retention**: How long should meeting history be retained by default?

6. **Offline mode**: Should we support any offline functionality (local transcription, cached responses)?

---

## Appendix A: Glossary

| Term | Definition |
|------|------------|
| GPT-5 nano | OpenAI's ultra-low latency reasoning model |
| Whisper | OpenAI's speech-to-text transcription model |
| Context window | Maximum tokens a model can process (400K for GPT-5 nano) |
| Rolling summary | Periodic summary of recent content |
| Loopback device | Virtual audio device for capturing system audio |
| WebSocket | Bidirectional real-time communication protocol |

---

## Appendix B: References

- OpenAI API Documentation
- Electron Documentation
- Existing Backend: `backend/app/` (FastAPI services)
- CLAUDE.md: Project technical specifications
