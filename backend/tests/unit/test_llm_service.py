"""
Unit tests for LLM Service with OpenAI Responses API.

Tests all LLM service methods with proper mocking of the Responses API format.
"""

import pytest
from unittest.mock import AsyncMock, MagicMock, patch
import json

from app.services.llm_service import LLMService


def create_mock_response(text: str):
    """Helper to create mock Responses API response."""
    mock_content = MagicMock()
    mock_content.type = "output_text"
    mock_content.text = text

    mock_message = MagicMock()
    mock_message.type = "message"
    mock_message.content = [mock_content]

    mock_response = MagicMock()
    mock_response.output = [mock_message]

    return mock_response


@pytest.mark.asyncio
class TestLLMServiceSummary:
    """Tests for summary generation."""

    async def test_generate_summary_success(self):
        """Test summary generation with valid transcript."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client

            mock_response = create_mock_response("- Key decision: Launch new feature\n- Action item: Review docs")
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(return_value=mock_response)

            service = LLMService()
            result = await service.generate_summary("We decided to launch the new feature next week.")

            assert "Key decision" in result or "Launch" in result or len(result) > 0
            mock_client.responses.create.assert_called_once()

    async def test_generate_summary_empty_input(self):
        """Test that empty input returns empty string without API call."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock()

            service = LLMService()
            result = await service.generate_summary("")

            assert result == ""
            mock_client.responses.create.assert_not_called()

    async def test_generate_summary_whitespace_only(self):
        """Test that whitespace-only input returns empty string."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock()

            service = LLMService()
            result = await service.generate_summary("   \n\t  ")

            assert result == ""
            mock_client.responses.create.assert_not_called()

    async def test_generate_summary_api_error(self):
        """Test graceful handling of API errors."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(side_effect=Exception("API Error"))

            service = LLMService()
            result = await service.generate_summary("Test transcript")

            assert result == ""


@pytest.mark.asyncio
class TestLLMServiceSummaryStream:
    """Tests for streaming summary generation."""

    async def test_generate_summary_stream_success(self):
        """Test streaming summary returns chunks."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client

            async def mock_stream():
                events = [
                    MagicMock(type="response.output_text.delta", delta="- Key"),
                    MagicMock(type="response.output_text.delta", delta=" point"),
                    MagicMock(type="response.output_text.delta", delta=": Done"),
                ]
                for event in events:
                    yield event

            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(return_value=mock_stream())

            service = LLMService()
            chunks = []
            async for chunk in service.generate_summary_stream("Test transcript"):
                chunks.append(chunk)

            assert len(chunks) == 3
            assert "".join(chunks) == "- Key point: Done"

    async def test_generate_summary_stream_empty_input(self):
        """Test streaming with empty input yields nothing."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock()

            service = LLMService()
            chunks = []
            async for chunk in service.generate_summary_stream(""):
                chunks.append(chunk)

            assert len(chunks) == 0
            mock_client.responses.create.assert_not_called()


@pytest.mark.asyncio
class TestLLMServiceQuestionDetection:
    """Tests for question detection."""

    async def test_detect_question_yes(self):
        """Test detection of direct questions."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client

            mock_response = create_mock_response("YES")
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(return_value=mock_response)

            service = LLMService()
            result = await service.detect_question("Can you tell me about your experience?")

            assert result is True

    async def test_detect_question_no(self):
        """Test detection returns False for non-questions."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client

            mock_response = create_mock_response("NO")
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(return_value=mock_response)

            service = LLMService()
            result = await service.detect_question("Is this a rhetorical question?")

            assert result is False

    async def test_detect_question_no_question_mark(self):
        """Test early return when text has no question mark."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock()

            service = LLMService()
            result = await service.detect_question("This is a statement about our progress.")

            assert result is False
            mock_client.responses.create.assert_not_called()

    async def test_detect_question_case_insensitive(self):
        """Test YES detection is case insensitive."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client

            mock_response = create_mock_response("yes")
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(return_value=mock_response)

            service = LLMService()
            result = await service.detect_question("What do you think?")

            assert result is True


@pytest.mark.asyncio
class TestLLMServiceSuggestions:
    """Tests for suggestion generation."""

    async def test_generate_suggestion_success(self):
        """Test suggestion generation returns list."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client

            json_content = '{"suggestions": ["Response 1", "Response 2", "Response 3"]}'
            mock_response = create_mock_response(json_content)
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(return_value=mock_response)

            service = LLMService()
            result = await service.generate_suggestion(
                question="What's your experience with Python?",
                transcript_context="Interviewer asked about technical skills",
                document_context=["Resume: 5 years Python experience"]
            )

            assert len(result) == 3
            assert "Response 1" in result

    async def test_generate_suggestion_options_key(self):
        """Test fallback to 'options' key in JSON."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client

            json_content = '{"options": ["Option A", "Option B"]}'
            mock_response = create_mock_response(json_content)
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(return_value=mock_response)

            service = LLMService()
            result = await service.generate_suggestion(
                question="Test?",
                transcript_context="Context",
                document_context=[]
            )

            assert len(result) == 2
            assert "Option A" in result

    async def test_generate_suggestion_json_parse_error(self):
        """Test handling of invalid JSON response."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client

            mock_response = create_mock_response("This is not valid JSON")
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(return_value=mock_response)

            service = LLMService()
            result = await service.generate_suggestion(
                question="Test?",
                transcript_context="Context",
                document_context=[]
            )

            assert result == []

    async def test_generate_suggestion_empty_document_context(self):
        """Test suggestion with empty document context."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client

            json_content = '{"suggestions": ["Suggestion"]}'
            mock_response = create_mock_response(json_content)
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(return_value=mock_response)

            service = LLMService()
            result = await service.generate_suggestion(
                question="Test?",
                transcript_context="Context",
                document_context=[]
            )

            assert len(result) == 1


@pytest.mark.asyncio
class TestLLMServiceQueryStream:
    """Tests for streaming query answers."""

    async def test_answer_query_stream_success(self):
        """Test streaming query response."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client

            async def mock_stream():
                events = [
                    MagicMock(type="response.output_text.delta", delta="The answer"),
                    MagicMock(type="response.output_text.delta", delta=" is 42."),
                ]
                for event in events:
                    yield event

            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(return_value=mock_stream())

            service = LLMService()
            chunks = []
            async for chunk in service.answer_query_stream(
                question="What is the meaning of life?",
                transcript_context="Meeting about philosophy",
                summary_context="Discussed existential questions",
                document_context=["Reference: Douglas Adams"]
            ):
                chunks.append(chunk)

            assert len(chunks) == 2
            assert "".join(chunks) == "The answer is 42."

    async def test_answer_query_stream_api_error(self):
        """Test error handling yields error message."""
        with patch('openai.AsyncOpenAI') as mock_openai:
            mock_client = MagicMock()
            mock_openai.return_value = mock_client
            mock_client.responses = MagicMock()
            mock_client.responses.create = AsyncMock(side_effect=Exception("API Error"))

            service = LLMService()
            chunks = []
            async for chunk in service.answer_query_stream(
                question="Test?",
                transcript_context="",
                summary_context="",
                document_context=[]
            ):
                chunks.append(chunk)

            assert "Error" in "".join(chunks)


class TestLLMServiceTokenCounting:
    """Tests for token counting (synchronous)."""

    def test_count_tokens_basic(self):
        """Test token counting with normal text."""
        with patch('openai.AsyncOpenAI'):
            service = LLMService()
            count = service.count_tokens("Hello, world!")

            # Should return a positive integer
            assert count > 0
            assert isinstance(count, int)

    def test_count_tokens_empty(self):
        """Test token counting with empty string."""
        with patch('openai.AsyncOpenAI'):
            service = LLMService()
            count = service.count_tokens("")

            assert count == 0

    def test_count_tokens_none(self):
        """Test token counting with None-like input."""
        with patch('openai.AsyncOpenAI'):
            service = LLMService()
            count = service.count_tokens("")

            assert count == 0


class TestLLMServiceContextBuilding:
    """Tests for context building within token limits."""

    def test_build_context_within_limit(self):
        """Test context building prioritizes recent transcripts."""
        with patch('openai.AsyncOpenAI'):
            service = LLMService()

            transcripts = [
                "Old transcript from morning",
                "Mid-day discussion",
                "Recent afternoon meeting"
            ]
            summaries = ["Summary 1", "Summary 2"]

            transcript_text, summary_text = service.build_context_within_limit(
                transcripts=transcripts,
                summaries=summaries,
                max_tokens=200_000
            )

            # All should fit within 200k tokens
            assert "Summary 1" in summary_text
            assert "Summary 2" in summary_text

    def test_build_context_respects_limit(self):
        """Test that context respects token limits."""
        with patch('openai.AsyncOpenAI'):
            service = LLMService()

            # Create large transcripts
            large_transcript = "word " * 1000  # ~1000 words
            transcripts = [large_transcript] * 100  # 100 large transcripts
            summaries = ["Short summary"]

            transcript_text, summary_text = service.build_context_within_limit(
                transcripts=transcripts,
                summaries=summaries,
                max_tokens=5000  # Very limited
            )

            # Should truncate transcripts to fit
            total_tokens = service.count_tokens(transcript_text) + service.count_tokens(summary_text)
            assert total_tokens < 5000


class TestLLMServiceExtractText:
    """Tests for response text extraction helper."""

    def test_extract_text_from_response_success(self):
        """Test extracting text from valid response."""
        with patch('openai.AsyncOpenAI'):
            service = LLMService()

            mock_response = create_mock_response("Expected text")
            result = service._extract_text_from_response(mock_response)

            assert result == "Expected text"

    def test_extract_text_from_empty_response(self):
        """Test extracting text from empty response."""
        with patch('openai.AsyncOpenAI'):
            service = LLMService()

            mock_response = MagicMock()
            mock_response.output = []

            result = service._extract_text_from_response(mock_response)

            assert result == ""

    def test_extract_text_from_none_output(self):
        """Test extracting text when output is None."""
        with patch('openai.AsyncOpenAI'):
            service = LLMService()

            mock_response = MagicMock()
            mock_response.output = None

            result = service._extract_text_from_response(mock_response)

            assert result == ""
