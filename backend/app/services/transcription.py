"""
Transcription Service for macapy.io
Uses OpenAI Whisper API to transcribe audio chunks in real-time.
"""

import logging
import io
import wave
import numpy as np
from typing import Optional
from dataclasses import dataclass

from openai import AsyncOpenAI, APIError, APITimeoutError, RateLimitError
from tenacity import (
    retry,
    stop_after_attempt,
    wait_exponential,
    retry_if_exception_type,
)

from app.config import settings
from app.services.audio_capture import AudioChunk

logger = logging.getLogger(__name__)


@dataclass
class TranscriptResult:
    """Result from transcription service."""
    text: str
    language: Optional[str] = None
    duration: float = 0.0
    timestamp: float = 0.0
    confidence: Optional[float] = None


class TranscriptionService:
    """
    Service for transcribing audio chunks using OpenAI Whisper API.

    Features:
    - Real-time transcription of 1-second audio chunks
    - Automatic silence detection to save API costs
    - Retry logic for API failures with exponential backoff
    - Proper audio format conversion for Whisper
    """

    # Silence threshold: Skip chunks below this RMS level (0.0 to 1.0)
    SILENCE_THRESHOLD = 0.01

    def __init__(self, api_key: Optional[str] = None):
        """
        Initialize the transcription service.

        Args:
            api_key: OpenAI API key (defaults to settings.OPENAI_API_KEY)
        """
        self.api_key = api_key or settings.OPENAI_API_KEY
        if not self.api_key:
            raise ValueError("OpenAI API key is required. Set OPENAI_API_KEY in .env")

        # Initialize async OpenAI client
        self.client = AsyncOpenAI(api_key=self.api_key)
        self.model = settings.WHISPER_MODEL

        logger.info(f"TranscriptionService initialized with model: {self.model}")

    async def transcribe_chunk(
        self,
        chunk: AudioChunk,
        language: str = "en"
    ) -> Optional[TranscriptResult]:
        """
        Transcribe an audio chunk using Whisper API.

        Args:
            chunk: AudioChunk from AudioCaptureService
            language: ISO-639-1 language code (default: "en")

        Returns:
            TranscriptResult if successful and audio is not silent
            None if audio is silent or transcription fails after retries

        Note:
            - Skips chunks below SILENCE_THRESHOLD to save API costs
            - Retries up to 3 times with exponential backoff on API failures
            - Whisper API latency is typically 3-5 seconds
        """
        # Skip silent chunks to save API costs and reduce noise
        if chunk.audio_level < self.SILENCE_THRESHOLD:
            logger.debug(
                f"Skipping silent chunk (level: {chunk.audio_level:.4f}, "
                f"threshold: {self.SILENCE_THRESHOLD})"
            )
            return None

        try:
            logger.debug(
                f"Transcribing chunk: duration={chunk.duration}s, "
                f"level={chunk.audio_level:.4f}, timestamp={chunk.timestamp}"
            )

            # Convert audio chunk to WAV format bytes
            wav_bytes = self._chunk_to_wav_bytes(chunk)

            # Send to Whisper API with retry logic
            transcript_text = await self._call_whisper_api(
                wav_bytes,
                language=language
            )

            # Handle empty responses
            if not transcript_text or not transcript_text.strip():
                logger.debug("Whisper returned empty transcript")
                return None

            # Create result object
            result = TranscriptResult(
                text=transcript_text.strip(),
                language=language,
                duration=chunk.duration,
                timestamp=chunk.timestamp,
            )

            logger.info(f"Transcribed: '{result.text[:50]}...' ({len(result.text)} chars)")
            return result

        except Exception as e:
            logger.error(f"Failed to transcribe chunk: {e}", exc_info=True)
            return None

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=2, max=10),
        retry=retry_if_exception_type((APIError, APITimeoutError, RateLimitError)),
        reraise=True,
    )
    async def _call_whisper_api(
        self,
        wav_bytes: bytes,
        language: str = "en"
    ) -> str:
        """
        Call Whisper API with retry logic.

        Args:
            wav_bytes: WAV format audio bytes
            language: ISO-639-1 language code

        Returns:
            Transcript text from Whisper

        Raises:
            APIError: On API errors (retried up to 3 times)

        Retry Strategy:
            - Attempt 1: Immediate
            - Attempt 2: Wait 2 seconds
            - Attempt 3: Wait 4 seconds
            - Then raise exception
        """
        # Create file-like object from bytes
        # Whisper API expects a file with a .wav extension
        audio_file = io.BytesIO(wav_bytes)
        audio_file.name = "audio.wav"  # Required: Whisper checks file extension

        try:
            # Call Whisper API (async)
            # https://platform.openai.com/docs/api-reference/audio/createTranscription
            response = await self.client.audio.transcriptions.create(
                model=self.model,
                file=audio_file,
                language=language,
                response_format="text",  # Simple text response (not JSON/verbose)
                temperature=0.0,  # Deterministic output
            )

            # Response is plain text when response_format="text"
            return response

        except RateLimitError as e:
            logger.warning(f"Whisper API rate limit hit: {e}")
            raise
        except APITimeoutError as e:
            logger.warning(f"Whisper API timeout: {e}")
            raise
        except APIError as e:
            logger.error(f"Whisper API error: {e}")
            raise
        except Exception as e:
            logger.error(f"Unexpected error calling Whisper API: {e}")
            raise

    def _chunk_to_wav_bytes(self, chunk: AudioChunk) -> bytes:
        """
        Convert AudioChunk to WAV format bytes for Whisper API.

        The process:
        1. Convert float32 (-1.0 to 1.0) → int16 (-32768 to 32767)
        2. Wrap in WAV container with proper headers
        3. Return as bytes

        Args:
            chunk: AudioChunk with numpy float32 audio data

        Returns:
            WAV format bytes ready for Whisper API

        Note:
            Whisper expects:
            - 16kHz sample rate (chunk is already 16kHz)
            - Mono audio (chunk is already mono)
            - 16-bit PCM format (we convert from float32)
        """
        # Convert float32 (-1.0 to 1.0) to int16 (-32768 to 32767)
        # Clip to prevent overflow if audio exceeds [-1.0, 1.0] range
        audio_int16 = np.clip(chunk.data * 32768, -32768, 32767).astype(np.int16)

        # Create in-memory WAV file
        wav_buffer = io.BytesIO()

        with wave.open(wav_buffer, 'wb') as wav_file:
            # Set WAV parameters
            wav_file.setnchannels(chunk.channels)  # 1 = mono
            wav_file.setsampwidth(2)  # 2 bytes = 16-bit
            wav_file.setframerate(chunk.sample_rate)  # 16000 Hz

            # Write audio data
            wav_file.writeframes(audio_int16.tobytes())

        # Get bytes from buffer
        wav_bytes = wav_buffer.getvalue()

        logger.debug(
            f"Converted chunk to WAV: {len(wav_bytes)} bytes, "
            f"{chunk.duration}s @ {chunk.sample_rate}Hz"
        )

        return wav_bytes

    async def close(self):
        """
        Clean up resources.

        Note: AsyncOpenAI client handles its own cleanup, but this method
        is provided for consistency and future extensibility.
        """
        await self.client.close()
        logger.info("TranscriptionService closed")


# Singleton instance for use across the application
_transcription_service: Optional[TranscriptionService] = None


def get_transcription_service() -> TranscriptionService:
    """
    Get or create singleton transcription service instance.

    Returns:
        TranscriptionService instance

    Note:
        This pattern ensures we reuse the same OpenAI client instance
        across all requests, which is more efficient.
    """
    global _transcription_service

    if _transcription_service is None:
        _transcription_service = TranscriptionService()

    return _transcription_service
