"""
Token Service for macapy.io

Handles token counting, context window management, and token usage tracking.
Uses tiktoken for accurate OpenAI token counting.
"""

import logging
from typing import Optional
from uuid import UUID

import tiktoken
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func

from app.config import settings
from app.services.websocket_manager import manager
from app.models.transcript import Transcript
from app.models.summary import Summary

logger = logging.getLogger(__name__)

# GPT-5 nano context window (assumed similar to GPT-4 Turbo)
MAX_CONTEXT_TOKENS = 272000
WARNING_THRESHOLD = 0.80  # Warn at 80%
DANGER_THRESHOLD = 0.95  # Critical at 95%


class TokenService:
    def __init__(self):
        # Use cl100k_base encoding (GPT-4/GPT-3.5 compatible)
        try:
            self.encoding = tiktoken.get_encoding("cl100k_base")
        except Exception as e:
            logger.warning(f"Failed to load tiktoken encoding: {e}, using fallback")
            self.encoding = None

    def count_tokens(self, text: str) -> int:
        """
        Count the number of tokens in a text string.
        Uses tiktoken for accurate counting, falls back to word-based estimate.
        """
        if not text:
            return 0

        if self.encoding:
            try:
                return len(self.encoding.encode(text))
            except Exception as e:
                logger.warning(f"Token encoding failed: {e}, using fallback")

        # Fallback: rough estimate (1 token ~ 4 chars or 0.75 words)
        return len(text) // 4

    def count_tokens_batch(self, texts: list[str]) -> int:
        """Count total tokens for a list of texts."""
        return sum(self.count_tokens(text) for text in texts)

    async def get_meeting_token_usage(self, meeting_id: UUID, db: AsyncSession) -> dict:
        """
        Calculate current token usage for a meeting.
        Returns breakdown by source and total usage.
        """
        # Count transcript tokens
        transcript_result = await db.execute(
            select(Transcript.text).where(Transcript.meeting_id == meeting_id)
        )
        transcripts = transcript_result.scalars().all()
        transcript_tokens = self.count_tokens_batch(transcripts)

        # Count summary tokens
        summary_result = await db.execute(
            select(Summary.content).where(Summary.meeting_id == meeting_id)
        )
        summaries = summary_result.scalars().all()
        summary_tokens = self.count_tokens_batch(summaries)

        total_tokens = transcript_tokens + summary_tokens
        percentage = (total_tokens / MAX_CONTEXT_TOKENS) * 100

        return {
            "current_tokens": total_tokens,
            "max_tokens": MAX_CONTEXT_TOKENS,
            "percentage": round(percentage, 2),
            "breakdown": {
                "transcripts": transcript_tokens,
                "summaries": summary_tokens,
            },
            "warning": percentage >= WARNING_THRESHOLD * 100,
            "danger": percentage >= DANGER_THRESHOLD * 100,
        }

    def check_context_limit(self, current_tokens: int, new_text: str) -> dict:
        """
        Check if adding new text would exceed context limits.
        Returns status and recommendation.
        """
        new_tokens = self.count_tokens(new_text)
        total_after = current_tokens + new_tokens
        percentage = (total_after / MAX_CONTEXT_TOKENS) * 100

        return {
            "new_tokens": new_tokens,
            "total_after": total_after,
            "percentage": round(percentage, 2),
            "would_exceed": total_after > MAX_CONTEXT_TOKENS,
            "warning": percentage >= WARNING_THRESHOLD * 100,
            "danger": percentage >= DANGER_THRESHOLD * 100,
            "recommendation": self._get_recommendation(percentage),
        }

    def _get_recommendation(self, percentage: float) -> Optional[str]:
        """Get recommendation based on usage percentage."""
        if percentage >= DANGER_THRESHOLD * 100:
            return "Critical: Consider ending meeting or clearing old context"
        elif percentage >= WARNING_THRESHOLD * 100:
            return "Warning: Approaching context limit, summarize older segments"
        return None

    async def broadcast_token_usage(self, meeting_id: str, db: AsyncSession):
        """
        Calculate and broadcast token usage to connected clients.
        """
        try:
            usage = await self.get_meeting_token_usage(UUID(meeting_id), db)
            await manager.broadcast_to_meeting({
                "type": "token_usage",
                "data": usage
            }, meeting_id)
        except Exception as e:
            logger.error(f"Error broadcasting token usage: {e}")

    def estimate_query_cost(self, query: str, context_length: int) -> dict:
        """
        Estimate token cost for a query with context.
        Useful for showing users expected cost before submitting.
        """
        query_tokens = self.count_tokens(query)
        # Estimate response at 2x query tokens (rough heuristic)
        estimated_response = query_tokens * 2

        return {
            "query_tokens": query_tokens,
            "context_tokens": context_length,
            "estimated_response": estimated_response,
            "total_input": query_tokens + context_length,
            "total_estimated": query_tokens + context_length + estimated_response,
        }


# Singleton instance
token_service = TokenService()
