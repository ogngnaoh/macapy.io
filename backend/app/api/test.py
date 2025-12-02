"""
Test API endpoints for E2E testing.
These endpoints enable testing without real audio devices.
Should only be enabled in development/testing environments.
"""

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from uuid import UUID
from datetime import datetime
from pydantic import BaseModel
from typing import Optional
import logging

from app.db.session import get_db
from app.models.transcript import Transcript
from app.models.meeting import Meeting, MeetingStatus
from app.services.websocket_manager import manager
from app.services.token_service import token_service
from app.config import settings

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/test", tags=["test"])


class InjectTranscriptRequest(BaseModel):
    """Request body for injecting a mock transcript."""
    meeting_id: UUID
    text: str
    speaker: str = "system"  # "system" or "user"
    timestamp: Optional[float] = None


class InjectTranscriptResponse(BaseModel):
    """Response for transcript injection."""
    id: UUID
    meeting_id: UUID
    text: str
    speaker: str
    timestamp: float
    broadcast_sent: bool


@router.post("/inject-transcript", response_model=InjectTranscriptResponse)
async def inject_transcript(
    request: InjectTranscriptRequest,
    db: AsyncSession = Depends(get_db)
):
    """
    Inject a mock transcript for E2E testing.

    This endpoint simulates the audio → transcription pipeline by directly
    creating a transcript record and broadcasting it via WebSocket.

    Use this to test:
    - WebSocket event delivery
    - Transcript display in frontend
    - Summary generation triggers
    - Token counting
    """
    # Verify meeting exists and is in progress
    result = await db.execute(
        select(Meeting).where(Meeting.id == request.meeting_id)
    )
    meeting = result.scalars().first()

    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")

    if meeting.status != MeetingStatus.IN_PROGRESS:
        raise HTTPException(
            status_code=400,
            detail=f"Meeting is not in progress (status: {meeting.status})"
        )

    # Calculate timestamp relative to meeting start
    if request.timestamp is not None:
        timestamp = request.timestamp
    else:
        elapsed = (datetime.utcnow() - meeting.start_time).total_seconds()
        timestamp = elapsed

    # Create transcript record
    transcript = Transcript(
        meeting_id=request.meeting_id,
        text=request.text,
        speaker=request.speaker,
        timestamp=timestamp
    )
    db.add(transcript)
    await db.commit()
    await db.refresh(transcript)

    logger.info(f"Injected transcript for meeting {request.meeting_id}: {request.text[:50]}...")

    # Broadcast via WebSocket
    broadcast_sent = False
    try:
        await manager.broadcast(
            str(request.meeting_id),
            {
                "type": "transcript",
                "data": {
                    "id": str(transcript.id),
                    "text": transcript.text,
                    "timestamp": transcript.timestamp,
                    "speaker": transcript.speaker,
                    "created_at": transcript.created_at.isoformat()
                }
            }
        )
        broadcast_sent = True
    except Exception as e:
        logger.warning(f"WebSocket broadcast failed: {e}")

    return InjectTranscriptResponse(
        id=transcript.id,
        meeting_id=transcript.meeting_id,
        text=transcript.text,
        speaker=transcript.speaker,
        timestamp=transcript.timestamp,
        broadcast_sent=broadcast_sent
    )


class TriggerSummaryRequest(BaseModel):
    """Request body for triggering summary generation."""
    meeting_id: UUID


@router.post("/trigger-summary")
async def trigger_summary(
    request: TriggerSummaryRequest,
    db: AsyncSession = Depends(get_db)
):
    """
    Trigger summary generation for testing.

    This endpoint forces a summary to be generated for the given meeting,
    useful for testing the summary pipeline without waiting for the interval.
    """
    from app.services.query_service import query_service

    # Verify meeting exists
    result = await db.execute(
        select(Meeting).where(Meeting.id == request.meeting_id)
    )
    meeting = result.scalars().first()

    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")

    # Generate summary
    try:
        summary = await query_service.generate_summary_now(request.meeting_id, db)
        return {
            "success": True,
            "summary_id": str(summary.id) if summary else None,
            "content": summary.content if summary else None
        }
    except Exception as e:
        logger.error(f"Summary generation failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/token-usage/{meeting_id}")
async def get_token_usage(
    meeting_id: UUID,
    db: AsyncSession = Depends(get_db)
):
    """Get detailed token usage for a meeting (testing endpoint)."""
    usage = await token_service.get_meeting_token_usage(meeting_id, db)
    return usage
