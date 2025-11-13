# macapy.io Clarifying Questions

**Project**: macapy.io - AI-Powered Personal Meeting Assistant
**Last Updated**: 2025-10-09

Before beginning implementation, please answer the following questions to refine requirements and make informed technical decisions.

---

## Table of Contents

1. [Critical Decisions](#critical-decisions)
2. [Feature Scope Questions](#feature-scope-questions)
3. [How to Use This Document](#how-to-use-this-document)

---

## Critical Decisions

These questions directly impact the technology stack and architecture.

### Q1: Operating System Target

**Question**: What is your primary operating system for development and usage?

**Options**:
- [ ] Windows (primary focus)
- [ ] macOS (primary focus)
- [ ] Linux (primary focus)
- [ ] Cross-platform (all three)

**Impact**:
- **Audio capture** libraries are OS-specific (pyaudiowpatch for Windows, BlackHole for macOS)
- **Virtual audio device** setup varies by OS
- **Deployment** scripts and documentation will be OS-specific
- **Testing** requirements increase significantly for cross-platform

**Follow-up**:
- If cross-platform: Which OS should we prioritize for MVP?
- Are you willing to use OS-specific tools, or do you need a unified approach?

**Recommendation**: Start with one OS (your primary development environment), then expand to others in later stages.

---

### Q2: Programming Language Preferences

**Question**: Are you comfortable with the proposed technology stack?

**Proposed Stack**:
- **Backend**: Python 3.11+ with FastAPI
- **Frontend**: TypeScript with React
- **Database**: PostgreSQL with SQL

**Options**:
- [ ] Yes, comfortable with Python + TypeScript + SQL
- [ ] Prefer alternative backend language (specify: ________)
- [ ] Prefer alternative frontend framework (specify: ________)
- [ ] Need to learn these technologies first

**Impact**:
- **Development speed**: Familiar languages = faster progress
- **Learning curve**: New languages add 2-4 weeks per technology
- **Library availability**: Python has best AI/ML ecosystem
- **Type safety**: TypeScript provides better developer experience than JavaScript

**Recommendation**: The proposed stack is optimal for AI applications. If unfamiliar, budget time for learning (see [TECHNOLOGY_STACK.md](../TECHNOLOGY_STACK.md) learning roadmap).

---

### Q3: Privacy vs. Convenience Trade-offs

**Question**: What is your preference for API usage vs. local processing?

**Options**:
- [ ] **Option A**: Use OpenAI APIs (Whisper + GPT-4) - **Easiest, fastest, but sends data externally**
  - Pros: Simple integration, best quality, no GPU required
  - Cons: Costs money, data sent to OpenAI, requires internet

- [ ] **Option B**: Local models only (faster-whisper + local LLM) - **Most private, but slower and more complex**
  - Pros: Complete privacy, no API costs, works offline
  - Cons: Requires powerful GPU, slower transcription, more setup

- [ ] **Option C**: Hybrid (local Whisper + OpenAI GPT-4) - **Balanced approach**
  - Pros: Audio stays local, only text sent to OpenAI
  - Cons: Still requires API, moderate setup complexity

**Impact**:
- **Privacy**: Local models keep all data on your machine
- **Performance**: APIs are faster, local models require GPU for real-time processing
- **Cost**: APIs charge per use, local models are free after setup
- **Development time**: APIs are simpler to integrate

**Follow-up**:
- What is your monthly budget for API costs? (Estimate: $20-50/month for moderate use)
- Do you have a GPU? (Model: ________, VRAM: ________GB)
- Is complete privacy a hard requirement?

**Recommendation**: Start with Option A (APIs) for MVP, add Option B (local) in Stage 7 (Advanced Features).

---

### Q4: Meeting Platforms Priority

**Question**: Which meeting platforms do you use most frequently?

**Options** (check all that apply):
- [ ] Zoom
- [ ] Google Meet
- [ ] Microsoft Teams
- [ ] Discord
- [ ] Other: __________

**Primary platform** (most important): __________

**Impact**:
- **Audio capture approach**: Some platforms may have specific requirements
- **Testing scope**: Need to test audio routing for each platform
- **Feature priorities**: Platform-specific integrations (if any)

**Follow-up**:
- Do you need to support multiple platforms simultaneously?
- Are there platform-specific features you want (e.g., auto-join Zoom calls)?

**Recommendation**: Focus on one platform for MVP, test with others in Stage 6 (Integration & Testing).

---

### Q5: Real-Time vs. Near-Real-Time Expectations

**Question**: How much latency is acceptable for different features?

**Transcription latency** (time from speech to display):
- [ ] < 3 seconds (real-time, challenging)
- [ ] 3-5 seconds (near real-time, achievable)
- [ ] 5-10 seconds (acceptable for MVP)
- [ ] > 10 seconds (too slow, not useful)

**Suggestion latency** (time from question to suggestion):
- [ ] < 5 seconds (very fast, challenging)
- [ ] 5-8 seconds (fast enough for natural conversation)
- [ ] 8-15 seconds (acceptable if high quality)
- [ ] > 15 seconds (too slow)

**Impact**:
- **Architecture complexity**: Lower latency requires more optimization
- **API vs. local models**: APIs are faster but less controllable
- **User experience**: Lower latency feels more responsive
- **Development priorities**: May need to prioritize performance over features

**Recommendation**: Target 3-5s for transcription and 8s for suggestions. These are achievable with OpenAI APIs.

---

## Feature Scope Questions

These questions help prioritize features and define MVP scope.

### Q6: Response Suggestion Interactivity

**Question**: How should users interact with response suggestions?

**Desired features** (check all that apply):
- [ ] Display suggestions in UI (read-only)
- [ ] Copy suggestion to clipboard (single click)
- [ ] Edit suggestion before using
- [ ] Mark suggestion as "used" or "not used"
- [ ] Rate suggestion quality (thumbs up/down)
- [ ] Save favorite suggestions for reuse
- [ ] Customize suggestion style (formal, casual, technical)

**Impact**:
- More features = longer development time
- Editing and customization require additional UI components
- Rating system helps improve prompt engineering over time

**Recommendation**: Start with display + copy + mark as used. Add editing and rating in Stage 7.

---

### Q7: Meeting Recording Storage

**Question**: Should macapy.io store audio recordings, or just transcripts?

**Options**:
- [ ] **Option A**: Store transcripts only - **Simpler, less storage**
  - Pros: Smaller database, faster, no audio privacy concerns
  - Cons: Can't replay audio later, can't re-transcribe with better model

- [ ] **Option B**: Store audio + transcripts - **More complete, but larger**
  - Pros: Can review audio later, re-transcribe if needed, more accurate record
  - Cons: Large storage requirements (1GB+ per hour), privacy concerns

- [ ] **Option C**: Store audio temporarily, delete after meeting - **Balanced**
  - Pros: Can review audio during/after meeting, then cleanup
  - Cons: Slightly more complex

**Follow-up**:
- What's your available storage space? (GB: ________)
- How many hours of meetings per week? (Hours: ________)
- Do you need audio playback for reviewing meetings?

**Recommendation**: Start with Option A (transcripts only) for MVP. Add audio storage in Stage 7 if needed.

---

### Q8: Context Document Management

**Question**: How should uploaded documents be managed?

**Options**:
- [ ] **Per-meeting documents**: Upload documents for each meeting, delete after
  - Use case: Upload job description for each interview

- [ ] **Persistent documents**: Upload once, reuse across meetings
  - Use case: Upload resume once, use for all interviews

- [ ] **Both**: Some documents persist, others are meeting-specific

**Follow-up**:
- How many documents per meeting? (Estimate: ________)
- What's the typical document size? (MB: ________)
- Do documents change frequently? (e.g., updating resume monthly)

**Impact**:
- Persistent documents require document library UI
- Per-meeting documents are simpler but less convenient
- Both options add complexity

**Recommendation**: Start with per-meeting documents for MVP, add persistent library in Stage 7.

---

### Q9: User Authentication

**Question**: Is this a single-user application, or multi-user?

**Options**:
- [ ] **Single-user**: Only you will use it on your machine
  - Pros: Much simpler, no authentication needed
  - Cons: Can't share across devices or with others

- [ ] **Multi-user**: Multiple people can have accounts
  - Pros: Can share, collaborate, access from multiple devices
  - Cons: Requires authentication, user management, more security

**Impact**:
- Single-user significantly reduces development complexity
- Multi-user requires JWT authentication, password management, user table
- Estimated time difference: 1-2 weeks

**Recommendation**: Single-user for MVP (no authentication). Add authentication in post-MVP if needed.

---

### Q10: Deployment Complexity

**Question**: What is your preferred deployment approach?

**Options**:
- [ ] **Option A**: Docker Compose - **Easiest for local deployment**
  - Pros: One-command start, consistent environment, easy updates
  - Cons: Requires Docker installed, slight resource overhead

- [ ] **Option B**: Manual installation - **No Docker required**
  - Pros: No additional software, direct control
  - Cons: More setup steps, OS-specific issues, harder to update

- [ ] **Option C**: System service - **Always running in background**
  - Pros: Auto-start on boot, minimal user interaction
  - Cons: More complex setup, requires system permissions

**Follow-up**:
- Are you comfortable using Docker? (Yes/No: ________)
- Do you want the app to start automatically when your computer boots? (Yes/No: ________)
- Should there be a system tray icon for quick access? (Yes/No: ________)

**Impact**:
- Docker Compose simplifies deployment and updates
- System service provides best user experience but more complex
- Manual installation has most potential for setup issues

**Recommendation**: Use Docker Compose for development and MVP. Add system tray app in Stage 7.

---

## How to Use This Document

### Step 1: Answer All Questions

Go through each question and provide your answers. You can either:
- Edit this file directly with your answers
- Create a separate `ANSWERS.md` file
- Discuss answers with the development team

### Step 2: Identify Uncertainties

If you're unsure about any answer:
- Mark it with "⚠️ UNCERTAIN"
- Research options further
- Start with recommended default and adjust later

### Step 3: Update Documentation

Once questions are answered:
- Update [ROADMAP.md](./ROADMAP.md) with any changes to stages/tasks
- Update [ARCHITECTURE.md](./ARCHITECTURE.md) if technology choices change
- Update [TECHNOLOGY_STACK.md](../TECHNOLOGY_STACK.md) if learning paths change

### Step 4: Review Recommendations

The recommended approaches are:
1. **Q1**: Start with your primary OS (likely Windows based on environment)
2. **Q2**: Use proposed stack (Python + TypeScript)
3. **Q3**: OpenAI APIs for MVP, local models later
4. **Q4**: Focus on one meeting platform first
5. **Q5**: Target 3-5s transcription, 8s suggestions
6. **Q6**: Display + copy + mark-as-used for suggestions
7. **Q7**: Store transcripts only (no audio)
8. **Q8**: Per-meeting documents
9. **Q9**: Single-user (no authentication)
10. **Q10**: Docker Compose deployment

These recommendations optimize for:
- ✅ Fastest path to working MVP
- ✅ Simplest architecture
- ✅ Best learning experience
- ✅ Easy iteration and expansion later

---

## Decision Log

Track your answers here:

| Question | Answer | Date | Notes |
|----------|--------|------|-------|
| Q1: OS | Windows | 2025-11-12 | Primary development environment |
| Q2: Stack | Python + TypeScript + PostgreSQL | 2025-11-12 | FastAPI backend, React frontend |
| Q3: Privacy | OpenAI Whisper API (Option A) | 2025-11-12 | For MVP, consider local later |
| Q4: Platform | All platforms simultaneously | 2025-11-12 | Zoom, Google Meet, Teams, Discord |
| Q5: Latency | 3-5s transcription, 5-8s suggestions | 2025-11-12 | Stricter targets than recommended |
| Q6: Suggestions | Display + copy + mark-used | 2025-11-12 | Keep it simple |
| Q7: Storage | Transcripts only | 2025-11-12 | No audio storage for MVP |
| Q8: Documents | Per-meeting | 2025-11-12 | Upload for each session |
| Q9: Auth | Single-user | 2025-11-12 | No authentication needed |
| Q10: Deployment | Docker Compose | 2025-11-12 | Easiest for local use |

---

## Next Steps After Answering

1. **Review and finalize answers** - Make sure you're confident in your choices
2. **Update project documentation** - Reflect decisions in other docs
3. **Begin Stage 1** - Start with Foundation & Environment setup
4. **Revisit as needed** - These aren't set in stone; adjust as you learn

---

**Remember**: The goal is to make informed decisions, not perfect ones. You can always adjust later based on what you learn during development.

Good luck with macapy.io! 🚀
