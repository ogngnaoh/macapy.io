import asyncio
import logging
import sys
from pathlib import Path
from datetime import datetime
from sqlalchemy import select

# Add backend to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.meeting_service import MeetingService
from app.models.meeting import Meeting, MeetingStatus
from app.db.session import AsyncSessionLocal

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

async def test_audio_integration():
    logger.info("Starting Audio Integration Test...")
    
    meeting_service = MeetingService()
    
    # Mock AudioCaptureService
    async def mock_capture_audio(*args, **kwargs):
        import numpy as np
        from app.services.audio_capture import AudioChunk
        
        logger.info("🎤 Mocking audio capture...")
        while True:
            yield AudioChunk(
                data=np.zeros(16000),
                timestamp=datetime.utcnow().timestamp(),
                duration=1.0,
                sample_rate=16000,
                channels=1,
                audio_level=0.5
            )
            await asyncio.sleep(0.1)

    async def mock_stop_capture():
        logger.info("🛑 Mocking stop capture")

    meeting_service.audio_capture.capture_audio = mock_capture_audio
    meeting_service.audio_capture.stop_capture = mock_stop_capture
    
    # Create meeting
    async with AsyncSessionLocal() as db:
        meeting = Meeting(
            title="Integration Test Meeting",
            status=MeetingStatus.PENDING,
            start_time=datetime.utcnow()
        )
        db.add(meeting)
        await db.commit()
        await db.refresh(meeting)
        meeting_id = str(meeting.id)
        
    try:
        # Start Meeting
        logger.info(f"Starting meeting {meeting_id}...")
        await meeting_service.start_meeting(meeting_id)
        
        # Verify running
        assert meeting_service.is_running(meeting_id)
        
        # Let it run for a bit
        await asyncio.sleep(2)
        
        # Stop Meeting
        logger.info("Stopping meeting...")
        await meeting_service.stop_meeting(meeting_id)
        
        # Verify stopped
        assert not meeting_service.is_running(meeting_id)
        
        # Verify DB status
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Meeting).where(Meeting.id == meeting_id))
            updated_meeting = result.scalars().first()
            assert updated_meeting.status == MeetingStatus.COMPLETED
            
        print("✅ PASSED")
            
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"❌ FAILED: {e}")
            
    finally:
        # Cleanup
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Meeting).where(Meeting.id == meeting_id))
            m = result.scalars().first()
            if m:
                await db.delete(m)
                await db.commit()

if __name__ == "__main__":
    asyncio.run(test_audio_integration())
