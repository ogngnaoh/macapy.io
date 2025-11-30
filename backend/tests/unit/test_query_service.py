"""
Unit tests for Query Service.

Tests query streaming, recaps, and on-demand summary generation.
"""

import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from datetime import datetime, timedelta
from uuid import uuid4

from app.services.query_service import QueryService


def create_mock_transcript(text: str, speaker: str = "User", minutes_ago: int = 0):
    """Helper to create mock transcript objects."""
    mock = MagicMock()
    mock.text = text
    mock.speaker = speaker
    mock.created_at = datetime.utcnow() - timedelta(minutes=minutes_ago)
    return mock


def create_mock_summary(content: str, minutes_ago: int = 5):
    """Helper to create mock summary objects."""
    mock = MagicMock()
    mock.content = content
    mock.created_at = datetime.utcnow() - timedelta(minutes=minutes_ago)
    mock.end_time = datetime.utcnow() - timedelta(minutes=minutes_ago)
    return mock


@pytest.mark.asyncio
class TestQueryServiceStream:
    """Tests for streaming query responses."""

    async def test_stream_query_response_basic(self):
        """Test basic streaming query response."""
        with patch('app.services.query_service.LLMService') as MockLLM:
            mock_llm = MagicMock()
            MockLLM.return_value = mock_llm

            # Mock context building
            mock_llm.build_context_within_limit.return_value = ("transcript", "summary")

            # Mock streaming
            async def mock_stream(*args, **kwargs):
                yield "Answer"
                yield " to"
                yield " query"

            mock_llm.answer_query_stream = mock_stream

            # Mock DB
            mock_db = AsyncMock()
            mock_result = MagicMock()
            mock_result.scalars.return_value.all.return_value = []
            mock_db.execute.return_value = mock_result

            service = QueryService()
            service.llm = mock_llm

            chunks = []
            async for chunk in service.stream_query_response(
                meeting_id=uuid4(),
                query="What was discussed?",
                db=mock_db,
                include_documents=False
            ):
                chunks.append(chunk)

            assert "".join(chunks) == "Answer to query"

    async def test_stream_query_response_with_transcripts(self):
        """Test streaming with transcript context."""
        with patch('app.services.query_service.LLMService') as MockLLM:
            mock_llm = MagicMock()
            MockLLM.return_value = mock_llm

            mock_llm.build_context_within_limit.return_value = (
                "[User]: Hello\n[Other]: Hi there",
                "Summary of meeting"
            )

            async def mock_stream(*args, **kwargs):
                yield "Response with context"

            mock_llm.answer_query_stream = mock_stream

            # Mock DB with transcripts
            mock_db = AsyncMock()
            transcripts = [
                create_mock_transcript("Hello", "User", 5),
                create_mock_transcript("Hi there", "Other", 4)
            ]
            mock_result = MagicMock()
            mock_result.scalars.return_value.all.return_value = transcripts
            mock_db.execute.return_value = mock_result

            service = QueryService()
            service.llm = mock_llm

            chunks = []
            async for chunk in service.stream_query_response(
                meeting_id=uuid4(),
                query="Test query?",
                db=mock_db,
                include_documents=False
            ):
                chunks.append(chunk)

            assert len(chunks) > 0


@pytest.mark.asyncio
class TestRecapGeneration:
    """Tests for 30-second recap generation."""

    async def test_generate_recap_with_transcripts(self):
        """Test recap generation with recent transcripts."""
        with patch('app.services.query_service.LLMService') as MockLLM:
            mock_llm = MagicMock()
            MockLLM.return_value = mock_llm

            mock_llm.generate_summary = AsyncMock(return_value="Quick recap summary")
            mock_llm.count_tokens.return_value = 50

            # Mock DB with recent transcripts
            mock_db = AsyncMock()
            transcripts = [
                create_mock_transcript("First point", "Speaker1", 0),
                create_mock_transcript("Second point", "Speaker2", 0)
            ]
            mock_result = MagicMock()
            mock_result.scalars.return_value.all.return_value = transcripts
            mock_db.execute.return_value = mock_result

            service = QueryService()
            service.llm = mock_llm

            result = await service.generate_recap(
                meeting_id=uuid4(),
                db=mock_db,
                duration_seconds=30
            )

            assert result["recap"] == "Quick recap summary"
            assert result["transcript_count"] == 2
            assert "tokens_used" in result

    async def test_generate_recap_no_transcripts(self):
        """Test recap when no recent transcripts exist."""
        with patch('app.services.query_service.LLMService') as MockLLM:
            mock_llm = MagicMock()
            MockLLM.return_value = mock_llm

            # Mock DB with no transcripts
            mock_db = AsyncMock()
            mock_result = MagicMock()
            mock_result.scalars.return_value.all.return_value = []
            mock_db.execute.return_value = mock_result

            service = QueryService()
            service.llm = mock_llm

            result = await service.generate_recap(
                meeting_id=uuid4(),
                db=mock_db,
                duration_seconds=30
            )

            assert "No recent conversation" in result["recap"]
            assert result["transcript_count"] == 0


@pytest.mark.asyncio
class TestSummaryNow:
    """Tests for on-demand summary generation."""

    async def test_generate_summary_now_success(self):
        """Test immediate summary generation."""
        with patch('app.services.query_service.LLMService') as MockLLM:
            mock_llm = MagicMock()
            MockLLM.return_value = mock_llm

            mock_llm.generate_summary = AsyncMock(return_value="Generated summary")

            # Mock DB
            mock_db = AsyncMock()

            # Mock no previous summary
            mock_summary_result = MagicMock()
            mock_summary_result.scalar_one_or_none.return_value = None

            # Mock transcripts
            transcripts = [create_mock_transcript("New content", "User")]
            mock_transcript_result = MagicMock()
            mock_transcript_result.scalars.return_value.all.return_value = transcripts

            mock_db.execute.side_effect = [
                mock_summary_result,
                mock_transcript_result
            ]

            service = QueryService()
            service.llm = mock_llm

            # The actual implementation calls db.add and db.commit
            # We need to also mock db.refresh to set the summary attributes
            async def mock_refresh(obj):
                obj.id = 1
                obj.content = "Generated summary"
                obj.start_time = datetime.utcnow()
                obj.end_time = datetime.utcnow()
                obj.created_at = datetime.utcnow()

            mock_db.refresh = mock_refresh

            result = await service.generate_summary_now(
                meeting_id=uuid4(),
                db=mock_db
            )

            assert result is not None
            assert result["content"] == "Generated summary"

    async def test_generate_summary_now_no_transcripts(self):
        """Test summary generation when no new transcripts exist."""
        with patch('app.services.query_service.LLMService') as MockLLM:
            mock_llm = MagicMock()
            MockLLM.return_value = mock_llm

            mock_db = AsyncMock()

            # Mock previous summary
            mock_prev_summary = create_mock_summary("Previous summary")
            mock_summary_result = MagicMock()
            mock_summary_result.scalar_one_or_none.return_value = mock_prev_summary

            # Mock no new transcripts
            mock_transcript_result = MagicMock()
            mock_transcript_result.scalars.return_value.all.return_value = []

            mock_db.execute.side_effect = [
                mock_summary_result,
                mock_transcript_result
            ]

            service = QueryService()
            service.llm = mock_llm

            result = await service.generate_summary_now(
                meeting_id=uuid4(),
                db=mock_db
            )

            assert result is None
