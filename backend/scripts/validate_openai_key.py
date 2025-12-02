"""
Quick validation script to test OpenAI API key.
This creates a minimal audio file and tests the Whisper API.

Usage:
    python backend/tests/validate_openai_key.py
"""

import asyncio
import logging
import sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.services.transcription import TranscriptionService
from app.services.audio_capture import AudioChunk
from app.config import settings

logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger(__name__)


async def validate_api_key():
    """Test if OpenAI API key is valid."""

    logger.info("=" * 60)
    logger.info("OPENAI API KEY VALIDATION")
    logger.info("=" * 60)

    # Check if key is set
    if not settings.OPENAI_API_KEY:
        logger.error("❌ OPENAI_API_KEY is not set in .env file")
        logger.error("Please add your API key to .env:")
        logger.error("  OPENAI_API_KEY=sk-proj-...")
        return False

    if settings.OPENAI_API_KEY == "sk-your-api-key-here":
        logger.error("❌ OPENAI_API_KEY is still the placeholder value")
        logger.error("Please replace it with your actual API key from:")
        logger.error("  https://platform.openai.com/api-keys")
        return False

    logger.info(f"✓ API key found: {settings.OPENAI_API_KEY[:10]}...{settings.OPENAI_API_KEY[-4:]}")

    # Create a test audio chunk with a 440Hz tone (A note)
    # This creates a clear, recognizable signal that Whisper can process
    logger.info("\nGenerating test audio (440Hz tone, 1 second)...")
    duration = 1.0
    sample_rate = 16000
    t = np.linspace(0, duration, int(sample_rate * duration), endpoint=False)
    frequency = 440.0  # A note
    audio_data = (0.3 * np.sin(2 * np.pi * frequency * t)).astype(np.float32)

    test_chunk = AudioChunk(
        data=audio_data,
        timestamp=0.0,
        duration=duration,
        sample_rate=sample_rate,
        channels=1,
        audio_level=0.3
    )

    # Try to transcribe
    logger.info("Testing Whisper API...")
    transcription_service = TranscriptionService()

    try:
        result = await transcription_service.transcribe_chunk(test_chunk)

        if result:
            logger.info(f"✓ API call successful!")
            logger.info(f"  Response: '{result.text}'")
            logger.info(f"  (Note: Result may be empty/gibberish for a pure tone - that's OK)")
        else:
            logger.info("✓ API call successful (returned empty result for tone)")

        await transcription_service.close()

        logger.info("\n" + "=" * 60)
        logger.info("✅ VALIDATION PASSED")
        logger.info("=" * 60)
        logger.info("Your OpenAI API key is working correctly!")
        logger.info("You can now proceed with testing the full transcription service.")
        return True

    except Exception as e:
        logger.error(f"\n❌ VALIDATION FAILED")
        logger.error(f"Error: {e}")

        if "401" in str(e) or "Unauthorized" in str(e):
            logger.error("\nYour API key is invalid or expired.")
            logger.error("Please check:")
            logger.error("  1. The key is copied correctly (no extra spaces)")
            logger.error("  2. The key hasn't been revoked")
            logger.error("  3. You have access to the Whisper API")
        elif "429" in str(e) or "rate_limit" in str(e):
            logger.error("\nRate limit exceeded.")
            logger.error("Please wait a moment and try again.")
        elif "quota" in str(e).lower():
            logger.error("\nYou've exceeded your API quota.")
            logger.error("Please check your OpenAI billing settings.")
        else:
            logger.error("\nUnexpected error. Please check your internet connection.")

        await transcription_service.close()
        return False


if __name__ == "__main__":
    success = asyncio.run(validate_api_key())
    sys.exit(0 if success else 1)
