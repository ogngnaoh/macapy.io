import asyncio
from datetime import datetime
import logging
import sys
from pathlib import Path

# Add backend to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.meeting_service import MeetingService
from app.db.session import get_db
from app.models.meeting import Meeting, MeetingStatus
from app.config import settings

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

async def verify_audio_integration():
    logger.info("Starting Audio Integration Verification...")
    
    meeting_service = MeetingService()
    
    # Mock AudioCaptureService to avoid hardware dependency
    async def mock_capture_audio(*args, **kwargs):
        import numpy as np
        from app.services.audio_capture import AudioChunk
        import asyncio
        
        logger.info("🎤 Mocking audio capture...")
        while True:
            # Yield silent chunk
            yield AudioChunk(
                data=np.zeros(16000),
                timestamp=datetime.utcnow().timestamp(),
                duration=1.0,
                sample_rate=16000,
                channels=1,
                audio_level=0.5
            )
            await asyncio.sleep(1)

    async def mock_stop_capture():
        logger.info("🛑 Mocking stop capture")

    meeting_service.audio_capture.capture_audio = mock_capture_audio
    meeting_service.audio_capture.stop_capture = mock_stop_capture
    
    try:
        # 1. Create a test meeting directly in DB
        logger.info("Creating test meeting...")
        async for session in get_db():
            new_meeting = Meeting(
                title="Audio Integration Test",
                status=MeetingStatus.PENDING,
                start_time=datetime.utcnow()
            )
            session.add(new_meeting)
            await session.commit()
            await session.refresh(new_meeting)
            meeting_id = str(new_meeting.id)
            logger.info(f"Created meeting: {meeting_id}")
            
            try:
                # 2. Start Meeting (Simulate API call)
                logger.info("Starting meeting (simulating PATCH /meetings/{id})...")
                await meeting_service.start_meeting(meeting_id)
                
                # 3. Verify Service State
                if meeting_service.is_running and meeting_service.current_meeting_id == meeting_id:
                    logger.info("✅ MeetingService is running correctly")
                else:
                    logger.error("❌ MeetingService failed to start")
                    return
                
                # 4. Wait briefly to simulate operation
                await asyncio.sleep(2)
                
                # 5. Stop Meeting
                logger.info("Stopping meeting...")
                await meeting_service.stop_meeting(meeting_id)
                
                # 6. Verify Stop
                if not meeting_service.is_running:
                    logger.info("✅ MeetingService stopped correctly")
                else:
                    logger.error("❌ MeetingService failed to stop")
                    return
                    
                logger.info("✅ Audio Integration Verification PASSED")
            finally:
                # Cleanup
                await session.delete(new_meeting)
                await session.commit()
                
    except Exception as e:
        import traceback
        import sys
        with open("error.txt", "w", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        logger.error(f"❌ Verification failed: {e}")

if __name__ == "__main__":
    asyncio.run(verify_audio_integration())
