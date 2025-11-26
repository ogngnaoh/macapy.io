import pytest
from unittest.mock import AsyncMock, patch, MagicMock
from app.services.llm_service import LLMService

@pytest.mark.asyncio
async def test_generate_summary():
    # Mock the OpenAI client globally
    with patch("openai.AsyncOpenAI") as mock_openai_cls:
        mock_client = AsyncMock()
        mock_openai_cls.return_value = mock_client
        
        # Mock chat completion response
        mock_completion = MagicMock()
        mock_completion.choices[0].message.content = "This is a summary."
        mock_client.chat.completions.create.return_value = mock_completion
        
        service = LLMService()
        summary = await service.generate_summary("Transcript text here.")
        
        assert summary == "This is a summary."
        mock_client.chat.completions.create.assert_called_once()

@pytest.mark.asyncio
async def test_generate_suggestion():
    with patch("openai.AsyncOpenAI") as mock_openai_cls:
        mock_client = AsyncMock()
        mock_openai_cls.return_value = mock_client
        
        mock_completion = MagicMock()
        mock_completion.choices[0].message.content = '{"suggestions": ["Suggested response."]}'
        mock_client.chat.completions.create.return_value = mock_completion
        
        service = LLMService()
        suggestion = await service.generate_suggestion("Context", "Question?", [])
        
        assert "Suggested response." in suggestion
