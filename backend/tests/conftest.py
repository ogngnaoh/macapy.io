import pytest
import pytest_asyncio
import asyncio
import sys
import platform
from unittest.mock import MagicMock, AsyncMock, patch

# Mock audio libraries BEFORE importing app modules to prevent DLL/framework issues
# Windows: pyaudiowpatch uses native DLLs that may not be available
sys.modules["pyaudiowpatch"] = MagicMock()

# macOS: Mock PyObjC frameworks for non-macOS environments or when frameworks unavailable
# These are only needed if ScreenCaptureKit is imported but not available
if platform.system() != "Darwin":
    # Mock all PyObjC frameworks on non-macOS
    sys.modules["objc"] = MagicMock()
    sys.modules["Foundation"] = MagicMock()
    sys.modules["AVFoundation"] = MagicMock()
    sys.modules["ScreenCaptureKit"] = MagicMock()
    sys.modules["CoreMedia"] = MagicMock()

from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from app.config import settings
from app.db.base import Base

# Removed event_loop fixture to let pytest-asyncio handle it (function scope by default)

@pytest_asyncio.fixture
async def engine():
    # Function scoped engine
    engine = create_async_engine(settings.DATABASE_URL, echo=False)
    yield engine
    await engine.dispose()

@pytest_asyncio.fixture
async def db_session(engine):
    async_session = async_sessionmaker(engine, expire_on_commit=False)
    async with async_session() as session:
        yield session

@pytest_asyncio.fixture
async def client(db_session):
    from httpx import AsyncClient, ASGITransport
    from app.main import app
    from app.db.session import get_db

    async def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac
    
    app.dependency_overrides.clear()


# ============================================================================
# OpenAI Responses API Fixtures
# ============================================================================

def create_mock_response_output(text: str):
    """Create a mock output structure matching Responses API format."""
    mock_content = MagicMock()
    mock_content.type = "output_text"
    mock_content.text = text

    mock_message = MagicMock()
    mock_message.type = "message"
    mock_message.content = [mock_content]

    return mock_message


@pytest.fixture
def mock_responses_api():
    """
    Mock OpenAI Responses API for LLM service testing.

    Provides a mock client with responses.create() that returns
    properly structured Responses API format.
    """
    with patch('openai.AsyncOpenAI') as mock_openai:
        mock_client = MagicMock()
        mock_openai.return_value = mock_client

        # Create mock response object
        mock_response = MagicMock()
        mock_response.output = [create_mock_response_output("Mock response text")]

        # Mock responses.create() as async
        mock_client.responses = MagicMock()
        mock_client.responses.create = AsyncMock(return_value=mock_response)

        yield mock_client


@pytest.fixture
def mock_responses_api_streaming():
    """
    Mock OpenAI Responses API for streaming tests.

    Returns an async generator that yields streaming events.
    """
    with patch('openai.AsyncOpenAI') as mock_openai:
        mock_client = MagicMock()
        mock_openai.return_value = mock_client

        async def mock_stream():
            """Mock streaming response that yields delta events."""
            events = [
                MagicMock(type="response.output_text.delta", delta="Hello"),
                MagicMock(type="response.output_text.delta", delta=" "),
                MagicMock(type="response.output_text.delta", delta="World"),
                MagicMock(type="response.output_text.done", text="Hello World"),
            ]
            for event in events:
                yield event

        mock_client.responses = MagicMock()
        mock_client.responses.create = AsyncMock(return_value=mock_stream())

        yield mock_client


@pytest.fixture
def mock_responses_api_json():
    """
    Mock OpenAI Responses API for JSON format tests.

    Returns a response with JSON content for suggestion generation.
    """
    with patch('openai.AsyncOpenAI') as mock_openai:
        mock_client = MagicMock()
        mock_openai.return_value = mock_client

        json_content = '{"suggestions": ["Response 1", "Response 2", "Response 3"]}'
        mock_response = MagicMock()
        mock_response.output = [create_mock_response_output(json_content)]

        mock_client.responses = MagicMock()
        mock_client.responses.create = AsyncMock(return_value=mock_response)

        yield mock_client


@pytest.fixture
def mock_audio_api():
    """
    Mock OpenAI Audio API for transcription tests.

    Keeps Audio API separate from Responses API since
    transcription uses client.audio.transcriptions.create().
    """
    with patch('openai.AsyncOpenAI') as mock_openai:
        mock_client = MagicMock()
        mock_openai.return_value = mock_client

        # Mock audio.transcriptions.create()
        mock_client.audio = MagicMock()
        mock_client.audio.transcriptions = MagicMock()
        mock_client.audio.transcriptions.create = AsyncMock(
            return_value="This is a test transcription."
        )

        yield mock_client
