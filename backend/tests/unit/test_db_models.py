import pytest
from sqlalchemy.ext.asyncio import AsyncSession
from app.models.meeting import Meeting, MeetingStatus
from app.models.transcript import Transcript
from datetime import datetime

@pytest.mark.asyncio
async def test_create_meeting(db_session: AsyncSession):
    meeting = Meeting(title="Test Meeting", platform="zoom")
    db_session.add(meeting)
    await db_session.commit()
    await db_session.refresh(meeting)

    assert meeting.id is not None
    assert meeting.title == "Test Meeting"
    assert meeting.platform == "zoom"
    assert meeting.status == MeetingStatus.PENDING
    assert meeting.start_time is not None

@pytest.mark.asyncio
async def test_create_transcript(db_session: AsyncSession):
    # Create a meeting first
    meeting = Meeting(title="Transcript Test Meeting")
    db_session.add(meeting)
    await db_session.commit()
    await db_session.refresh(meeting)

    # Create a transcript
    transcript = Transcript(
        meeting_id=meeting.id,
        speaker="User",
        text="Hello world",
        timestamp=0.0
    )
    db_session.add(transcript)
    await db_session.commit()
    await db_session.refresh(transcript)

    assert transcript.id is not None
    assert transcript.meeting_id == meeting.id
    assert transcript.text == "Hello world"
    assert transcript.speaker == "User"

@pytest.mark.asyncio
async def test_meeting_transcripts_relationship(db_session: AsyncSession):
    meeting = Meeting(title="Relationship Test")
    db_session.add(meeting)
    await db_session.commit()
    await db_session.refresh(meeting)

    t1 = Transcript(meeting_id=meeting.id, text="One", timestamp=1.0)
    t2 = Transcript(meeting_id=meeting.id, text="Two", timestamp=2.0)
    db_session.add_all([t1, t2])
    await db_session.commit()

    # Refresh meeting to load relationship
    await db_session.refresh(meeting, attribute_names=["transcripts"])
    
    assert len(meeting.transcripts) == 2
    assert t1 in meeting.transcripts
    assert t2 in meeting.transcripts
