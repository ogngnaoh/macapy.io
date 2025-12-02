"""
Query Service for macapy.io

Handles user queries with streaming AI responses.
Retrieves context from transcripts and documents for informed answers.
"""

import logging
from typing import AsyncGenerator, List, Optional
from uuid import UUID
from datetime import datetime, timedelta, timezone

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, desc

from app.config import settings
from app.models.transcript import Transcript
from app.models.summary import Summary
from app.services.context_service import ContextService
from app.services.context_builder import ContextBuilder, CONTEXT_PRESETS
from app.services.llm_service import LLMService, LLMError, LLMRateLimitError

logger = logging.getLogger(__name__)


class QueryService:
    def __init__(self):
        self.llm = LLMService()

    async def stream_query_response(
        self,
        meeting_id: UUID,
        query: str,
        db: AsyncSession,
        include_documents: bool = True
    ) -> AsyncGenerator[str, None]:
        """
        Stream AI response to user query using unified context.
        Yields text chunks as they are generated.
        """
        logger.info(f"stream_query_response: meeting_id={meeting_id}, query_len={len(query)}")

        # Build unified context with ContextBuilder
        builder = ContextBuilder(db)
        config = CONTEXT_PRESETS["query"]

        # Override include_documents if specified
        if not include_documents:
            config.include_documents = False

        context = await builder.build(
            meeting_id=meeting_id,
            query=query,
            config=config
        )

        logger.info(
            f"stream_query_response: context built - "
            f"transcripts={len(context['transcripts'])}, "
            f"summaries={len(context['summaries'])}, "
            f"documents={len(context['documents'])}, "
            f"tokens={context['token_counts']['total']}"
        )

        # Stream response using context-aware method
        try:
            async for token in self.llm.answer_query_with_context(
                question=query,
                context=context,
                reasoning_effort="medium"
            ):
                yield token
        except LLMRateLimitError as e:
            logger.error(f"stream_query_response: rate limit error - {e}")
            raise
        except LLMError as e:
            logger.error(f"stream_query_response: LLM error - {e}")
            raise
        except Exception as e:
            logger.error(f"stream_query_response: unexpected error - {type(e).__name__}: {e}", exc_info=True)
            raise

    async def generate_recap(
        self,
        meeting_id: UUID,
        db: AsyncSession,
        duration_seconds: int = 30
    ) -> dict:
        """
        Generate a quick recap of the last N seconds of the meeting.
        """
        # Get transcripts from the last N seconds
        cutoff_time = datetime.now(timezone.utc) - timedelta(seconds=duration_seconds)

        result = await db.execute(
            select(Transcript)
            .where(Transcript.meeting_id == meeting_id)
            .where(Transcript.created_at >= cutoff_time)
            .order_by(Transcript.created_at.asc())
        )
        recent_transcripts = result.scalars().all()

        if not recent_transcripts:
            return {
                "recap": "No recent conversation in the last 30 seconds.",
                "tokens_used": 0,
                "transcript_count": 0,
                "time_range": {"start": None, "end": None}
            }

        transcript_text = "\n".join([
            f"[{t.speaker}]: {t.text}" for t in recent_transcripts
        ])

        recap_text = await self.llm.generate_summary(transcript_text)
        
        # Estimate tokens
        tokens_used = self.llm.count_tokens(transcript_text) + self.llm.count_tokens(recap_text)

        return {
            "recap": recap_text,
            "tokens_used": tokens_used,
            "transcript_count": len(recent_transcripts),
            "time_range": {
                "start": recent_transcripts[0].created_at.isoformat(),
                "end": recent_transcripts[-1].created_at.isoformat()
            }
        }

    async def generate_summary_now(
        self,
        meeting_id: UUID,
        db: AsyncSession
    ) -> Optional[dict]:
        """
        Trigger immediate summary generation for unsummarized transcripts.
        """
        logger.info(f"generate_summary_now: meeting_id={meeting_id}")

        # Get the last summary time
        last_summary_result = await db.execute(
            select(Summary)
            .where(Summary.meeting_id == meeting_id)
            .order_by(desc(Summary.created_at))
            .limit(1)
        )
        last_summary = last_summary_result.scalar_one_or_none()

        since_time = last_summary.end_time if last_summary else datetime.min
        logger.debug(f"generate_summary_now: last_summary_time={since_time}")

        # Get transcripts since last summary
        result = await db.execute(
            select(Transcript)
            .where(Transcript.meeting_id == meeting_id)
            .where(Transcript.created_at > since_time)
            .order_by(Transcript.created_at.asc())
        )
        transcripts = result.scalars().all()

        if not transcripts:
            logger.info("generate_summary_now: no new transcripts to summarize")
            return None

        logger.info(f"generate_summary_now: found {len(transcripts)} transcripts to summarize")

        transcript_text = "\n".join([t.text for t in transcripts])
        logger.debug(f"generate_summary_now: transcript_text_len={len(transcript_text)}")

        try:
            summary_text = await self.llm.generate_summary(transcript_text)
        except LLMError as e:
            logger.error(f"generate_summary_now: LLM error - {e}")
            raise
        except Exception as e:
            logger.error(f"generate_summary_now: unexpected error - {type(e).__name__}: {e}", exc_info=True)
            raise

        if not summary_text:
            logger.warning("generate_summary_now: LLM returned empty summary")
            return None

        logger.info(f"generate_summary_now: summary generated, len={len(summary_text)}")

        # Save summary to DB
        from app.models.summary import Summary as SummaryModel
        summary = SummaryModel(
            meeting_id=meeting_id,
            content=summary_text,
            start_time=since_time if since_time != datetime.min else transcripts[0].created_at,
            end_time=datetime.now(timezone.utc)
        )
        db.add(summary)
        await db.commit()
        await db.refresh(summary)

        logger.info(f"generate_summary_now: summary saved, id={summary.id}")

        return {
            "id": summary.id,
            "content": summary.content,
            "start_time": summary.start_time.isoformat() if summary.start_time else None,
            "end_time": summary.end_time.isoformat() if summary.end_time else None,
            "created_at": summary.created_at.isoformat()
        }


# Singleton instance
query_service = QueryService()
