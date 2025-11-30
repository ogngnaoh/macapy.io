from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import StreamingResponse, JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from uuid import UUID
from typing import List
import json
import logging

from app.db.session import get_db
from app.models.summary import Summary
from app.models.suggestion import Suggestion
from app.schemas.ai import (
    QueryRequest,
    RecapRequest,
    RecapResponse,
    SummaryGenerateResponse,
    TokenUsageResponse,
    LLMErrorDetail,
    ErrorCode,
)
from app.services.query_service import query_service
from app.services.token_service import token_service
from app.services.websocket_manager import manager
from app.services.llm_service import LLMError, LLMRefusalError, LLMRateLimitError

logger = logging.getLogger(__name__)

router = APIRouter()


@router.get("/meetings/{meeting_id}/summaries")
async def get_meeting_summaries(
    meeting_id: UUID,
    db: AsyncSession = Depends(get_db)
):
    """Get all summaries for a meeting."""
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
    """Get all AI suggestions for a meeting."""
    result = await db.execute(
        select(Suggestion)
        .where(Suggestion.meeting_id == meeting_id)
        .order_by(Suggestion.created_at.desc())
    )
    return result.scalars().all()


@router.post("/query")
async def query_ai(
    request: QueryRequest,
    db: AsyncSession = Depends(get_db)
):
    """
    Submit a query to the AI assistant with meeting context.
    Returns a streaming response (Server-Sent Events format).

    Error handling:
    - LLMRefusalError: 422 Unprocessable Entity
    - LLMRateLimitError: 429 Too Many Requests
    - Other errors: Included in stream as error event
    """
    async def generate():
        try:
            async for chunk in query_service.stream_query_response(
                meeting_id=request.meeting_id,
                query=request.question,
                db=db,
                include_documents=request.include_documents
            ):
                # SSE format: data: <content>\n\n
                yield f"data: {json.dumps({'content': chunk})}\n\n"
            yield "data: [DONE]\n\n"
        except LLMRefusalError as e:
            error_detail = LLMErrorDetail(
                code=ErrorCode.REFUSAL,
                message=e.message,
                recoverable=False
            )
            yield f"data: {json.dumps({'error': error_detail.model_dump()})}\n\n"
        except LLMRateLimitError as e:
            error_detail = LLMErrorDetail(
                code=ErrorCode.RATE_LIMIT,
                message=e.message,
                recoverable=True,
                retry_after=e.retry_after
            )
            yield f"data: {json.dumps({'error': error_detail.model_dump()})}\n\n"
        except LLMError as e:
            error_detail = LLMErrorDetail(
                code=e.code,
                message=e.message,
                recoverable=e.recoverable
            )
            yield f"data: {json.dumps({'error': error_detail.model_dump()})}\n\n"
        except Exception as e:
            logger.error(f"Error in query stream: {e}", exc_info=True)
            error_detail = LLMErrorDetail(
                code=ErrorCode.MODEL_ERROR,
                message=str(e),
                recoverable=True
            )
            yield f"data: {json.dumps({'error': error_detail.model_dump()})}\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        }
    )


@router.post("/recap", response_model=RecapResponse)
async def get_recap(
    request: RecapRequest,
    db: AsyncSession = Depends(get_db)
):
    """
    Get a quick recap of the last N seconds of the meeting.
    Default is 30 seconds.
    """
    result = await query_service.generate_recap(
        meeting_id=request.meeting_id,
        db=db,
        duration_seconds=request.duration_seconds
    )
    return RecapResponse(**result)


@router.post("/meetings/{meeting_id}/summaries/generate")
async def generate_summary_now(
    meeting_id: UUID,
    db: AsyncSession = Depends(get_db)
):
    """
    Trigger immediate summary generation for unsummarized content.
    Returns 202 Accepted with the generated summary or null if no content to summarize.
    """
    result = await query_service.generate_summary_now(meeting_id, db)

    if result is None:
        return {"message": "No new content to summarize", "summary": None}

    # Broadcast the new summary via WebSocket
    await manager.broadcast_to_meeting({
        "type": "summary_update",
        "data": result
    }, str(meeting_id))

    return {"message": "Summary generated successfully", "summary": result}


@router.get("/meetings/{meeting_id}/tokens", response_model=TokenUsageResponse)
async def get_token_usage(
    meeting_id: UUID,
    db: AsyncSession = Depends(get_db)
):
    """
    Get current token usage for a meeting.
    Useful for displaying context window usage in the UI.
    """
    usage = await token_service.get_meeting_token_usage(meeting_id, db)
    return TokenUsageResponse(**usage)
