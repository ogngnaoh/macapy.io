from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from uuid import UUID
from typing import List

from app.db.session import get_db
from app.models.summary import Summary
from app.models.suggestion import Suggestion

router = APIRouter()

@router.get("/meetings/{meeting_id}/summaries")
async def get_meeting_summaries(
    meeting_id: UUID,
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        select(Summary)
        .where(Summary.meeting_id == meeting_id)
        .order_by(Summary.created_at.asc())
    )
    return result.scalars().all()

@router.get("/meetings/{meeting_id}/suggestions")
async def get_meeting_suggestions(
    meeting_id: UUID,
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        select(Suggestion)
        .where(Suggestion.meeting_id == meeting_id)
        .order_by(Suggestion.created_at.desc())
    )
    return result.scalars().all()
