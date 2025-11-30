---
name: realtime-transcription
description: |
  Refactor macapy.io's transcription system from batch Whisper API to OpenAI's Realtime API
  for real-time transcription with sub-500ms latency. Use when: (1) migrating transcription.py
  to use WebSocket streaming, (2) updating meeting_service.py processing loop for realtime
  events, (3) implementing VAD-based turn detection, (4) debugging Realtime API connections.
---

# Realtime Transcription Migration

Migrate macapy.io from batch Whisper API (3-5s latency) to Realtime API WebSocket (sub-500ms latency).

## Files to Modify

| File | Change Type |
|------|-------------|
| `backend/app/services/transcription.py` | Complete rewrite |
| `backend/app/services/meeting_service.py` | Moderate changes |
| `backend/app/config.py` | Add realtime config |
| `backend/requirements.txt` | Add dependencies |

## Migration Workflow

### Step 1: Add Dependencies

Add to `backend/requirements.txt`:
```
websocket-client>=1.6.0
scipy>=1.11.0
```

### Step 2: Update Config

Add to `backend/app/config.py`:
```python
# Realtime API settings
REALTIME_MODEL: str = "gpt-4o-transcribe"
VAD_THRESHOLD: float = 0.5
VAD_SILENCE_MS: int = 700  # Higher for meetings
NOISE_REDUCTION: str = "near_field"
```

### Step 3: Rewrite TranscriptionService

Replace `transcription.py` with `RealtimeTranscriptionService`:

```python
import asyncio
import base64
import json
import threading
from typing import AsyncIterator, Callable, Optional
import numpy as np
from scipy import signal
import websocket

from app.config import settings

class RealtimeTranscriptionService:
    """Real-time transcription using OpenAI Realtime API."""

    def __init__(self, on_transcript: Callable[[str, str], None]):
        """
        Args:
            on_transcript: Callback(item_id, text) for completed transcripts
        """
        self.on_transcript = on_transcript
        self._ws: Optional[websocket.WebSocket] = None
        self._running = False
        self._current_source = "system"  # Track audio source

    def connect(self):
        """Establish WebSocket connection."""
        url = "wss://api.openai.com/v1/realtime?intent=transcription"
        self._ws = websocket.WebSocket()
        self._ws.connect(url, header=[
            f"Authorization: Bearer {settings.OPENAI_API_KEY}"
        ])
        self._running = True
        self._configure_session()
        threading.Thread(target=self._receive_loop, daemon=True).start()

    def _configure_session(self):
        """Send session configuration."""
        self._ws.send(json.dumps({
            "type": "transcription_session.update",
            "input_audio_format": "pcm16",
            "input_audio_transcription": {
                "model": settings.REALTIME_MODEL,
                "language": "en"
            },
            "turn_detection": {
                "type": "server_vad",
                "threshold": settings.VAD_THRESHOLD,
                "prefix_padding_ms": 300,
                "silence_duration_ms": settings.VAD_SILENCE_MS
            },
            "input_audio_noise_reduction": {
                "type": settings.NOISE_REDUCTION
            }
        }))

    def _receive_loop(self):
        """Background thread to receive WebSocket messages."""
        while self._running:
            try:
                message = self._ws.recv()
                if message:
                    self._handle_event(json.loads(message))
            except Exception as e:
                if self._running:
                    print(f"WebSocket error: {e}")
                break

    def _handle_event(self, event: dict):
        """Handle incoming Realtime API events."""
        event_type = event.get("type")

        if event_type == "conversation.item.input_audio_transcription.completed":
            item_id = event.get("item_id", "")
            transcript = event.get("transcript", "")
            if transcript.strip():
                self.on_transcript(item_id, transcript)

    def send_audio(self, chunk_data: np.ndarray, source: str):
        """
        Send audio chunk to Realtime API.

        Args:
            chunk_data: float32 numpy array at 16kHz
            source: "system" or "user"
        """
        if not self._ws or not self._running:
            return

        self._current_source = source
        pcm16_24k = self._resample_16k_to_24k(chunk_data)
        audio_b64 = base64.b64encode(pcm16_24k).decode("utf-8")

        self._ws.send(json.dumps({
            "type": "input_audio_buffer.append",
            "audio": audio_b64
        }))

    def _resample_16k_to_24k(self, audio_float32: np.ndarray) -> bytes:
        """Convert 16kHz float32 to 24kHz PCM16."""
        num_samples = int(len(audio_float32) * 24000 / 16000)
        audio_24k = signal.resample(audio_float32, num_samples)
        audio_int16 = np.clip(audio_24k * 32767, -32768, 32767).astype(np.int16)
        return audio_int16.tobytes()

    def disconnect(self):
        """Close WebSocket connection."""
        self._running = False
        if self._ws:
            self._ws.close()
            self._ws = None
```

### Step 4: Update MeetingService

Modify `_processing_loop()` in `meeting_service.py`:

```python
async def _processing_loop(self):
    """Main audio processing loop with Realtime API."""

    def on_transcript(item_id: str, text: str):
        """Callback when transcript completes."""
        asyncio.run_coroutine_threadsafe(
            self._handle_transcript(item_id, text, self._current_source),
            self._loop
        )

    # Connect to Realtime API
    self.transcription_service = RealtimeTranscriptionService(on_transcript)
    self.transcription_service.connect()
    self._loop = asyncio.get_event_loop()
    self._current_source = "system"

    try:
        async for chunk in self.audio_capture.capture_audio():
            if self._paused:
                continue  # Skip while paused (don't send audio)

            self._current_source = chunk.source
            self.transcription_service.send_audio(chunk.data, chunk.source)
    finally:
        self.transcription_service.disconnect()

async def _handle_transcript(self, item_id: str, text: str, source: str):
    """Handle completed transcript from Realtime API."""
    # Store in database
    transcript = Transcript(
        meeting_id=self.meeting_id,
        speaker=source,
        text=text,
        timestamp=time.time() - self._start_time
    )
    self.db.add(transcript)
    await self.db.commit()

    # Broadcast to WebSocket
    await self.websocket_manager.broadcast_to_meeting(
        str(self.meeting_id),
        {
            "type": "transcript",
            "data": {
                "id": str(transcript.id),
                "text": text,
                "timestamp": transcript.timestamp,
                "speaker": source,
                "created_at": transcript.created_at.isoformat()
            }
        }
    )

    # Buffer for summarization
    self._transcript_buffer.append(text)

    # Trigger question detection
    await self._check_for_questions(text)
```

## Key Changes Summary

| Aspect | Before (Whisper) | After (Realtime API) |
|--------|------------------|----------------------|
| Latency | 3-5 seconds | sub-500ms |
| Connection | HTTP per chunk | Persistent WebSocket |
| Audio format | 16kHz WAV file | 24kHz PCM16 stream |
| Silence detection | Local RMS check | Server VAD |
| Response | Full transcript | Streaming deltas |

## Preserved Patterns

- **Speaker attribution**: `chunk.source` ("system"/"user") mapped to transcript
- **Pause/resume**: Skip `send_audio()` while paused
- **Transcript buffering**: Still buffer for summarization
- **Question detection**: Trigger on completed transcripts
- **WebSocket events**: Same `transcript` event format to frontend

## References

- [Realtime API Reference](references/realtime-api-reference.md) - API details, events, VAD config
- [macapy.io Architecture](references/macapy-architecture.md) - Current patterns to preserve
