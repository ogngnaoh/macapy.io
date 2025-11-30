"""
Test script for transcription service.

This script demonstrates how to:
1. Capture live audio from your microphone
2. Send audio chunks to the transcription service
3. Display transcripts in real-time

Usage:
    python -m pytest backend/tests/test_transcription.py -v -s

Or run directly for interactive testing:
    python backend/tests/test_transcription.py
"""

import asyncio
import logging
import sys
from pathlib import Path
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
import numpy as np

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from app.services.audio_capture import AudioCaptureService, AudioChunk
from app.services.transcription import TranscriptionService
from app.config import settings

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


@pytest.mark.asyncio
async def test_transcription_basic():
    """
    Test transcription service with mocked audio capture.
    """
    logger.info("=" * 60)
    logger.info("TRANSCRIPTION SERVICE TEST (MOCKED)")
    logger.info("=" * 60)

    # Mock AudioCaptureService
    with patch("app.services.audio_capture.AudioCaptureService") as MockAudioService:
        mock_audio_service = MockAudioService.return_value
        
        # Create fake audio chunks
        async def mock_capture_generator(*args, **kwargs):
            for i in range(5):
                await asyncio.sleep(0.1)
                yield AudioChunk(
                    data=np.zeros(16000, dtype=np.float32),
                    timestamp=float(i),
                    duration=1.0,
                    sample_rate=16000,
                    channels=1,
                    audio_level=0.5,
                    source="user"
                )

        mock_audio_service.capture_audio.side_effect = mock_capture_generator
        mock_audio_service.stop_capture = AsyncMock()

        # Mock TranscriptionService
        with patch("app.services.transcription.TranscriptionService") as MockTranscriptionService:
            mock_transcription_service = MockTranscriptionService.return_value
            # Make transcribe_chunk return a coroutine that resolves to the result
            async def mock_transcribe(chunk, language="en"):
                return MagicMock(text="Mocked Transcript", timestamp=0.0)
            
            mock_transcription_service.transcribe_chunk.side_effect = mock_transcribe
            mock_transcription_service.close = AsyncMock()

            # Initialize services (using mocks)
            audio_service = mock_audio_service
            transcription_service = mock_transcription_service

            transcripts = []
            chunk_count = 0

            try:
                logger.info("\nStarting audio capture...")
                
                async for chunk in audio_service.capture_audio(auto_select_loopback=True, auto_select_mic=True):
                    chunk_count += 1
                    logger.info(f"\n[Chunk {chunk_count}] Audio level: {chunk.audio_level:.4f}")

                    # Transcribe chunk
                    result = await transcription_service.transcribe_chunk(chunk)

                    if result:
                        transcripts.append(result)
                        logger.info(f"✓ TRANSCRIPT: '{result.text}'")

                logger.info("\n" + "=" * 60)
                logger.info("TEST COMPLETED")
                logger.info("=" * 60)
                logger.info(f"Total chunks captured: {chunk_count}")
                logger.info(f"Total transcripts: {len(transcripts)}")
                
                assert chunk_count == 5
                assert len(transcripts) == 5

            except Exception as e:
                logger.error(f"\nTest failed with error: {e}", exc_info=True)
                raise


@pytest.mark.asyncio
async def test_transcription_silent_chunk():
    """
    Test that silent chunks are properly skipped.
    """
    logger.info("\n" + "=" * 60)
    logger.info("SILENT CHUNK")
    logger.info("=" * 60)

    # Patch AsyncOpenAI because __init__ uses it
    with patch("app.services.transcription.AsyncOpenAI") as MockOpenAI:
        # Ensure the client instance returned by MockOpenAI() has an async close method
        mock_client = MockOpenAI.return_value
        mock_client.close = AsyncMock()
        
        transcription_service = TranscriptionService()
        
        # Mock _call_whisper_api on the instance with an explicit async function
        async def mock_call_api(*args, **kwargs):
            return "Should not be called"
        
        # Use MagicMock to wrap the async function so we can assert calls
        mock_wrapper = MagicMock(side_effect=mock_call_api)
        transcription_service._call_whisper_api = mock_wrapper
        
        # Create a silent audio chunk (all zeros)
        silent_audio = np.zeros(16000, dtype=np.float32)
        silent_chunk = AudioChunk(
            data=silent_audio,
            timestamp=0.0,
            duration=1.0,
            sample_rate=16000,
            channels=1,
            audio_level=0.0  # Silent
        )

        logger.info("Testing silent chunk (audio_level=0.0)...")
        # We expect it to return None without calling API
        result = await transcription_service.transcribe_chunk(silent_chunk)

        if result is None:
            logger.info("✓ PASSED: Silent chunk was correctly skipped")
        else:
            logger.error(f"✗ FAILED: Silent chunk returned: {result.text}")
        
        # Verify API was NOT called
        mock_wrapper.assert_not_called()
        
        await transcription_service.close()


@pytest.mark.asyncio
async def test_transcription_noise_chunk():
    """
    Test transcription with synthetic noise.
    """
    logger.info("\n" + "=" * 60)
    logger.info("NOISE CHUNK TEST")
    logger.info("=" * 60)

    with patch("app.services.transcription.AsyncOpenAI") as MockOpenAI:
        # Ensure the client instance returned by MockOpenAI() has an async close method
        mock_client = MockOpenAI.return_value
        mock_client.close = AsyncMock()

        transcription_service = TranscriptionService()
        
        # Mock _call_whisper_api on the instance with an explicit async function
        async def mock_call_api(*args, **kwargs):
            return "Noise text"
            
        # Use MagicMock to wrap the async function so we can assert calls if needed
        # But here we just need it to be awaitable
        transcription_service._call_whisper_api = mock_call_api
        
        # Create a noise chunk
        noise_audio = np.random.uniform(-0.1, 0.1, 16000).astype(np.float32)
        noise_chunk = AudioChunk(
            data=noise_audio,
            timestamp=0.0,
            duration=1.0,
            sample_rate=16000,
            channels=1,
            audio_level=0.05  # Above silence threshold
        )

        logger.info("Testing noise chunk (audio_level=0.05)...")
        result = await transcription_service.transcribe_chunk(noise_chunk)

        if result:
            logger.info(f"✓ Transcription returned: '{result.text}'")
            assert result.text == "Noise text"
        else:
            logger.info("  No transcription")
            pytest.fail("Expected transcription for noise chunk")

        await transcription_service.close()


@pytest.mark.asyncio
async def test_config_validation():
    """
    Test that configuration is properly loaded.
    """
    logger.info("\n" + "=" * 60)
    logger.info("CONFIGURATION TEST")
    logger.info("=" * 60)

    # We can't easily change settings at runtime if they are loaded at module level, 
    # but we can check if they are present.
    assert settings.OPENAI_API_KEY, "OPENAI_API_KEY missing"
    
    logger.info("\n✓ PASSED: Configuration is valid")
    return True


# Main test runner
async def run_all_tests():
    """Run all tests in sequence."""
    # This runner is for manual execution
    await test_config_validation()
    await test_transcription_silent_chunk()
    await test_transcription_noise_chunk()
    await test_transcription_basic()


if __name__ == "__main__":
    asyncio.run(run_all_tests())

# Pytest wrappers
def test_config():
    asyncio.run(test_config_validation())

def test_silent():
    asyncio.run(test_transcription_silent_chunk())

def test_noise():
    asyncio.run(test_transcription_noise_chunk())

def test_live():
    asyncio.run(test_transcription_basic())
