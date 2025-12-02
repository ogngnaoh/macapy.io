from typing import List, Any
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from app.db.session import get_db
from app.models.meeting import Meeting, MeetingStatus
from app.schemas.meeting import MeetingCreate, MeetingUpdate, Meeting as MeetingSchema
from sqlalchemy import select

router = APIRouter()

@router.post("/", response_model=MeetingSchema)
async def create_meeting(
    meeting_in: MeetingCreate,
    db: AsyncSession = Depends(get_db)
) -> Any:
    meeting = Meeting(**meeting_in.model_dump())
    db.add(meeting)
    await db.commit()
    await db.refresh(meeting)
    return meeting

@router.get("/", response_model=List[MeetingSchema])
async def read_meetings(
    skip: int = 0,
    limit: int = 100,
    db: AsyncSession = Depends(get_db)
) -> Any:
    result = await db.execute(
        select(Meeting)
        .order_by(Meeting.start_time.desc())
        .offset(skip)
        .limit(limit)
    )
    meetings = result.scalars().all()
    return meetings

@router.get("/{meeting_id}", response_model=MeetingSchema)
async def read_meeting(
    meeting_id: str,
    db: AsyncSession = Depends(get_db)
) -> Any:
    result = await db.execute(select(Meeting).where(Meeting.id == meeting_id))
    meeting = result.scalars().first()
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")
    return meeting

@router.patch("/{meeting_id}", response_model=MeetingSchema)
async def update_meeting(
    meeting_id: str,
    meeting_in: MeetingUpdate,
    db: AsyncSession = Depends(get_db)
) -> Any:
    result = await db.execute(select(Meeting).where(Meeting.id == meeting_id))
    meeting = result.scalars().first()
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")
    
    # Check for status changes to trigger meeting service
    if meeting_in.status:
        from app.services.meeting_service import meeting_service
        
        if meeting_in.status == MeetingStatus.IN_PROGRESS and meeting.status != MeetingStatus.IN_PROGRESS:
            # Start meeting processing
            # We do this as a background task so we don't block the API response
            # However, start_meeting is async and mostly sets up tasks, so awaiting it is fine
            await meeting_service.start_meeting(str(meeting.id))
            
        elif meeting_in.status == MeetingStatus.COMPLETED and meeting.status != MeetingStatus.COMPLETED:
            # Stop meeting processing
            await meeting_service.stop_meeting(str(meeting.id))

    update_data = meeting_in.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(meeting, field, value)
    
    db.add(meeting)
    await db.commit()
    await db.refresh(meeting)
    return meeting

@router.delete("/{meeting_id}", response_model=MeetingSchema)
async def delete_meeting(
    meeting_id: str,
    db: AsyncSession = Depends(get_db)
) -> Any:
    result = await db.execute(select(Meeting).where(Meeting.id == meeting_id))
    meeting = result.scalars().first()
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")

    await db.delete(meeting)
    await db.commit()
    return meeting


@router.post("/{meeting_id}/pause")
async def pause_meeting(meeting_id: str) -> Any:
    """
    Pause audio capture for privacy.
    Audio is not captured/transcribed while paused.
    """
    from app.services.meeting_service import meeting_service

    success = await meeting_service.pause_meeting(meeting_id)
    if not success:
        raise HTTPException(
            status_code=400,
            detail="Cannot pause: meeting not active or not found"
        )
    return {"status": "paused", "meeting_id": meeting_id}


@router.post("/{meeting_id}/resume")
async def resume_meeting(meeting_id: str) -> Any:
    """
    Resume audio capture after pause.
    """
    from app.services.meeting_service import meeting_service

    success = await meeting_service.resume_meeting(meeting_id)
    if not success:
        raise HTTPException(
            status_code=400,
            detail="Cannot resume: meeting not active or not found"
        )
    return {"status": "recording", "meeting_id": meeting_id}


@router.get("/{meeting_id}/status")
async def get_meeting_status(meeting_id: str) -> Any:
    """
    Get current meeting capture status (running, paused, etc).
    """
    from app.services.meeting_service import meeting_service

    status = meeting_service.get_status()
    if status["meeting_id"] != meeting_id:
        return {"status": "idle", "meeting_id": meeting_id, "is_active": False}

    return {
        "status": "paused" if status["is_paused"] else "recording",
        "meeting_id": meeting_id,
        "is_active": status["is_running"],
        "is_paused": status["is_paused"]
    }
