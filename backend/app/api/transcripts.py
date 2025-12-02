from typing import List, Any
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from app.db.session import get_db
from app.models.transcript import Transcript
from app.schemas.transcript import TranscriptCreate, Transcript as TranscriptSchema
from sqlalchemy import select

router = APIRouter()

@router.post("/", response_model=TranscriptSchema)
async def create_transcript(
    transcript_in: TranscriptCreate,
    db: AsyncSession = Depends(get_db)
) -> Any:
    transcript = Transcript(**transcript_in.model_dump())
    db.add(transcript)
    await db.commit()
    await db.refresh(transcript)
    return transcript

@router.get("/", response_model=List[TranscriptSchema])
async def read_transcripts(
    meeting_id: str = None,
    skip: int = 0,
    limit: int = 100,
    db: AsyncSession = Depends(get_db)
) -> Any:
    query = select(Transcript)
    if meeting_id:
        query = query.where(Transcript.meeting_id == meeting_id)
    
    query = query.offset(skip).limit(limit)
    result = await db.execute(query)
    transcripts = result.scalars().all()
    return transcripts

@router.get("/{transcript_id}", response_model=TranscriptSchema)
async def read_transcript(
    transcript_id: str,
    db: AsyncSession = Depends(get_db)
) -> Any:
    result = await db.execute(select(Transcript).where(Transcript.id == transcript_id))
    transcript = result.scalars().first()
    if not transcript:
        raise HTTPException(status_code=404, detail="Transcript not found")
    return transcript

@router.delete("/{transcript_id}", response_model=TranscriptSchema)
async def delete_transcript(
    transcript_id: str,
    db: AsyncSession = Depends(get_db)
) -> Any:
    result = await db.execute(select(Transcript).where(Transcript.id == transcript_id))
    transcript = result.scalars().first()
    if not transcript:
        raise HTTPException(status_code=404, detail="Transcript not found")
    
    await db.delete(transcript)
    await db.commit()
    return transcript
