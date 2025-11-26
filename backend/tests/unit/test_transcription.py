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

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from app.services.audio_capture import AudioCaptureService
from app.services.transcription import TranscriptionService
from app.config import settings

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


async def test_transcription_basic():
    """
    Test transcription service with live dual audio capture.

    This test will:
    1. Start audio capture from System Audio AND Microphone
    2. Capture audio for 10 seconds
    3. Transcribe each chunk in real-time
    4. Print transcripts as they arrive
    """
    logger.info("=" * 60)
    logger.info("TRANSCRIPTION SERVICE TEST (DUAL CAPTURE)")
    logger.info("=" * 60)
    logger.info("This will capture audio from System Audio AND Microphone for 10 seconds")
    logger.info("Play some audio and speak clearly to test...")
    logger.info("=" * 60)

    # Initialize services
    audio_service = AudioCaptureService()
    transcription_service = TranscriptionService()

    transcripts = []
    chunk_count = 0

    try:
        # Start audio capture using async generator
        logger.info("\nStarting audio capture...")
        logger.info("✓ Audio capture starting (recording for 10 seconds)")

        # Capture and transcribe for 10 seconds
        start_time = asyncio.get_event_loop().time()

        async for chunk in audio_service.capture_audio(auto_select_loopback=True, auto_select_mic=True):
            # Check if we've exceeded 10 seconds
            if (asyncio.get_event_loop().time() - start_time) >= 10.0:
                break

            chunk_count += 1
            logger.info(
                f"\n[Chunk {chunk_count}] Audio level: {chunk.audio_level:.4f}, "
                f"Duration: {chunk.duration:.2f}s"
            )

            # Transcribe chunk
            result = await transcription_service.transcribe_chunk(chunk)

            if result:
                transcripts.append(result)
                logger.info(f"✓ TRANSCRIPT: '{result.text}'")
            else:
                logger.info("  (Silent or failed)")

        logger.info("\n" + "=" * 60)
        logger.info("TEST COMPLETED")
        logger.info("=" * 60)
        logger.info(f"Total chunks captured: {chunk_count}")
        logger.info(f"Total transcripts: {len(transcripts)}")

        if transcripts:
            logger.info("\nFull Transcript:")
            logger.info("-" * 60)
            for i, result in enumerate(transcripts, 1):
                logger.info(f"{i}. {result.text}")
            logger.info("-" * 60)

            # Combine all transcripts
            full_text = " ".join(t.text for t in transcripts)
            logger.info(f"\nCombined: {full_text}")
        else:
            logger.warning("\n⚠ No transcripts were generated!")
            logger.warning("Possible reasons:")
            logger.warning("  - Audio level too low (silence)")
            logger.warning("  - Microphone not working")
            logger.warning("  - OpenAI API key invalid")
            logger.warning("  - Network issues")

    except KeyboardInterrupt:
        logger.info("\nTest interrupted by user")

    except Exception as e:
        logger.error(f"\nTest failed with error: {e}", exc_info=True)
        raise

    finally:
        # Cleanup
        logger.info("\nCleaning up...")
        await audio_service.stop_capture()
        await transcription_service.close()
        logger.info("✓ Cleanup complete")


async def test_transcription_silent_chunk():
    """
    Test that silent chunks are properly skipped.
    """
    import numpy as np
    from app.services.audio_capture import AudioChunk

    logger.info("\n" + "=" * 60)
    logger.info("SILENT CHUNK")
    logger.info("=" * 60)

    transcription_service = TranscriptionService()

    # Create a silent audio chunk (all zeros)
    silent_audio = np.zeros(16000, dtype=np.float32)  # 1 second of silence
    silent_chunk = AudioChunk(
        data=silent_audio,
        timestamp=0.0,
        duration=1.0,
        sample_rate=16000,
        channels=1,
        audio_level=0.0  # Silent
    )

    logger.info("Testing silent chunk (audio_level=0.0)...")
    result = await transcription_service.transcribe_chunk(silent_chunk)

    if result is None:
        logger.info("✓ PASSED: Silent chunk was correctly skipped")
    else:
        logger.error(f"✗ FAILED: Silent chunk returned: {result.text}")

    await transcription_service.close()


async def test_transcription_noise_chunk():
    """
    Test transcription with synthetic noise.
    """
    import numpy as np
    from app.services.audio_capture import AudioChunk

    logger.info("\n" + "=" * 60)
    logger.info("NOISE CHUNK TEST")
    logger.info("=" * 60)

    transcription_service = TranscriptionService()

    # Create a noise chunk (random audio)
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
        logger.info("  (Likely empty or gibberish - that's expected for random noise)")
    else:
        logger.info("  No transcription (Whisper returned empty)")

    await transcription_service.close()


async def test_config_validation():
    """
    Test that configuration is properly loaded.
    """
    logger.info("\n" + "=" * 60)
    logger.info("CONFIGURATION TEST")
    logger.info("=" * 60)

    logger.info(f"OpenAI API Key present: {'Yes' if settings.OPENAI_API_KEY else 'NO - MISSING!'}")
    logger.info(f"Whisper Model: {settings.WHISPER_MODEL}")
    logger.info(f"Audio Sample Rate: {settings.AUDIO_SAMPLE_RATE}")

    if not settings.OPENAI_API_KEY:
        logger.error("\n✗ FAILED: OPENAI_API_KEY not found in .env file")
        logger.error("Please add OPENAI_API_KEY=sk-... to your .env file")
        return False

    logger.info("\n✓ PASSED: Configuration is valid")
    return True


# Main test runner
async def run_all_tests():
    """Run all tests in sequence."""
    logger.info("\n" + "=" * 60)
    logger.info("RUNNING ALL TRANSCRIPTION TESTS")
    logger.info("=" * 60)

    # Test 1: Configuration
    if not await test_config_validation():
        logger.error("Configuration test failed - aborting remaining tests")
        return

    # Test 2: Silent chunk handling
    await test_transcription_silent_chunk()

    # Test 3: Noise chunk handling
    await test_transcription_noise_chunk()

    # Test 4: Live audio transcription (interactive)
    logger.info("\n" + "=" * 60)
    logger.info("Ready for live audio test?")
    logger.info("This will record for 10 seconds. Press Ctrl+C to skip.")
    logger.info("=" * 60)
    await asyncio.sleep(2)

    try:
        await test_transcription_basic()
    except KeyboardInterrupt:
        logger.info("\nLive audio test skipped by user")

    logger.info("\n" + "=" * 60)
    logger.info("ALL TESTS COMPLETED")
    logger.info("=" * 60)


if __name__ == "__main__":
    """
    Run tests directly (not via pytest).

    Usage:
        python backend/tests/test_transcription.py
    """
    asyncio.run(run_all_tests())


# Pytest test functions (for running with pytest)
def test_config():
    """Pytest wrapper for config test."""
    asyncio.run(test_config_validation())


def test_silent():
    """Pytest wrapper for silent chunk test."""
    asyncio.run(test_transcription_silent_chunk())


def test_noise():
    """Pytest wrapper for noise chunk test."""
    asyncio.run(test_transcription_noise_chunk())


def test_live():
    """Pytest wrapper for live transcription test."""
    asyncio.run(test_transcription_basic())
