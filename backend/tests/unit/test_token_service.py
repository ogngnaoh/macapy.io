"""
Unit tests for Token Service.

Tests token counting, context window management, and usage tracking.
"""

import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

from app.services.token_service import (
    TokenService,
    MAX_CONTEXT_TOKENS,
    WARNING_THRESHOLD,
    DANGER_THRESHOLD,
)


class TestTokenCounting:
    """Tests for token counting functionality."""

    def test_count_tokens_basic(self):
        """Test basic token counting."""
        service = TokenService()
        count = service.count_tokens("Hello, world!")

        # Should return a positive integer
        assert count > 0
        assert isinstance(count, int)

    def test_count_tokens_empty(self):
        """Test token counting with empty string."""
        service = TokenService()
        count = service.count_tokens("")

        assert count == 0

    def test_count_tokens_long_text(self):
        """Test token counting with longer text."""
        service = TokenService()
        text = "This is a test sentence. " * 100
        count = service.count_tokens(text)

        # Should be proportional to text length
        assert count > 100

    def test_count_tokens_special_characters(self):
        """Test token counting with special characters."""
        service = TokenService()
        text = "Hello! 🎉 Special chars: @#$%^&*()"
        count = service.count_tokens(text)

        assert count > 0

    def test_count_tokens_batch(self):
        """Test batch token counting."""
        service = TokenService()
        texts = ["Hello", "World", "Test sentence here"]
        total = service.count_tokens_batch(texts)

        # Should be sum of individual counts
        expected = sum(service.count_tokens(t) for t in texts)
        assert total == expected

    def test_count_tokens_batch_empty_list(self):
        """Test batch counting with empty list."""
        service = TokenService()
        total = service.count_tokens_batch([])

        assert total == 0


class TestContextLimitChecking:
    """Tests for context limit checking."""

    def test_check_context_limit_under_limit(self):
        """Test checking when well under context limit."""
        service = TokenService()
        result = service.check_context_limit(
            current_tokens=1000,
            new_text="Short text"
        )

        assert result["would_exceed"] is False
        assert result["warning"] is False
        assert result["danger"] is False
        assert result["recommendation"] is None

    def test_check_context_limit_warning_threshold(self):
        """Test warning when approaching limit."""
        service = TokenService()
        # Set current tokens to be just above warning threshold after adding new text
        warning_tokens = int(MAX_CONTEXT_TOKENS * WARNING_THRESHOLD) + 1000

        result = service.check_context_limit(
            current_tokens=warning_tokens,
            new_text="Test"
        )

        assert result["warning"] is True
        assert "Warning" in str(result["recommendation"])

    def test_check_context_limit_danger_threshold(self):
        """Test danger when near limit."""
        service = TokenService()
        # Set current tokens to be just above danger threshold
        danger_tokens = int(MAX_CONTEXT_TOKENS * DANGER_THRESHOLD) + 1000

        result = service.check_context_limit(
            current_tokens=danger_tokens,
            new_text="Test"
        )

        assert result["danger"] is True
        assert "Critical" in str(result["recommendation"])

    def test_check_context_limit_would_exceed(self):
        """Test detection of exceeding limit."""
        service = TokenService()

        result = service.check_context_limit(
            current_tokens=MAX_CONTEXT_TOKENS - 10,
            new_text="A" * 1000  # Much larger than 10 tokens
        )

        assert result["would_exceed"] is True


class TestRecommendations:
    """Tests for usage recommendations."""

    def test_recommendation_normal_usage(self):
        """Test no recommendation for normal usage."""
        service = TokenService()
        recommendation = service._get_recommendation(50.0)

        assert recommendation is None

    def test_recommendation_warning_level(self):
        """Test warning recommendation."""
        service = TokenService()
        recommendation = service._get_recommendation(WARNING_THRESHOLD * 100 + 1)

        assert "Warning" in recommendation

    def test_recommendation_danger_level(self):
        """Test danger recommendation."""
        service = TokenService()
        recommendation = service._get_recommendation(DANGER_THRESHOLD * 100 + 1)

        assert "Critical" in recommendation


class TestQueryCostEstimation:
    """Tests for query cost estimation."""

    def test_estimate_query_cost_basic(self):
        """Test basic cost estimation."""
        service = TokenService()
        result = service.estimate_query_cost(
            query="What happened in the meeting?",
            context_length=5000
        )

        assert "query_tokens" in result
        assert "context_tokens" in result
        assert result["context_tokens"] == 5000
        assert result["total_input"] == result["query_tokens"] + 5000

    def test_estimate_query_cost_empty_query(self):
        """Test cost estimation with empty query."""
        service = TokenService()
        result = service.estimate_query_cost(
            query="",
            context_length=1000
        )

        assert result["query_tokens"] == 0
        assert result["total_input"] == 1000


@pytest.mark.asyncio
class TestMeetingTokenUsage:
    """Tests for meeting-level token usage tracking."""

    async def test_get_meeting_token_usage(self):
        """Test getting token usage for a meeting."""
        service = TokenService()
        meeting_id = uuid4()

        # Mock DB
        mock_db = AsyncMock()

        # Mock transcript query
        mock_transcript_result = MagicMock()
        mock_transcript_result.scalars.return_value.all.return_value = [
            "First transcript",
            "Second transcript"
        ]

        # Mock summary query
        mock_summary_result = MagicMock()
        mock_summary_result.scalars.return_value.all.return_value = [
            "Summary content"
        ]

        mock_db.execute.side_effect = [
            mock_transcript_result,
            mock_summary_result
        ]

        result = await service.get_meeting_token_usage(meeting_id, mock_db)

        assert "current_tokens" in result
        assert "max_tokens" in result
        assert result["max_tokens"] == MAX_CONTEXT_TOKENS
        assert "breakdown" in result
        assert "transcripts" in result["breakdown"]
        assert "summaries" in result["breakdown"]

    async def test_get_meeting_token_usage_empty(self):
        """Test token usage when meeting has no content."""
        service = TokenService()
        meeting_id = uuid4()

        mock_db = AsyncMock()

        # Empty results
        mock_result = MagicMock()
        mock_result.scalars.return_value.all.return_value = []
        mock_db.execute.return_value = mock_result

        result = await service.get_meeting_token_usage(meeting_id, mock_db)

        assert result["current_tokens"] == 0
        assert result["percentage"] == 0


@pytest.mark.asyncio
class TestBroadcastTokenUsage:
    """Tests for WebSocket token usage broadcasting."""

    async def test_broadcast_token_usage(self):
        """Test broadcasting token usage to clients."""
        with patch('app.services.token_service.manager') as mock_manager:
            mock_manager.broadcast_to_meeting = AsyncMock()

            service = TokenService()
            meeting_id = str(uuid4())

            mock_db = AsyncMock()
            mock_result = MagicMock()
            mock_result.scalars.return_value.all.return_value = []
            mock_db.execute.return_value = mock_result

            await service.broadcast_token_usage(meeting_id, mock_db)

            mock_manager.broadcast_to_meeting.assert_called_once()
            call_args = mock_manager.broadcast_to_meeting.call_args
            assert call_args[0][0]["type"] == "token_usage"

    async def test_broadcast_token_usage_error_handling(self):
        """Test error handling during broadcast."""
        with patch('app.services.token_service.manager') as mock_manager:
            mock_manager.broadcast_to_meeting = AsyncMock(
                side_effect=Exception("WebSocket error")
            )

            service = TokenService()

            mock_db = AsyncMock()
            mock_result = MagicMock()
            mock_result.scalars.return_value.all.return_value = []
            mock_db.execute.return_value = mock_result

            # Should not raise, just log error
            await service.broadcast_token_usage(str(uuid4()), mock_db)
