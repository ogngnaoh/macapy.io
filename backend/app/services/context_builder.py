"""
Context Builder Service for macapy.io

Unified context assembly service that provides consistent context building
across all LLM operations (queries, summaries, suggestions).

Key features:
- Token budgeting with configurable limits
- Relevance filtering for document chunks
- Metadata preservation for source attribution
- Preset configurations for different operations
"""

import logging
from dataclasses import dataclass, field
from typing import List, Optional, Tuple, Dict, Any
from uuid import UUID
from datetime import datetime, timedelta, timezone

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.models.meeting import Meeting
from app.models.transcript import Transcript
from app.models.summary import Summary
from app.models.context import ContextDocument, ContextChunk
from app.services.embedding_service import EmbeddingService
from app.services.token_service import TokenService

logger = logging.getLogger(__name__)

# Default relevance threshold for document chunks
DEFAULT_RELEVANCE_THRESHOLD = 0.70


@dataclass
class DocumentChunkResult:
    """A document chunk with metadata for source attribution."""
    text: str
    document_id: int
    document_filename: str
    chunk_index: int
    relevance_score: float


@dataclass
class ContextConfig:
    """Configuration for context building."""
    transcript_window_minutes: int = 30
    max_transcript_tokens: int = 100_000
    max_summary_tokens: int = 20_000
    max_document_tokens: int = 30_000
    max_document_chunks: int = 5
    relevance_threshold: float = DEFAULT_RELEVANCE_THRESHOLD
    include_summaries: bool = True
    include_documents: bool = True
    include_meeting_metadata: bool = True


# Preset configurations for different LLM operations
CONTEXT_PRESETS: Dict[str, ContextConfig] = {
    "query": ContextConfig(
        transcript_window_minutes=30,
        max_document_chunks=5,
        relevance_threshold=0.70,
        include_summaries=True,
        include_documents=True,
    ),
    "suggestion": ContextConfig(
        transcript_window_minutes=5,  # More recent for suggestions
        max_transcript_tokens=20_000,
        max_document_chunks=5,
        relevance_threshold=0.65,
        include_summaries=False,  # Speed over comprehensiveness
    ),
    "summary": ContextConfig(
        transcript_window_minutes=60,
        max_document_chunks=3,
        relevance_threshold=0.60,  # Lower threshold for background context
        include_documents=True,  # KEY FIX: Now includes documents
        include_summaries=True,  # Include previous summaries for continuity
    ),
    "recap": ContextConfig(
        transcript_window_minutes=1,  # Just last minute
        max_transcript_tokens=10_000,
        include_summaries=False,
        include_documents=False,
    ),
}


class ContextBuilder:
    """
    Unified context builder for all LLM operations.

    Provides consistent context assembly with:
    - Token budgeting
    - Relevance filtering for document chunks
    - Metadata preservation for attribution
    - Configurable presets for different operations
    """

    def __init__(self, db: AsyncSession):
        self.db = db
        self.embedding_service = EmbeddingService()
        self.token_service = TokenService()

    async def build(
        self,
        meeting_id: UUID,
        query: Optional[str] = None,
        config: Optional[ContextConfig] = None
    ) -> Dict[str, Any]:
        """
        Build unified context for LLM operations.

        Args:
            meeting_id: The meeting to build context for
            query: Optional query for document relevance matching
            config: Configuration for context building (uses defaults if not provided)

        Returns:
            Dictionary containing:
            - meeting: Meeting metadata
            - transcripts: List of transcript dicts
            - summaries: List of summary strings
            - documents: List of DocumentChunkResult
            - token_counts: Token breakdown
        """
        config = config or ContextConfig()

        # Gather all context components in parallel-friendly way
        meeting_context = await self._get_meeting_metadata(meeting_id) if config.include_meeting_metadata else {}

        transcripts, transcript_tokens = await self._get_transcripts(meeting_id, config)

        summaries, summary_tokens = [], 0
        if config.include_summaries:
            summaries, summary_tokens = await self._get_summaries(meeting_id, config)

        documents, document_tokens = [], 0
        if config.include_documents and query:
            documents, document_tokens = await self._get_relevant_documents(meeting_id, query, config)

        total_tokens = transcript_tokens + summary_tokens + document_tokens

        logger.info(
            f"ContextBuilder: meeting={meeting_id}, "
            f"transcripts={len(transcripts)} ({transcript_tokens} tokens), "
            f"summaries={len(summaries)} ({summary_tokens} tokens), "
            f"documents={len(documents)} ({document_tokens} tokens), "
            f"total={total_tokens} tokens"
        )

        return {
            "meeting": meeting_context,
            "transcripts": transcripts,
            "summaries": summaries,
            "documents": documents,
            "token_counts": {
                "transcripts": transcript_tokens,
                "summaries": summary_tokens,
                "documents": document_tokens,
                "total": total_tokens
            }
        }

    async def _get_meeting_metadata(self, meeting_id: UUID) -> Dict[str, Any]:
        """Get meeting metadata for context."""
        result = await self.db.execute(
            select(Meeting).where(Meeting.id == meeting_id)
        )
        meeting = result.scalar_one_or_none()

        if not meeting:
            return {}

        duration_minutes = None
        if meeting.start_time and meeting.end_time:
            duration = meeting.end_time - meeting.start_time
            duration_minutes = int(duration.total_seconds() / 60)
        elif meeting.start_time:
            duration = datetime.now(timezone.utc) - meeting.start_time
            duration_minutes = int(duration.total_seconds() / 60)

        return {
            "id": str(meeting.id),
            "title": meeting.title or "Untitled Meeting",
            "platform": meeting.platform,
            "status": meeting.status.value if meeting.status else None,
            "start_time": meeting.start_time.isoformat() if meeting.start_time else None,
            "duration_minutes": duration_minutes,
        }

    async def _get_transcripts(
        self,
        meeting_id: UUID,
        config: ContextConfig
    ) -> Tuple[List[Dict[str, Any]], int]:
        """Get transcripts within time window, respecting token budget."""
        cutoff = datetime.now(timezone.utc) - timedelta(minutes=config.transcript_window_minutes)

        result = await self.db.execute(
            select(Transcript)
            .where(Transcript.meeting_id == meeting_id)
            .where(Transcript.created_at >= cutoff)
            .order_by(Transcript.created_at.desc())  # Most recent first
        )
        all_transcripts = result.scalars().all()

        # Build from most recent, respecting token budget
        selected = []
        total_tokens = 0

        for t in all_transcripts:
            tokens = self.token_service.count_tokens(t.text)
            if total_tokens + tokens > config.max_transcript_tokens:
                break

            selected.append({
                "id": str(t.id),
                "speaker": t.speaker or "unknown",
                "text": t.text,
                "timestamp": t.timestamp,
                "created_at": t.created_at.isoformat() if t.created_at else None,
            })
            total_tokens += tokens

        # Reverse to chronological order
        selected.reverse()

        return selected, total_tokens

    async def _get_summaries(
        self,
        meeting_id: UUID,
        config: ContextConfig
    ) -> Tuple[List[str], int]:
        """Get all summaries for the meeting, respecting token budget."""
        result = await self.db.execute(
            select(Summary)
            .where(Summary.meeting_id == meeting_id)
            .order_by(Summary.created_at.desc())  # Most recent first
        )
        all_summaries = result.scalars().all()

        selected = []
        total_tokens = 0

        for s in all_summaries:
            tokens = self.token_service.count_tokens(s.content)
            if total_tokens + tokens > config.max_summary_tokens:
                break

            selected.append(s.content)
            total_tokens += tokens

        # Reverse to chronological order
        selected.reverse()

        return selected, total_tokens

    async def _get_relevant_documents(
        self,
        meeting_id: UUID,
        query: str,
        config: ContextConfig
    ) -> Tuple[List[DocumentChunkResult], int]:
        """
        Get relevant document chunks with metadata and relevance filtering.

        Uses cosine similarity search with pgvector, filtering out
        chunks below the relevance threshold.
        """
        if not query:
            return [], 0

        # Generate query embedding
        query_embedding = await self.embedding_service.generate_embedding(query)

        # Query with cosine distance, fetch extra to allow filtering
        stmt = (
            select(
                ContextChunk,
                ContextDocument.filename,
                ContextChunk.embedding.cosine_distance(query_embedding).label('distance')
            )
            .join(ContextDocument)
            .where(ContextDocument.meeting_id == meeting_id)
            .order_by('distance')
            .limit(config.max_document_chunks * 2)  # Fetch extra for filtering
        )

        result = await self.db.execute(stmt)
        rows = result.all()

        selected = []
        total_tokens = 0

        for chunk, filename, distance in rows:
            # Convert distance to similarity (cosine distance is 1 - similarity)
            similarity = 1 - distance

            # Skip low-relevance chunks
            if similarity < config.relevance_threshold:
                logger.debug(f"Skipping chunk from {filename} (relevance={similarity:.2f} < {config.relevance_threshold})")
                continue

            # Check token budget
            tokens = self.token_service.count_tokens(chunk.chunk_text)
            if total_tokens + tokens > config.max_document_tokens:
                break

            # Check chunk limit
            if len(selected) >= config.max_document_chunks:
                break

            selected.append(DocumentChunkResult(
                text=chunk.chunk_text,
                document_id=chunk.document_id,
                document_filename=filename,
                chunk_index=chunk.chunk_index,
                relevance_score=round(similarity, 3)
            ))
            total_tokens += tokens

        logger.debug(f"Selected {len(selected)} document chunks from {len(rows)} candidates")

        return selected, total_tokens

    def format_for_prompt(self, context: Dict[str, Any]) -> str:
        """
        Format context dictionary into a prompt string with attribution.

        Creates a structured prompt section with:
        - Meeting metadata
        - Previous summaries
        - Relevant document excerpts with source attribution
        - Recent conversation
        """
        parts = []

        # Meeting metadata
        if context.get("meeting"):
            m = context["meeting"]
            parts.append(f"## Meeting: {m.get('title', 'Untitled')}")
            if m.get("platform"):
                parts.append(f"Platform: {m['platform']}")
            if m.get("duration_minutes"):
                parts.append(f"Duration: {m['duration_minutes']} minutes")
            parts.append("")

        # Previous summaries
        if context.get("summaries"):
            parts.append("## Previous Summaries")
            for i, summary in enumerate(context["summaries"], 1):
                parts.append(f"### Summary {i}")
                parts.append(summary)
            parts.append("")

        # Document context with attribution
        if context.get("documents"):
            parts.append("## Relevant Documents")
            for doc in context["documents"]:
                parts.append(f"### From: {doc.document_filename} (relevance: {doc.relevance_score:.0%})")
                parts.append(doc.text)
            parts.append("")

        # Recent conversation
        if context.get("transcripts"):
            parts.append("## Recent Conversation")
            for t in context["transcripts"]:
                speaker = t.get("speaker", "unknown")
                text = t.get("text", "")
                parts.append(f"[{speaker}]: {text}")

        return "\n".join(parts)

    def format_documents_only(self, documents: List[DocumentChunkResult]) -> str:
        """Format just the document chunks with attribution."""
        if not documents:
            return "No relevant documents found."

        parts = []
        for doc in documents:
            parts.append(f"[From: {doc.document_filename}]")
            parts.append(doc.text)
            parts.append("")

        return "\n".join(parts)

    def format_transcripts_only(self, transcripts: List[Dict[str, Any]]) -> str:
        """Format just the transcripts."""
        if not transcripts:
            return "No recent conversation."

        return "\n".join([
            f"[{t.get('speaker', 'unknown')}]: {t.get('text', '')}"
            for t in transcripts
        ])


def get_context_preset(name: str) -> ContextConfig:
    """Get a preset context configuration by name."""
    if name not in CONTEXT_PRESETS:
        logger.warning(f"Unknown context preset '{name}', using default query preset")
        return CONTEXT_PRESETS["query"]
    return CONTEXT_PRESETS[name]
