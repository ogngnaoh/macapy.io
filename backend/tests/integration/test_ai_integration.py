"""
Integration tests for AI services using OpenAI Responses API.

Tests LLM service integration with mocked OpenAI API responses.
"""

import pytest
from unittest.mock import AsyncMock, patch, MagicMock
from app.services.llm_service import LLMService


def create_mock_response(text: str):
    """Helper to create mock Responses API response structure."""
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
async def test_generate_summary():
    """Test summary generation with mocked Responses API."""
    with patch("openai.AsyncOpenAI") as mock_openai_cls:
        mock_client = MagicMock()
        mock_openai_cls.return_value = mock_client

        # Mock Responses API response format
        mock_response = create_mock_response("This is a summary.")
        mock_client.responses = MagicMock()
        mock_client.responses.create = AsyncMock(return_value=mock_response)

        service = LLMService()
        summary = await service.generate_summary("Transcript text here.")

        assert summary == "This is a summary."
        mock_client.responses.create.assert_called_once()


@pytest.mark.asyncio
async def test_generate_suggestion():
    """Test suggestion generation with JSON response."""
    with patch("openai.AsyncOpenAI") as mock_openai_cls:
        mock_client = MagicMock()
        mock_openai_cls.return_value = mock_client

        # Mock Responses API with JSON content
        json_content = '{"suggestions": ["Suggested response."]}'
        mock_response = create_mock_response(json_content)
        mock_client.responses = MagicMock()
        mock_client.responses.create = AsyncMock(return_value=mock_response)

        service = LLMService()
        suggestions = await service.generate_suggestion(
            question="Question?",
            transcript_context="Context",
            document_context=[]
        )

        assert "Suggested response." in suggestions


@pytest.mark.asyncio
async def test_detect_question():
    """Test question detection with mocked Responses API."""
    with patch("openai.AsyncOpenAI") as mock_openai_cls:
        mock_client = MagicMock()
        mock_openai_cls.return_value = mock_client

        # Mock YES response
        mock_response = create_mock_response("YES")
        mock_client.responses = MagicMock()
        mock_client.responses.create = AsyncMock(return_value=mock_response)

        service = LLMService()
        result = await service.detect_question("Can you tell me about yourself?")

        assert result is True


@pytest.mark.asyncio
async def test_answer_query_stream():
    """Test streaming query answer with mocked Responses API."""
    with patch("openai.AsyncOpenAI") as mock_openai_cls:
        mock_client = MagicMock()
        mock_openai_cls.return_value = mock_client

        # Mock streaming response
        async def mock_stream():
            events = [
                MagicMock(type="response.output_text.delta", delta="Stream"),
                MagicMock(type="response.output_text.delta", delta="ed"),
                MagicMock(type="response.output_text.delta", delta=" answer"),
            ]
            for event in events:
                yield event

        mock_client.responses = MagicMock()
        mock_client.responses.create = AsyncMock(return_value=mock_stream())

        service = LLMService()
        chunks = []
        async for chunk in service.answer_query_stream(
            question="Test question?",
            transcript_context="Context",
            summary_context="Summary",
            document_context=[]
        ):
            chunks.append(chunk)

        assert "".join(chunks) == "Streamed answer"


@pytest.mark.asyncio
async def test_generate_summary_stream():
    """Test streaming summary generation."""
    with patch("openai.AsyncOpenAI") as mock_openai_cls:
        mock_client = MagicMock()
        mock_openai_cls.return_value = mock_client

        # Mock streaming response
        async def mock_stream():
            events = [
                MagicMock(type="response.output_text.delta", delta="- Key"),
                MagicMock(type="response.output_text.delta", delta=" point"),
            ]
            for event in events:
                yield event

        mock_client.responses = MagicMock()
        mock_client.responses.create = AsyncMock(return_value=mock_stream())

        service = LLMService()
        chunks = []
        async for chunk in service.generate_summary_stream("Test transcript"):
            chunks.append(chunk)

        assert "".join(chunks) == "- Key point"
