"""
Realtime Transcription Service using OpenAI Realtime API.

This service provides low-latency streaming transcription using OpenAI's
Realtime API via WebSocket connection.

Key features:
- WebSocket-based streaming transcription
- Voice Activity Detection (VAD) for natural sentence boundaries
- Automatic reconnection on connection loss
- Fallback to batch Whisper API if Realtime fails

Audio requirements:
- Sample rate: 24kHz (mono)
- Format: Raw PCM int16 or base64 encoded

Reference: https://platform.openai.com/docs/guides/realtime
"""

import asyncio
import base64
import json
import logging
from typing import AsyncGenerator, Optional, Callable, List
from dataclasses import dataclass
from enum import Enum

import numpy as np
import ssl
import certifi

try:
    import websockets
    from websockets.client import WebSocketClientProtocol
    WEBSOCKETS_AVAILABLE = True
except ImportError:
    WEBSOCKETS_AVAILABLE = False

from app.config import settings

logger = logging.getLogger(__name__)


class ConnectionState(Enum):
    """WebSocket connection states"""
    DISCONNECTED = "disconnected"
    CONNECTING = "connecting"
    CONNECTED = "connected"
    RECONNECTING = "reconnecting"
    ERROR = "error"


@dataclass
class TranscriptDelta:
    """Streaming transcript update from Realtime API"""
    text: str
    is_final: bool
    item_id: str
    timestamp: float


@dataclass
class RealtimeConfig:
    """Configuration for Realtime API session"""
    model: str = settings.REALTIME_MODEL
    voice: str = "alloy"  # Not used for transcription-only, but required
    turn_detection_type: str = "server_vad"  # Server-side Voice Activity Detection
    silence_duration_ms: int = 500  # Silence threshold for end of speech
    temperature: float = 0.6
    max_response_output_tokens: int = 4096


class RealtimeTranscriptionService:
    """
    Service for streaming transcription using OpenAI Realtime API.

    This service maintains a WebSocket connection to OpenAI's Realtime API
    and streams audio for real-time transcription.

    Usage:
        service = RealtimeTranscriptionService()
        await service.connect()

        # Send audio chunks
        await service.send_audio(audio_bytes)

        # Receive transcripts
        async for transcript in service.receive_transcripts():
            print(transcript.text)

        await service.close()
    """

    def __init__(
        self,
        api_key: str = settings.OPENAI_API_KEY,
        config: Optional[RealtimeConfig] = None
    ):
        if not WEBSOCKETS_AVAILABLE:
            raise ImportError(
                "websockets package required for Realtime API. "
                "Install with: pip install websockets"
            )

        self.api_key = api_key
        self.config = config or RealtimeConfig()

        self.ws: Optional[WebSocketClientProtocol] = None
        self.state = ConnectionState.DISCONNECTED
        self._receive_task: Optional[asyncio.Task] = None
        self._transcript_queue: asyncio.Queue = asyncio.Queue()

        # Session state
        self.session_id: Optional[str] = None
        self._current_item_id: Optional[str] = None
        self._accumulated_text: str = ""

        # Callbacks
        self._on_transcript: Optional[Callable[[TranscriptDelta], None]] = None
        self._on_error: Optional[Callable[[str], None]] = None

        # Reconnection settings
        self._max_reconnect_attempts = 5
        self._reconnect_delay = 1.0

        logger.info(f"RealtimeTranscriptionService initialized with model: {self.config.model}")

    @property
    def is_connected(self) -> bool:
        return self.state == ConnectionState.CONNECTED and self.ws is not None

    async def connect(self) -> bool:
        """
        Establish WebSocket connection to OpenAI Realtime API.

        Returns:
            True if connection successful, False otherwise
        """
        if self.is_connected:
            logger.warning("Already connected to Realtime API")
            return True

        self.state = ConnectionState.CONNECTING

        try:
            url = f"wss://api.openai.com/v1/realtime?model={self.config.model}"
            headers = {
                "Authorization": f"Bearer {self.api_key}",
                "OpenAI-Beta": "realtime=v1"
            }

            logger.info(f"Connecting to Realtime API: {url}")

            # Create SSL context with certifi's CA bundle to avoid SSL errors on macOS
            ssl_context = ssl.create_default_context(cafile=certifi.where())

            self.ws = await websockets.connect(
                url,
                additional_headers=headers,
                ping_interval=20,
                ping_timeout=20,
                close_timeout=10,
                ssl=ssl_context
            )

            # Configure session for transcription
            await self._configure_session()

            # Start receiving events
            self._receive_task = asyncio.create_task(self._receive_loop())

            self.state = ConnectionState.CONNECTED
            logger.info("Connected to Realtime API successfully")
            return True

        except Exception as e:
            logger.error(f"Failed to connect to Realtime API: {e}")
            self.state = ConnectionState.ERROR
            return False

    async def _configure_session(self):
        """Configure the Realtime API session for transcription."""
        if not self.ws:
            return

        # Session configuration
        session_config = {
            "type": "session.update",
            "session": {
                "modalities": ["text", "audio"],  # We want text output from audio input
                "voice": self.config.voice,
                "input_audio_format": "pcm16",  # 24kHz 16-bit PCM
                "output_audio_format": "pcm16",
                "input_audio_transcription": {
                    "model": "whisper-1"  # Use Whisper for transcription
                },
                "turn_detection": {
                    "type": self.config.turn_detection_type,
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": self.config.silence_duration_ms
                },
                "temperature": self.config.temperature,
                "max_response_output_tokens": self.config.max_response_output_tokens
            }
        }

        await self.ws.send(json.dumps(session_config))
        logger.info("Sent session configuration to Realtime API")

    async def send_audio(self, audio_bytes: bytes):
        """
        Send audio data to the Realtime API.

        Args:
            audio_bytes: Raw PCM audio data (24kHz, mono, int16)
        """
        if not self.is_connected:
            logger.warning("Cannot send audio: not connected")
            return

        try:
            # Base64 encode the audio
            audio_b64 = base64.b64encode(audio_bytes).decode('utf-8')

            # Send audio buffer append event
            event = {
                "type": "input_audio_buffer.append",
                "audio": audio_b64
            }

            await self.ws.send(json.dumps(event))

        except Exception as e:
            logger.error(f"Error sending audio: {e}")
            if self._on_error:
                self._on_error(str(e))

    async def send_audio_numpy(self, audio_data: np.ndarray, sample_rate: int = 24000):
        """
        Send numpy audio data to the Realtime API.

        Args:
            audio_data: Numpy array of audio samples (float32 or int16)
            sample_rate: Sample rate of the audio (should be 24000)
        """
        # Convert to int16 if float
        if audio_data.dtype == np.float32 or audio_data.dtype == np.float64:
            audio_int16 = (audio_data * 32767).astype(np.int16)
        else:
            audio_int16 = audio_data.astype(np.int16)

        # Convert to bytes
        audio_bytes = audio_int16.tobytes()

        await self.send_audio(audio_bytes)

    async def commit_audio_buffer(self):
        """
        Signal that the current audio buffer is complete.
        This triggers processing of buffered audio.
        """
        if not self.is_connected:
            return

        try:
            event = {"type": "input_audio_buffer.commit"}
            await self.ws.send(json.dumps(event))
            logger.debug("Committed audio buffer")
        except Exception as e:
            logger.error(f"Error committing audio buffer: {e}")

    async def _receive_loop(self):
        """Background task to receive and process events from Realtime API."""
        logger.debug("Realtime API receive loop started")
        if not self.ws:
            logger.warning("No websocket in receive loop")
            return

        try:
            async for message in self.ws:
                try:
                    event = json.loads(message)
                    await self._handle_event(event)
                except json.JSONDecodeError as e:
                    logger.warning(f"Invalid JSON from Realtime API: {e}")

        except websockets.exceptions.ConnectionClosed as e:
            logger.warning(f"WebSocket connection closed: {e}")
            self.state = ConnectionState.DISCONNECTED
            # Attempt reconnection
            asyncio.create_task(self._reconnect())

        except Exception as e:
            logger.error(f"Error in receive loop: {e}")
            self.state = ConnectionState.ERROR

    async def _handle_event(self, event: dict):
        """Handle events from Realtime API."""
        event_type = event.get("type", "")

        # Log event types for debugging
        logger.debug(f"Received event: {event_type}")

        if event_type == "session.created":
            self.session_id = event.get("session", {}).get("id")
            logger.info(f"Session created: {self.session_id}")

        elif event_type == "session.updated":
            logger.info("Session configuration updated")

        elif event_type == "conversation.item.input_audio_transcription.completed":
            # Final transcription for an audio segment
            transcript_text = event.get("transcript", "")
            item_id = event.get("item_id", "")

            if transcript_text:
                logger.info(f"Transcription completed: '{transcript_text[:50]}...'")
                transcript = TranscriptDelta(
                    text=transcript_text,
                    is_final=True,
                    item_id=item_id,
                    timestamp=asyncio.get_event_loop().time()
                )

                await self._transcript_queue.put(transcript)

                if self._on_transcript:
                    self._on_transcript(transcript)

        elif event_type == "conversation.item.input_audio_transcription.delta":
            # Streaming partial transcript
            delta_text = event.get("delta", "")
            item_id = event.get("item_id", "")

            if delta_text:
                transcript = TranscriptDelta(
                    text=delta_text,
                    is_final=False,
                    item_id=item_id,
                    timestamp=asyncio.get_event_loop().time()
                )

                await self._transcript_queue.put(transcript)

                if self._on_transcript:
                    self._on_transcript(transcript)

        elif event_type == "input_audio_buffer.speech_started":
            logger.debug("Speech started")

        elif event_type == "input_audio_buffer.speech_stopped":
            logger.debug("Speech stopped")

        elif event_type == "input_audio_buffer.committed":
            logger.debug("Audio buffer committed by server")

        elif event_type == "error":
            error_msg = event.get("error", {}).get("message", "Unknown error")
            error_code = event.get("error", {}).get("code", "")
            logger.error(f"Realtime API error [{error_code}]: {error_msg}")

            if self._on_error:
                self._on_error(f"[{error_code}] {error_msg}")

        elif event_type == "rate_limits.updated":
            # Rate limit info - log for monitoring
            limits = event.get("rate_limits", [])
            logger.debug(f"Rate limits updated: {limits}")

    async def receive_transcripts(self) -> AsyncGenerator[TranscriptDelta, None]:
        """
        Async generator that yields transcript updates.

        Yields:
            TranscriptDelta objects with text and metadata
        """
        while self.state in [ConnectionState.CONNECTED, ConnectionState.RECONNECTING]:
            try:
                transcript = await asyncio.wait_for(
                    self._transcript_queue.get(),
                    timeout=1.0
                )
                yield transcript
            except asyncio.TimeoutError:
                # No transcript available, continue waiting
                continue
            except Exception as e:
                logger.error(f"Error receiving transcript: {e}")
                break

    async def _reconnect(self):
        """Attempt to reconnect to the Realtime API."""
        if self.state == ConnectionState.RECONNECTING:
            return

        self.state = ConnectionState.RECONNECTING

        for attempt in range(1, self._max_reconnect_attempts + 1):
            logger.info(f"Reconnection attempt {attempt}/{self._max_reconnect_attempts}")

            await asyncio.sleep(self._reconnect_delay * attempt)

            if await self.connect():
                logger.info("Reconnected successfully")
                return

        logger.error("Failed to reconnect after maximum attempts")
        self.state = ConnectionState.ERROR

    def set_on_transcript(self, callback: Callable[[TranscriptDelta], None]):
        """Set callback for transcript updates."""
        self._on_transcript = callback

    def set_on_error(self, callback: Callable[[str], None]):
        """Set callback for errors."""
        self._on_error = callback

    async def close(self):
        """Close the WebSocket connection and cleanup."""
        logger.info("Closing Realtime API connection")

        self.state = ConnectionState.DISCONNECTED

        # Cancel receive task
        if self._receive_task:
            self._receive_task.cancel()
            try:
                await self._receive_task
            except asyncio.CancelledError:
                pass
            self._receive_task = None

        # Close WebSocket
        if self.ws:
            await self.ws.close()
            self.ws = None

        # Clear queue
        while not self._transcript_queue.empty():
            try:
                self._transcript_queue.get_nowait()
            except asyncio.QueueEmpty:
                break

        self.session_id = None
        logger.info("Realtime API connection closed")


def resample_to_24khz(audio_data: np.ndarray, orig_sample_rate: int) -> np.ndarray:
    """
    Resample audio to 24kHz for Realtime API.

    Args:
        audio_data: Input audio as numpy array
        orig_sample_rate: Original sample rate

    Returns:
        Resampled audio at 24kHz
    """
    from scipy import signal

    target_rate = settings.REALTIME_SAMPLE_RATE  # 24000

    if orig_sample_rate == target_rate:
        return audio_data

    num_samples = int(len(audio_data) * target_rate / orig_sample_rate)
    resampled = signal.resample(audio_data, num_samples)

    return resampled.astype(np.float32)


# Singleton instance
_realtime_service: Optional[RealtimeTranscriptionService] = None


def get_realtime_transcription_service() -> RealtimeTranscriptionService:
    """Get or create the singleton Realtime transcription service."""
    global _realtime_service

    if _realtime_service is None:
        _realtime_service = RealtimeTranscriptionService()

    return _realtime_service
