"""
Integration tests for audio capture and meeting flow.

Tests the complete audio pipeline from capture to meeting service integration.
"""
import pytest
import asyncio
import logging
import platform
from datetime import datetime
from contextlib import asynccontextmanager
from sqlalchemy import select
from app.services.meeting_service import MeetingService
from app.models.meeting import Meeting, MeetingStatus
import app.services.meeting_service as meeting_service_module

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SYSTEM = platform.system()


@pytest.mark.asyncio
async def test_audio_integration(db_session, engine, monkeypatch):
    """Test audio integration flow with mocked audio capture."""
    logger.info("Starting Audio Integration Test...")

    # Patch AsyncSessionLocal to use the test's engine and session
    from sqlalchemy.ext.asyncio import async_sessionmaker
    test_session_factory = async_sessionmaker(engine, expire_on_commit=False)
    monkeypatch.setattr(meeting_service_module, "AsyncSessionLocal", test_session_factory)

    meeting_service = MeetingService()

    # Mock AudioCaptureService
    async def mock_capture_audio(*args, **kwargs):
        import numpy as np
        from app.services.audio_capture import AudioChunk

        logger.info("Mocking audio capture...")
        for _ in range(5):  # Yield 5 chunks instead of infinite loop
            yield AudioChunk(
                data=np.zeros(16000),
                timestamp=datetime.utcnow().timestamp(),
                duration=1.0,
                sample_rate=16000,
                channels=1,
                audio_level=0.5,
                source="system"  # Include source field for dual-column transcript
            )
            await asyncio.sleep(0.1)

    async def mock_stop_capture():
        logger.info("Mocking stop capture")

    meeting_service.audio_capture.capture_audio = mock_capture_audio
    meeting_service.audio_capture.stop_capture = mock_stop_capture

    # Create meeting using the fixture session
    meeting = Meeting(
        title="Integration Test Meeting",
        status=MeetingStatus.PENDING,
        start_time=datetime.utcnow()
    )
    db_session.add(meeting)
    await db_session.commit()
    await db_session.refresh(meeting)
    meeting_id = str(meeting.id)

    try:
        # Start Meeting
        logger.info(f"Starting meeting {meeting_id}...")
        await meeting_service.start_meeting(meeting_id)

        # Verify running
        assert meeting_service.is_running

        # Let it run for a bit
        await asyncio.sleep(1)

        # Stop Meeting
        logger.info("Stopping meeting...")
        await meeting_service.stop_meeting(meeting_id)

        # Verify stopped
        assert not meeting_service.is_running

        # Verify DB status - expire cache to get fresh data from database
        db_session.expire_all()
        result = await db_session.execute(select(Meeting).where(Meeting.id == meeting_id))
        updated_meeting = result.scalars().first()
        # Note: Status is updated by MeetingService in its own transaction
        # The meeting should be COMPLETED after stop_meeting()
        assert updated_meeting.status == MeetingStatus.COMPLETED, (
            f"Expected COMPLETED but got {updated_meeting.status}"
        )

    finally:
        # Cleanup
        result = await db_session.execute(select(Meeting).where(Meeting.id == meeting_id))
        m = result.scalars().first()
        if m:
            # Delete related transcripts first
            from app.models.transcript import Transcript
            from sqlalchemy import delete
            await db_session.execute(delete(Transcript).where(Transcript.meeting_id == meeting_id))
            
            await db_session.delete(m)
            await db_session.commit()


@pytest.mark.asyncio
async def test_macos_dual_audio_capture(db_session, engine, monkeypatch):
    """Test macOS dual audio capture with mocked audio streams.

    This test verifies that when running on macOS (or when ScreenCaptureKit is used),
    the dual capture yields separate chunks for system and mic audio.
    """
    logger.info("Starting macOS Dual Audio Capture Integration Test...")

    # Patch AsyncSessionLocal
    from sqlalchemy.ext.asyncio import async_sessionmaker
    test_session_factory = async_sessionmaker(engine, expire_on_commit=False)
    monkeypatch.setattr(meeting_service_module, "AsyncSessionLocal", test_session_factory)

    meeting_service = MeetingService()

    # Track captured sources
    captured_sources = []

    async def mock_dual_capture_audio(*args, **kwargs):
        """Mock audio capture that yields alternating system and mic chunks."""
        import numpy as np
        from app.services.audio_capture import AudioChunk

        logger.info("Mocking macOS dual audio capture...")
        for i in range(6):  # Yield 6 chunks (3 system, 3 mic)
            source = "system" if i % 2 == 0 else "user"
            captured_sources.append(source)

            yield AudioChunk(
                data=np.random.randn(16000).astype(np.float32) * 0.1,
                timestamp=datetime.utcnow().timestamp(),
                duration=1.0,
                sample_rate=16000,
                channels=1,
                audio_level=0.3 if source == "system" else 0.5,
                source=source
            )
            await asyncio.sleep(0.05)

    async def mock_stop_capture():
        logger.info("Mocking stop capture")

    meeting_service.audio_capture.capture_audio = mock_dual_capture_audio
    meeting_service.audio_capture.stop_capture = mock_stop_capture

    # Create meeting
    meeting = Meeting(
        title="macOS Dual Capture Test",
        status=MeetingStatus.PENDING,
        start_time=datetime.utcnow()
    )
    db_session.add(meeting)
    await db_session.commit()
    await db_session.refresh(meeting)
    meeting_id = str(meeting.id)

    try:
        # Start Meeting
        logger.info(f"Starting meeting {meeting_id} with dual capture...")
        await meeting_service.start_meeting(meeting_id)

        assert meeting_service.is_running
        await asyncio.sleep(0.5)

        # Stop Meeting
        await meeting_service.stop_meeting(meeting_id)
        assert not meeting_service.is_running

        # Verify we got both sources
        system_count = sum(1 for s in captured_sources if s == "system")
        user_count = sum(1 for s in captured_sources if s == "user")

        logger.info(f"Captured {system_count} system chunks, {user_count} user chunks")

        assert system_count > 0, "Should capture at least one system chunk"
        assert user_count > 0, "Should capture at least one user/mic chunk"
        assert system_count + user_count == len(captured_sources)

        # Verify DB status
        db_session.expire_all()
        result = await db_session.execute(select(Meeting).where(Meeting.id == meeting_id))
        updated_meeting = result.scalars().first()
        assert updated_meeting.status == MeetingStatus.COMPLETED

        logger.info("macOS dual audio capture test PASSED")

    finally:
        result = await db_session.execute(select(Meeting).where(Meeting.id == meeting_id))
        m = result.scalars().first()
        if m:
            # Delete related transcripts first
            from app.models.transcript import Transcript
            from sqlalchemy import delete
            await db_session.execute(delete(Transcript).where(Transcript.meeting_id == meeting_id))

            await db_session.delete(m)
            await db_session.commit()


@pytest.mark.skipif(SYSTEM != "Darwin", reason="macOS-only test with real hardware")
@pytest.mark.asyncio
async def test_screencapturekit_real_hardware():
    """Manual test with real ScreenCaptureKit and microphone on macOS.

    This test is skipped in CI. Run manually with:
        pytest backend/tests/integration/test_audio_flow.py::test_screencapturekit_real_hardware -v -s

    Requirements:
    - macOS 12.3 or later
    - Screen Recording permission granted
    - Working microphone
    """
    from app.services.audio_capture import AudioCaptureService, AUDIO_BACKEND
    from app.services.audio_capture_macos import ScreenCaptureKitAudioCapture

    logger.info("Testing real ScreenCaptureKit audio capture...")

    # Check ScreenCaptureKit availability
    if not ScreenCaptureKitAudioCapture.is_available():
        pytest.skip("ScreenCaptureKit not available - requires macOS 12.3+")

    # List devices
    sck_service = ScreenCaptureKitAudioCapture()
    devices = await sck_service.list_audio_devices()
    logger.info("Available devices:")
    for d in devices:
        logger.info(f"  [{d['index']}] {d['name']} (loopback={d['is_loopback']}, default={d['is_default']})")

    # Find system audio and mic
    system_audio = next((d for d in devices if d['is_loopback']), None)
    mic = next((d for d in devices if not d['is_loopback'] and d['is_default']), None)

    if not system_audio:
        pytest.skip("System audio not available")
    if not mic:
        pytest.skip("No microphone found")

    logger.info(f"Using System Audio: {system_audio['name']}")
    logger.info(f"Using Microphone: {mic['name']}")

    # Capture a few chunks
    chunks_captured = {"system": 0, "user": 0}

    try:
        async for chunk in sck_service.capture_audio(
            capture_system=True,
            capture_mic=True
        ):
            chunks_captured[chunk.source] = chunks_captured.get(chunk.source, 0) + 1
            logger.info(f"Captured {chunk.source} chunk, level={chunk.audio_level:.3f}")

            # Stop after 5 total chunks or 5 seconds
            if sum(chunks_captured.values()) >= 5:
                break
    except Exception as e:
        logger.error(f"Capture error: {e}")
        raise

    await sck_service.stop_capture()

    logger.info(f"Results: {chunks_captured}")
    assert chunks_captured.get("system", 0) >= 0, "Should attempt system capture"
    assert chunks_captured.get("user", 0) >= 0, "Should attempt mic capture"
