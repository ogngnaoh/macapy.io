import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from app.services.meeting_service import MeetingService
from app.models.meeting import Meeting, MeetingStatus
from datetime import datetime

@pytest.mark.asyncio
async def test_meeting_lifecycle_mocked():
    # Mock dependencies
    with patch("app.services.meeting_service.AudioCaptureService") as MockAudioCapture, \
         patch("app.services.meeting_service.TranscriptionService") as MockTranscription, \
         patch("app.services.meeting_service.LLMService") as MockLLM, \
         patch("app.services.meeting_service.AsyncSessionLocal") as MockSessionLocal:
         
        # Setup mocks
        mock_audio = AsyncMock()
        MockAudioCapture.return_value = mock_audio
        
        mock_session = AsyncMock()
        MockSessionLocal.return_value = mock_session
        mock_session.__aenter__.return_value = mock_session
        
        service = MeetingService()
        service._processing_loop = AsyncMock()
        
        # Create meeting object
        meeting_id = "123e4567-e89b-12d3-a456-426614174000"
        meeting = Meeting(
            id=meeting_id,
            title="Unit Test Meeting", 
            status=MeetingStatus.PENDING,
            start_time=datetime.utcnow()
        )
        
        # Mock DB query result
        mock_result = MagicMock()
        mock_result.scalars().first.return_value = meeting
        mock_session.execute.return_value = mock_result
        
        # Start Meeting
        print("Starting meeting...")
        await service.start_meeting(meeting_id)
        print("Meeting started.")
        
        # Verify status update in DB
        assert meeting.status == MeetingStatus.IN_PROGRESS
        # Verify commit was called
        mock_session.commit.assert_awaited()
        
        assert service.is_running
        assert service.current_meeting_id == meeting_id
        
        # Stop Meeting
        print("Stopping meeting...")
        await service.stop_meeting(meeting_id)
        print("Meeting stopped.")
        
        # Verify status update
        assert meeting.status == MeetingStatus.COMPLETED
        assert not service.is_running
