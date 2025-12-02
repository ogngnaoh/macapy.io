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
                "Authorization": f"Bearer {self.api_key[:10]}...{self.api_key[-4:]}",  # Masked for logging
                "OpenAI-Beta": "realtime=v1"
            }

            logger.info(f"=== Realtime API Connection ===")
            logger.info(f"URL: {url}")
            logger.info(f"Model: {self.config.model}")
            logger.debug(f"Headers: OpenAI-Beta=realtime=v1")

            # Create SSL context with certifi's CA bundle to avoid SSL errors on macOS
            ssl_context = ssl.create_default_context(cafile=certifi.where())

            # Restore full API key for actual connection
            actual_headers = {
                "Authorization": f"Bearer {self.api_key}",
                "OpenAI-Beta": "realtime=v1"
            }

            self.ws = await websockets.connect(
                url,
                additional_headers=actual_headers,
                ping_interval=20,
                ping_timeout=20,
                close_timeout=10,
                ssl=ssl_context
            )
            logger.info(f"WebSocket connected, waiting for session.created event...")

            # Wait for session.created event before proceeding
            try:
                first_message = await asyncio.wait_for(self.ws.recv(), timeout=10.0)
                event = json.loads(first_message)
                logger.info(f"First event received: type={event.get('type')}")

                if event.get('type') == 'session.created':
                    self.session_id = event.get('session', {}).get('id')
                    session_info = event.get('session', {})
                    logger.info(f"Session created successfully!")
                    logger.info(f"  Session ID: {self.session_id}")
                    logger.info(f"  Expires at: {session_info.get('expires_at', 'N/A')}")
                    logger.debug(f"  Full session config: {json.dumps(session_info, default=str)[:500]}")
                elif event.get('type') == 'error':
                    error_info = event.get('error', {})
                    logger.error(f"Session creation failed: {error_info.get('code')} - {error_info.get('message')}")
                    self.state = ConnectionState.ERROR
                    return False
                else:
                    logger.warning(f"Unexpected first event: {event.get('type')}")
            except asyncio.TimeoutError:
                logger.error("Timeout waiting for session.created event")
                self.state = ConnectionState.ERROR
                return False

            # Configure session for transcription
            await self._configure_session()

            # Start receiving events
            self._receive_task = asyncio.create_task(self._receive_loop())

            self.state = ConnectionState.CONNECTED
            logger.info("=== Realtime API Ready ===")
            return True

        except websockets.exceptions.InvalidStatusCode as e:
            logger.error(f"WebSocket connection rejected: HTTP {e.status_code}")
            if e.status_code == 401:
                logger.error("Authentication failed - check OPENAI_API_KEY")
            elif e.status_code == 404:
                logger.error(f"Model not found - check model ID: {self.config.model}")
            self.state = ConnectionState.ERROR
            return False
        except Exception as e:
            logger.error(f"Failed to connect to Realtime API: {type(e).__name__}: {e}", exc_info=True)
            self.state = ConnectionState.ERROR
            return False

    async def _configure_session(self):
        """Configure the Realtime API session for transcription-only mode."""
        if not self.ws:
            return

        # Session configuration optimized for transcription-only
        # We disable response generation since we only need transcription
        session_config = {
            "type": "session.update",
            "session": {
                "modalities": ["audio", "text"],  # Audio input, text output
                "input_audio_format": "pcm16",  # 24kHz 16-bit PCM mono
                "input_audio_transcription": {
                    "model": "whisper-1"  # Use Whisper for transcription
                },
                "turn_detection": {
                    "type": self.config.turn_detection_type,
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": self.config.silence_duration_ms,
                    "create_response": False  # Don't generate AI response, just transcribe
                },
                # Disable response generation - we only want transcription
                "instructions": "",
                "tools": []
            }
        }

        logger.info("Sending session configuration for transcription-only mode...")
        logger.debug(f"Session config: {json.dumps(session_config, indent=2)}")

        await self.ws.send(json.dumps(session_config))

        # Wait for session.updated confirmation
        try:
            message = await asyncio.wait_for(self.ws.recv(), timeout=5.0)
            event = json.loads(message)
            if event.get('type') == 'session.updated':
                logger.info("Session configuration confirmed (session.updated received)")
                logger.debug(f"Updated session: {json.dumps(event.get('session', {}), default=str)[:500]}")
            else:
                logger.warning(f"Unexpected response to session.update: {event.get('type')}")
                # Log full event for debugging
                logger.debug(f"Full event: {json.dumps(event, default=str)[:500]}")
        except asyncio.TimeoutError:
            logger.warning("No confirmation received for session.update (timeout)")
        except Exception as e:
            logger.warning(f"Error waiting for session.update confirmation: {e}")

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
        """Handle events from Realtime API with comprehensive logging."""
        event_type = event.get("type", "")

        # Log ALL events for debugging (categorized by importance)
        if event_type.startswith("conversation.item") or event_type.startswith("input_audio"):
            # Important events - log at info level with details
            logger.info(f"Realtime event: {event_type}")
            # Log transcript/audio related data
            if "transcription" in event_type:
                transcript = event.get("transcript", event.get("delta", ""))
                if transcript:
                    logger.info(f"  Transcript: '{transcript[:100]}{'...' if len(transcript) > 100 else ''}'")
        elif event_type.startswith("error"):
            # Error events - always log
            logger.error(f"Realtime event: {event_type}")
        else:
            # Other events - debug level
            logger.debug(f"Realtime event: {event_type}")

        if event_type == "session.created":
            self.session_id = event.get("session", {}).get("id")
            logger.info(f"Session created: {self.session_id}")

        elif event_type == "session.updated":
            logger.info("Session configuration updated successfully")

        elif event_type == "conversation.item.input_audio_transcription.completed":
            # Final transcription for an audio segment
            transcript_text = event.get("transcript", "")
            item_id = event.get("item_id", "")

            logger.info(f"=== TRANSCRIPTION COMPLETE ===")
            logger.info(f"  Item ID: {item_id}")
            logger.info(f"  Text: '{transcript_text[:100]}{'...' if len(transcript_text) > 100 else ''}'")
            logger.info(f"  Length: {len(transcript_text)} chars")

            if transcript_text:
                transcript = TranscriptDelta(
                    text=transcript_text,
                    is_final=True,
                    item_id=item_id,
                    timestamp=asyncio.get_event_loop().time()
                )

                await self._transcript_queue.put(transcript)
                logger.debug(f"  Added to transcript queue (queue size: {self._transcript_queue.qsize()})")

                if self._on_transcript:
                    self._on_transcript(transcript)
            else:
                logger.warning("  Empty transcript received!")

        elif event_type == "conversation.item.input_audio_transcription.delta":
            # Streaming partial transcript
            delta_text = event.get("delta", "")
            item_id = event.get("item_id", "")

            if delta_text:
                logger.debug(f"Transcript delta: '{delta_text[:50]}...' (item: {item_id})")
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
            logger.info("VAD: Speech STARTED")

        elif event_type == "input_audio_buffer.speech_stopped":
            logger.info("VAD: Speech STOPPED")

        elif event_type == "input_audio_buffer.committed":
            logger.debug("Audio buffer committed by server")

        elif event_type == "input_audio_buffer.cleared":
            logger.debug("Audio buffer cleared")

        elif event_type == "error":
            error_info = event.get("error", {})
            error_msg = error_info.get("message", "Unknown error")
            error_code = error_info.get("code", "unknown")
            error_type = error_info.get("type", "unknown")

            logger.error(f"=== REALTIME API ERROR ===")
            logger.error(f"  Code: {error_code}")
            logger.error(f"  Type: {error_type}")
            logger.error(f"  Message: {error_msg}")
            logger.error(f"  Full error: {json.dumps(error_info, default=str)}")

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
    Resample audio to 24kHz for Realtime API using high-quality resampling.

    Uses scipy.signal.resample_poly for better quality integer-ratio resampling.
    16kHz -> 24kHz is a 3/2 ratio which resample_poly handles efficiently.

    Args:
        audio_data: Input audio as numpy array (float32 or int16)
        orig_sample_rate: Original sample rate (e.g., 16000)

    Returns:
        Resampled audio at 24kHz as float32
    """
    from scipy.signal import resample_poly
    import math

    target_rate = settings.REALTIME_SAMPLE_RATE  # 24000

    if orig_sample_rate == target_rate:
        logger.debug(f"resample_to_24khz: no resampling needed (already {target_rate}Hz)")
        return audio_data.astype(np.float32) if audio_data.dtype != np.float32 else audio_data

    # Calculate integer ratio using GCD for optimal quality
    gcd = math.gcd(target_rate, orig_sample_rate)
    up = target_rate // gcd  # 3 for 16kHz -> 24kHz
    down = orig_sample_rate // gcd  # 2 for 16kHz -> 24kHz

    logger.debug(f"resample_to_24khz: {orig_sample_rate}Hz -> {target_rate}Hz (ratio: {up}/{down}, "
                f"input_samples={len(audio_data)})")

    # resample_poly provides better quality than generic resample
    # It uses polyphase filtering which preserves audio quality better
    try:
        resampled = resample_poly(audio_data, up, down)
        logger.debug(f"resample_to_24khz: output_samples={len(resampled)}")
        return resampled.astype(np.float32)
    except Exception as e:
        # Fallback to generic resample if resample_poly fails
        logger.warning(f"resample_to_24khz: resample_poly failed, using fallback: {e}")
        from scipy import signal
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
