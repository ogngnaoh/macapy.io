# macapy.io Current Transcription Architecture

## Table of Contents
- [Audio Pipeline](#audio-pipeline)
- [Key Data Structures](#key-data-structures)
- [Service Interfaces](#service-interfaces)
- [WebSocket Events](#websocket-events)
- [Patterns to Preserve](#patterns-to-preserve)

---

## Audio Pipeline

```
Native Audio Capture → AudioChunk → TranscriptionService → Transcript DB → WebSocket Broadcast
```

**Current flow:**
1. `AudioCaptureService` yields `AudioChunk` objects (1 second each)
2. `TranscriptionService.transcribe_chunk()` sends to Whisper API
3. `MeetingService._processing_loop()` orchestrates the pipeline
4. Transcripts stored in DB and broadcast via WebSocket

---

## Key Data Structures

### AudioChunk (from audio_capture.py)

```python
@dataclass
class AudioChunk:
    data: np.ndarray      # float32 array (-1.0 to 1.0)
    timestamp: float      # seconds since meeting start
    sample_rate: int      # 16000 Hz
    channels: int         # 1 (mono)
    source: str           # "system" (loopback) or "user" (mic)
```

### TranscriptResult (from transcription.py)

```python
@dataclass
class TranscriptResult:
    text: str             # Transcribed text
    language: str         # Detected language code
    timestamp: float      # Chunk timestamp
    duration: float       # Chunk duration
```

### Transcript Model (from models/transcript.py)

```python
class Transcript(Base):
    id: UUID
    meeting_id: UUID
    speaker: str          # "system" or "user" (from chunk.source)
    text: str
    timestamp: float
    created_at: datetime
```

---

## Service Interfaces

### TranscriptionService (current)

```python
class TranscriptionService:
    async def transcribe_chunk(self, chunk: AudioChunk) -> Optional[TranscriptResult]:
        """Transcribe audio chunk using Whisper API."""
        # Returns None if chunk is silent
```

### MeetingService Processing Loop

```python
async def _processing_loop(self):
    """Main audio processing loop."""
    async for chunk in self.audio_capture.capture_audio():
        if self._paused:
            continue  # Skip while paused

        result = await self.transcription_service.transcribe_chunk(chunk)
        if result and result.text.strip():
            # Store transcript
            transcript = await self._store_transcript(result, chunk.source)

            # Broadcast to WebSocket
            await self.websocket_manager.broadcast_to_meeting(
                self.meeting_id,
                {"type": "transcript", "data": transcript_dict}
            )

            # Buffer for summarization
            self._transcript_buffer.append(result.text)

            # Trigger question detection
            await self._check_for_questions(result.text)
```

### WebSocketManager Interface

```python
class WebSocketManager:
    async def broadcast_to_meeting(self, meeting_id: str, message: dict):
        """Broadcast message to all connections in a meeting room."""

    async def connect(self, websocket: WebSocket, meeting_id: str):
        """Add connection to meeting room."""

    async def disconnect(self, websocket: WebSocket, meeting_id: str):
        """Remove connection from meeting room."""
```

---

## WebSocket Events

### Transcript Event (preserve this format)

```json
{
  "type": "transcript",
  "data": {
    "id": "uuid-string",
    "text": "transcribed text here",
    "timestamp": 45.5,
    "speaker": "system",
    "created_at": "2024-01-15T10:30:00Z"
  }
}
```

### Meeting Status Event

```json
{
  "type": "meeting_status",
  "data": {
    "status": "paused",
    "meeting_id": "uuid-string"
  }
}
```

---

## Patterns to Preserve

### 1. Dual-Channel Speaker Attribution

The `chunk.source` field distinguishes system audio (meeting participants) from user microphone:

```python
# Current pattern - PRESERVE
transcript.speaker = chunk.source  # "system" or "user"
```

With Realtime API, maintain separate connections or track source metadata.

### 2. Pause/Resume Flow

```python
# Current pause handling - PRESERVE
if self._paused:
    continue  # Skip processing while paused

# Pause method
async def pause_meeting(self):
    self._paused = True
    await self.websocket_manager.broadcast_to_meeting(
        self.meeting_id,
        {"type": "meeting_status", "data": {"status": "paused", ...}}
    )
```

With Realtime API: stop sending audio to WebSocket while paused.

### 3. Transcript Buffering for Summarization

```python
# Current buffering - PRESERVE
self._transcript_buffer.append(result.text)

# Every SUMMARY_INTERVAL seconds:
if self._transcript_buffer:
    summary = await self.llm_service.generate_summary(self._transcript_buffer)
    self._transcript_buffer.clear()
```

### 4. Question Detection Trigger

```python
# Current trigger - PRESERVE
await self._check_for_questions(result.text)
```

With Realtime API: trigger on `completed` events, not deltas.

### 5. Silence Detection

Current: RMS threshold check before API call
```python
if self._is_silent(chunk):
    return None
```

With Realtime API: Server VAD handles this automatically. Remove local silence detection.

---

## Files to Modify

| File | Changes |
|------|---------|
| `backend/app/services/transcription.py` | Replace with RealtimeTranscriptionService |
| `backend/app/services/meeting_service.py` | Update _processing_loop for streaming events |
| `backend/app/config.py` | Add REALTIME_MODEL, VAD settings |
| `backend/requirements.txt` | Add websocket-client, scipy |
