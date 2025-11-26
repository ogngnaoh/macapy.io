# Clarifying Questions
# macapy.io - Pre-Implementation Decisions

**Version**: 1.0
**Last Updated**: 2025-11-25
**Status**: Awaiting User Input

---

## Instructions

Please review each question and provide your decision. These answers will directly inform implementation priorities and architectural choices.

---

## 1. Technical Decisions

### Q1.1: Summary Generation Interval

**Question**: What should be the default interval for rolling summaries?

**Options**:
- A) 30 seconds - More frequent updates, higher API costs
- B) 60 seconds (current default) - Balanced approach
- C) 90 seconds - Less frequent, lower costs
- D) User-configurable with a default (specify default)

**Considerations**:
- 30s: ~$0.02/hour in GPT-5 nano costs for summaries
- 60s: ~$0.01/hour
- 90s: ~$0.007/hour

**Your Answer**: _______________

---

### Q1.2: Question Detection Sensitivity

**Question**: How aggressively should the system detect questions directed at the user?

**Options**:
- A) High sensitivity - Detect most questions, some false positives acceptable
- B) Medium sensitivity - Balance between detection and false positives
- C) Low sensitivity - Only detect very clear, direct questions
- D) User-configurable toggle for sensitivity level

**Considerations**:
- High: May interrupt workflow with unnecessary suggestions
- Low: May miss important questions during interviews
- Medium: Current implementation uses heuristic + LLM confirmation

**Your Answer**: _______________

---

### Q1.3: Audio Source Handling

**Question**: How should the system handle system audio vs. microphone input?

**Options**:
- A) Mix both sources (current implementation) - Single transcript
- B) Separate streams with visual distinction - Two transcript columns
- C) User choice at meeting start - Select one or both
- D) System audio only (meeting attendees) with manual mic toggle

**Considerations**:
- Mixed: Simpler UI, may have audio level imbalance
- Separate: Clearer attribution, more complex UI
- User choice: Flexibility, potential confusion

**Your Answer**: _______________

---

### Q1.4: Token Budget Allocation

**Question**: How should the 272K input token budget be allocated?

**Options**:
- A) Dynamic allocation based on meeting length
- B) Fixed allocation:
  - 60% transcript (163K tokens)
  - 25% summaries (68K tokens)
  - 15% user queries/document context (41K tokens)
- C) Prioritize summaries over raw transcript always
- D) Let user configure allocation in settings

**Considerations**:
- Longer meetings need more aggressive summarization
- User queries need guaranteed context space
- Document context valuable for interview scenarios

**Your Answer**: _______________

---

### Q1.5: Data Retention Policy

**Question**: How long should meeting history be retained by default?

**Options**:
- A) 7 days
- B) 30 days
- C) 90 days
- D) Indefinitely until manually deleted
- E) User-configurable with default (specify default)

**Considerations**:
- Storage: ~1-2MB per hour-long meeting
- Privacy: Longer retention = more exposure risk
- Utility: Past meetings useful for reference

**Your Answer**: _______________

---

## 2. User Experience Decisions

### Q2.1: Suggestion Display Duration

**Question**: How long should auto-generated suggestions remain visible?

**Options**:
- A) 15 seconds then auto-dismiss
- B) 30 seconds then auto-dismiss (current design)
- C) Persist until manually dismissed
- D) User-configurable timeout

**Considerations**:
- Short: Less intrusive, may miss suggestions
- Long/Persistent: May clutter UI during active discussion

**Your Answer**: _______________

---

### Q2.2: Notification Style

**Question**: How should new suggestions and summaries be announced?

**Options**:
- A) Subtle highlight in UI panel only
- B) Slide-in notification (current design)
- C) System notification (native OS)
- D) Audio cue + visual notification
- E) User-configurable per notification type

**Considerations**:
- Subtle: Non-intrusive, may be missed
- System notification: Works even when window minimized
- Audio: Could be distracting during meeting

**Your Answer**: _______________

---

### Q2.3: Window Behavior

**Question**: What should be the default window behavior?

**Options**:
- A) Normal window (taskbar, can be covered by other apps)
- B) Always-on-top by default (overlay style)
- C) Compact mode with always-on-top, full mode without
- D) User sets preference on first launch

**Considerations**:
- Always-on-top: Ensures visibility, can obstruct screen share view
- Normal: Less intrusive, may get buried behind meeting app

**Your Answer**: _______________

---

### Q2.4: Meeting Title Handling

**Question**: How should meeting titles be handled?

**Options**:
- A) Required before starting (must enter title)
- B) Optional with auto-generated default ("Meeting - Nov 25, 10:30 AM")
- C) Optional with blank allowed
- D) Auto-detect from meeting app window title (experimental)

**Considerations**:
- Required: Better organization, friction to start
- Auto-generated: Easy to start, potentially generic titles
- Auto-detect: Technical complexity, may not work consistently

**Your Answer**: _______________

---

### Q2.5: Compact vs Full Mode

**Question**: Should there be a compact/minimal mode?

**Options**:
- A) No, single layout only
- B) Yes, toggle between full and compact (transcript only)
- C) Yes, with separate compact overlay (small floating widget)
- D) Yes, with multiple size presets (small/medium/large)

**Considerations**:
- Single layout: Simpler implementation
- Compact mode: Useful for limited screen space
- Floating widget: Very unobtrusive but limited functionality

**Your Answer**: _______________

---

## 3. Feature Priority Decisions

### Q3.1: MVP Feature Set

**Question**: Confirm the MVP (Minimum Viable Product) feature set:

**Proposed MVP Features** (Check all that should be in MVP):
- [ ] Start/Stop meeting recording
- [ ] Real-time transcription display
- [ ] Rolling summaries (60s interval)
- [ ] User query input with AI response
- [ ] Question detection with suggestions
- [ ] 30-second recap button
- [ ] Meeting history with search
- [ ] Document upload for context
- [ ] Custom keyboard shortcuts
- [ ] System tray with quick access
- [ ] Auto-update functionality

**Your Answer** (list included features): _______________

---

### Q3.2: Document Context Feature

**Question**: Should document context (upload resume/docs) be included in V1?

**Options**:
- A) Yes, include in MVP - Critical for interview use case
- B) Yes, but as a secondary feature (V1.1)
- C) No, defer to V2 - Focus on core transcription/AI first

**Considerations**:
- Backend already supports this feature
- Adds complexity to UI (upload flow, document management)
- Very valuable for the interview persona

**Your Answer**: _______________

---

### Q3.3: Export Functionality Priority

**Question**: How important is export functionality for V1?

**Options**:
- A) Essential - Include full export (TXT, Markdown)
- B) Basic - Copy to clipboard only
- C) Defer - Not needed for MVP

**Considerations**:
- Export useful for sharing/archiving
- Copy to clipboard covers most immediate needs
- Full export adds UI complexity

**Your Answer**: _______________

---

## 4. Performance Requirements

### Q4.1: Long Meeting Support

**Question**: What is the maximum meeting duration to support well?

**Options**:
- A) 1 hour (standard meeting)
- B) 2 hours (extended meeting)
- C) 4+ hours (all-day sessions)

**Considerations**:
- Longer meetings = more aggressive context pruning needed
- Memory usage scales with duration
- API costs scale linearly

**Your Answer**: _______________

---

### Q4.2: Offline Capabilities

**Question**: Should there be any offline functionality?

**Options**:
- A) No offline support - Require internet connection
- B) Basic offline - View history when offline
- C) Partial offline - Local transcription fallback (Whisper local model)
- D) Full offline - Local transcription + local LLM

**Considerations**:
- Local Whisper: Requires ~1GB+ model download, CPU intensive
- Local LLM: Requires powerful GPU, significant complexity
- View history offline: Simple to implement

**Your Answer**: _______________

---

### Q4.3: Startup Performance

**Question**: Is cold startup time critical?

**Options**:
- A) Yes - Must start in < 3 seconds
- B) Moderate - Up to 5 seconds acceptable
- C) Not critical - Can show splash screen for 10+ seconds

**Considerations**:
- Faster startup = more eager loading, higher memory
- Splash screen allows background initialization
- User may start app right before meeting

**Your Answer**: _______________

---

## 5. Platform and Distribution

### Q5.1: Initial Platform Target

**Question**: Confirm initial platform target:

**Options**:
- A) Windows only (fastest path)
- B) Windows primary, macOS secondary (built simultaneously)
- C) Cross-platform from start (Windows + macOS)

**Considerations**:
- Windows only: Faster development, VB-CABLE well-supported
- macOS: BlackHole support, different audio APIs
- Cross-platform: More testing, broader reach

**Your Answer**: _______________

---

### Q5.2: Distribution Method

**Question**: How will the app be distributed?

**Options**:
- A) Direct download (GitHub releases)
- B) Windows Store
- C) Both direct and store
- D) Private distribution (not public)

**Considerations**:
- Store: Auto-updates, discoverability, review process
- Direct: Full control, faster updates, no store fees
- Private: Simpler if internal tool only

**Your Answer**: _______________

---

### Q5.3: Auto-Update Strategy

**Question**: Should the app auto-update?

**Options**:
- A) Yes, automatic background updates
- B) Yes, but prompt user before installing
- C) No, manual updates only
- D) User-configurable

**Considerations**:
- Auto: Best UX, ensures users have latest fixes
- Prompt: User control, may defer important updates
- Manual: Risk of outdated installations

**Your Answer**: _______________

---

## 6. Cost and API Management

### Q6.1: API Key Management

**Question**: How should OpenAI API keys be handled?

**Options**:
- A) User provides their own API key (stored locally)
- B) Developer-provisioned key with usage limits
- C) Hybrid - Developer key for trial, user key for full use
- D) Subscription model with backend proxy

**Considerations**:
- User key: No backend costs, user controls spending
- Developer key: Simpler UX, cost management challenge
- Subscription: Predictable revenue, backend complexity

**Your Answer**: _______________

---

### Q6.2: Usage Warnings

**Question**: Should the app warn about API costs?

**Options**:
- A) Yes, show estimated session cost in real-time
- B) Yes, warn only when approaching high cost threshold
- C) No, assume user is aware of API costs
- D) User-configurable cost alerts

**Considerations**:
- Real-time: Most transparent, may cause anxiety
- Threshold only: Less intrusive, still protective
- No warning: Cleaner UI, risk of surprise bills

**Your Answer**: _______________

---

## 7. Additional Questions

### Q7.1: Branding

**Question**: Confirm the application name and branding:

- App Name: _______________
- Tagline (optional): _______________
- Color scheme confirmed (black + light blue)? Y/N: _______________

---

### Q7.2: Keyboard Shortcut Conflicts

**Question**: The proposed shortcuts may conflict with other apps. Please review:

| Action | Proposed | Conflict? | Alternative |
|--------|----------|-----------|-------------|
| Start Meeting | Ctrl+Shift+M | | |
| End Meeting | Ctrl+Shift+E | | |
| Focus Query | Ctrl+K | VS Code | |
| 30s Recap | Ctrl+Shift+R | | |
| Toggle History | Ctrl+H | Common | |

**Your Changes** (if any): _______________

---

### Q7.3: Privacy Considerations

**Question**: Should there be additional privacy features?

**Options** (select all that apply):
- [ ] Option to not store transcripts (session-only mode)
- [ ] Encryption at rest for stored meetings
- [ ] Auto-delete after N days option
- [ ] Pause recording button (mute capture)
- [ ] Clear all data button

**Your Selection**: _______________

---

### Q7.4: Accessibility Requirements

**Question**: What level of accessibility support is required?

**Options**:
- A) Basic - Keyboard navigation, focus indicators
- B) WCAG AA - Full screen reader support, contrast requirements
- C) WCAG AAA - Maximum accessibility compliance
- D) Defer accessibility to post-MVP

**Your Answer**: _______________

---

### Q7.5: Error Reporting

**Question**: Should the app include error/crash reporting?

**Options**:
- A) Yes, automatic anonymous crash reporting (Sentry/similar)
- B) Yes, but ask user permission first
- C) No telemetry, manual bug reports only

**Your Answer**: _______________

---

## Summary of Required Decisions

Please provide answers to all questions above. Critical decisions for starting development:

1. **Q1.1** - Summary interval
2. **Q1.3** - Audio source handling
3. **Q3.1** - MVP feature set confirmation
4. **Q5.1** - Platform target
5. **Q6.1** - API key management

---

## Response Template

```
## My Answers

### Technical
- Q1.1 (Summary interval):
- Q1.2 (Question detection):
- Q1.3 (Audio handling):
- Q1.4 (Token allocation):
- Q1.5 (Data retention):

### UX
- Q2.1 (Suggestion duration):
- Q2.2 (Notification style):
- Q2.3 (Window behavior):
- Q2.4 (Meeting title):
- Q2.5 (Compact mode):

### Features
- Q3.1 (MVP features):
- Q3.2 (Document context):
- Q3.3 (Export):

### Performance
- Q4.1 (Max duration):
- Q4.2 (Offline):
- Q4.3 (Startup):

### Platform
- Q5.1 (Platform):
- Q5.2 (Distribution):
- Q5.3 (Auto-update):

### Cost
- Q6.1 (API keys):
- Q6.2 (Usage warnings):

### Additional
- Q7.1 (Branding):
- Q7.2 (Shortcuts):
- Q7.3 (Privacy):
- Q7.4 (Accessibility):
- Q7.5 (Error reporting):

### Additional Notes:
(Any other preferences or requirements)
```
