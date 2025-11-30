# OpenAI Realtime Transcription API Reference

## Table of Contents
- [Connection Setup](#connection-setup)
- [Session Configuration](#session-configuration)
- [Audio Format](#audio-format)
- [Events](#events)
- [VAD Configuration](#vad-configuration)
- [Python Example](#python-example)

---

## Connection Setup

WebSocket URL for transcription-only mode:
```
wss://api.openai.com/v1/realtime?intent=transcription
```

Authentication header:
```
Authorization: Bearer $OPENAI_API_KEY
```

---

## Session Configuration

Transcription session payload (send after connection):
```json
{
  "type": "transcription_session.update",
  "input_audio_format": "pcm16",
  "input_audio_transcription": {
    "model": "gpt-4o-transcribe",
    "prompt": "",
    "language": "en"
  },
  "turn_detection": {
    "type": "server_vad",
    "threshold": 0.5,
    "prefix_padding_ms": 300,
    "silence_duration_ms": 500
  },
  "input_audio_noise_reduction": {
    "type": "near_field"
  },
  "include": [
    "item.input_audio_transcription.logprobs"
  ]
}
```

### Key Fields

| Field | Description |
|-------|-------------|
| `input_audio_format` | `pcm16` (24kHz mono required) |
| `input_audio_transcription.model` | `whisper-1`, `gpt-4o-transcribe`, or `gpt-4o-mini-transcribe` |
| `turn_detection.type` | `server_vad` for automatic turn detection |
| `input_audio_noise_reduction.type` | `near_field` (close mic) or `far_field` (distant mic) |

---

## Audio Format

**Required format for Realtime API:**
- Sample rate: **24,000 Hz** (24kHz)
- Channels: **1** (mono)
- Format: **PCM16** (16-bit signed integers)
- Byte order: Little-endian

**Sending audio:**
```json
{
  "type": "input_audio_buffer.append",
  "audio": "Base64EncodedAudioData"
}
```

---

## Events

### Server Events

**Transcript delta (streaming):**
```json
{
  "event_id": "event_123",
  "type": "conversation.item.input_audio_transcription.delta",
  "item_id": "item_003",
  "content_index": 0,
  "delta": "Hello,"
}
```

**Transcript completed:**
```json
{
  "event_id": "event_456",
  "type": "conversation.item.input_audio_transcription.completed",
  "item_id": "item_003",
  "content_index": 0,
  "transcript": "Hello, how are you?"
}
```

**Audio buffer committed (VAD detected speech end):**
```json
{
  "type": "input_audio_buffer.committed",
  "item_id": "item_003",
  "previous_item_id": "item_002"
}
```

### Event Ordering

Use `item_id` and `previous_item_id` from `input_audio_buffer.committed` to order transcripts correctly. Completion events from different turns are not guaranteed to arrive in order.

---

## VAD Configuration

Server VAD settings for meeting scenarios:

| Parameter | Recommended | Description |
|-----------|-------------|-------------|
| `threshold` | 0.5 | Speech detection sensitivity (0.0-1.0) |
| `prefix_padding_ms` | 300 | Audio included before speech start |
| `silence_duration_ms` | 500-800 | Silence before turn ends (meeting: use higher) |

For meetings with multiple speakers, increase `silence_duration_ms` to 700-800ms to avoid cutting off mid-sentence.

---

## Python Example

```python
import os
import json
import base64
import websocket

OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY")

url = "wss://api.openai.com/v1/realtime?intent=transcription"
headers = ["Authorization: Bearer " + OPENAI_API_KEY]

def on_open(ws):
    print("Connected to Realtime API")
    # Configure transcription session
    ws.send(json.dumps({
        "type": "transcription_session.update",
        "input_audio_format": "pcm16",
        "input_audio_transcription": {
            "model": "gpt-4o-transcribe",
            "language": "en"
        },
        "turn_detection": {
            "type": "server_vad",
            "threshold": 0.5,
            "prefix_padding_ms": 300,
            "silence_duration_ms": 700
        },
        "input_audio_noise_reduction": {
            "type": "near_field"
        }
    }))

def on_message(ws, message):
    data = json.loads(message)
    event_type = data.get("type")

    if event_type == "conversation.item.input_audio_transcription.delta":
        print(f"Delta: {data.get('delta', '')}", end="", flush=True)

    elif event_type == "conversation.item.input_audio_transcription.completed":
        print(f"\nCompleted: {data.get('transcript', '')}")

    elif event_type == "input_audio_buffer.committed":
        print(f"Turn ended: {data.get('item_id')}")

def send_audio(ws, pcm16_bytes: bytes):
    """Send audio chunk to Realtime API."""
    audio_base64 = base64.b64encode(pcm16_bytes).decode("utf-8")
    ws.send(json.dumps({
        "type": "input_audio_buffer.append",
        "audio": audio_base64
    }))

ws = websocket.WebSocketApp(
    url,
    header=headers,
    on_open=on_open,
    on_message=on_message,
)

ws.run_forever()
```

---

## Audio Resampling (16kHz to 24kHz)

macapy.io captures at 16kHz but Realtime API requires 24kHz. Use scipy for resampling:

```python
import numpy as np
from scipy import signal

def resample_16k_to_24k(audio_float32: np.ndarray) -> bytes:
    """
    Convert 16kHz float32 audio to 24kHz PCM16.

    Args:
        audio_float32: numpy array of float32 samples (-1.0 to 1.0) at 16kHz

    Returns:
        bytes: PCM16 audio at 24kHz
    """
    # Resample from 16kHz to 24kHz (ratio = 1.5)
    num_samples_24k = int(len(audio_float32) * 24000 / 16000)
    audio_24k = signal.resample(audio_float32, num_samples_24k)

    # Convert float32 (-1.0 to 1.0) to int16 (-32768 to 32767)
    audio_int16 = np.clip(audio_24k * 32767, -32768, 32767).astype(np.int16)

    return audio_int16.tobytes()
```
