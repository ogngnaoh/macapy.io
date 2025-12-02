"""
Unit tests for RealtimeTranscriptionService.

Tests cover:
- Connection lifecycle (connect, disconnect, reconnect)
- Audio processing (send_audio, send_audio_numpy, resampling)
- Event handling (session.created, transcripts, errors)
- Queue and callback mechanisms
"""

import pytest
import asyncio
import json
import numpy as np
from unittest.mock import AsyncMock, MagicMock, patch
from dataclasses import dataclass

# Mark all tests in this file as unit tests
pytestmark = pytest.mark.unit


@pytest.fixture
def mock_websocket():
    """Create a mock WebSocket connection."""
    ws = AsyncMock()
    ws.send = AsyncMock()
    ws.close = AsyncMock()
    ws.closed = False
    return ws


@pytest.fixture
def mock_settings():
    """Mock settings for tests."""
    with patch('app.services.realtime_transcription.settings') as mock:
        mock.OPENAI_API_KEY = 'test-api-key'
        mock.REALTIME_MODEL = 'gpt-4o-realtime-preview'
        mock.REALTIME_SAMPLE_RATE = 24000
        yield mock


@pytest.fixture
def realtime_service(mock_settings):
    """Create a RealtimeTranscriptionService instance for testing."""
    with patch('app.services.realtime_transcription.WEBSOCKETS_AVAILABLE', True):
        from app.services.realtime_transcription import RealtimeTranscriptionService
        service = RealtimeTranscriptionService(api_key='test-key')
        return service


class TestConnectionLifecycle:
    """Tests for WebSocket connection management."""

    @pytest.mark.asyncio
    async def test_connect_success(self, realtime_service, mock_websocket):
        """Test successful WebSocket connection."""
        with patch('app.services.realtime_transcription.websockets') as mock_ws:
            mock_ws.connect = AsyncMock(return_value=mock_websocket)

            result = await realtime_service.connect()

            assert result is True
            assert realtime_service.is_connected is True
            mock_ws.connect.assert_called_once()

    @pytest.mark.asyncio
    async def test_connect_failure_returns_false(self, realtime_service):
        """Test connection failure returns False."""
        with patch('app.services.realtime_transcription.websockets') as mock_ws:
            mock_ws.connect = AsyncMock(side_effect=Exception("Connection failed"))

            result = await realtime_service.connect()

            assert result is False
            assert realtime_service.is_connected is False

    @pytest.mark.asyncio
    async def test_connect_already_connected(self, realtime_service, mock_websocket):
        """Test connecting when already connected is idempotent."""
        with patch('app.services.realtime_transcription.websockets') as mock_ws:
            mock_ws.connect = AsyncMock(return_value=mock_websocket)

            # First connection
            await realtime_service.connect()

            # Second connection attempt
            result = await realtime_service.connect()

            assert result is True
            # Should only connect once
            assert mock_ws.connect.call_count == 1

    @pytest.mark.asyncio
    async def test_close_cleanup(self, realtime_service, mock_websocket):
        """Test proper resource cleanup on close."""
        with patch('app.services.realtime_transcription.websockets') as mock_ws:
            mock_ws.connect = AsyncMock(return_value=mock_websocket)

            await realtime_service.connect()
            await realtime_service.close()

            assert realtime_service.ws is None
            assert realtime_service.session_id is None
            mock_websocket.close.assert_called_once()


class TestAudioProcessing:
    """Tests for audio data handling."""

    @pytest.mark.asyncio
    async def test_send_audio_bytes(self, realtime_service, mock_websocket):
        """Test sending raw audio bytes."""
        with patch('app.services.realtime_transcription.websockets') as mock_ws:
            mock_ws.connect = AsyncMock(return_value=mock_websocket)
            await realtime_service.connect()

            audio_bytes = b'\x00\x01' * 100
            await realtime_service.send_audio(audio_bytes)

            # Verify the message format
            call_args = mock_websocket.send.call_args_list
            # First call is session config, second is audio
            audio_call = call_args[1][0][0]
            data = json.loads(audio_call)
            assert data['type'] == 'input_audio_buffer.append'
            assert 'audio' in data

    @pytest.mark.asyncio
    async def test_send_audio_numpy_float32(self, realtime_service, mock_websocket):
        """Test float32 numpy array conversion to int16."""
        with patch('app.services.realtime_transcription.websockets') as mock_ws:
            mock_ws.connect = AsyncMock(return_value=mock_websocket)
            await realtime_service.connect()

            # Float32 audio data (normalized -1.0 to 1.0)
            audio_data = np.array([0.5, -0.5, 0.0, 1.0, -1.0], dtype=np.float32)
            await realtime_service.send_audio_numpy(audio_data)

            # Should convert and send successfully
            assert mock_websocket.send.call_count >= 2  # session config + audio

    @pytest.mark.asyncio
    async def test_send_audio_numpy_int16(self, realtime_service, mock_websocket):
        """Test int16 numpy array passthrough."""
        with patch('app.services.realtime_transcription.websockets') as mock_ws:
            mock_ws.connect = AsyncMock(return_value=mock_websocket)
            await realtime_service.connect()

            # Int16 audio data (already in correct format)
            audio_data = np.array([16383, -16383, 0, 32767, -32768], dtype=np.int16)
            await realtime_service.send_audio_numpy(audio_data)

            assert mock_websocket.send.call_count >= 2

    @pytest.mark.asyncio
    async def test_send_audio_not_connected(self, realtime_service):
        """Test sending audio when not connected does nothing."""
        audio_bytes = b'\x00\x01' * 100
        # Should not raise, just log warning
        await realtime_service.send_audio(audio_bytes)

    def test_resampling_16k_to_24k(self, mock_settings):
        """Test audio resampling from 16kHz to 24kHz."""
        from app.services.realtime_transcription import resample_to_24khz

        # 1 second of 16kHz audio
        orig_rate = 16000
        duration = 1.0
        samples = int(orig_rate * duration)
        audio = np.sin(2 * np.pi * 440 * np.arange(samples) / orig_rate).astype(np.float32)

        resampled = resample_to_24khz(audio, orig_rate)

        # Should have 24000 samples for 1 second
        expected_samples = int(24000 * duration)
        assert len(resampled) == expected_samples
        assert resampled.dtype == np.float32

    def test_resampling_already_24k(self, mock_settings):
        """Test resampling when already at target rate is a no-op."""
        from app.services.realtime_transcription import resample_to_24khz

        audio = np.random.randn(24000).astype(np.float32)
        resampled = resample_to_24khz(audio, 24000)

        # Should return original array unchanged
        np.testing.assert_array_equal(resampled, audio)


class TestEventHandling:
    """Tests for Realtime API event processing."""

    @pytest.mark.asyncio
    async def test_handle_session_created(self, realtime_service):
        """Test session.created event captures session ID."""
        event = {
            "type": "session.created",
            "session": {"id": "test-session-123"}
        }

        await realtime_service._handle_event(event)

        assert realtime_service.session_id == "test-session-123"

    @pytest.mark.asyncio
    async def test_handle_transcript_completed(self, realtime_service):
        """Test final transcript is queued correctly."""
        event = {
            "type": "conversation.item.input_audio_transcription.completed",
            "transcript": "Hello, this is a test.",
            "item_id": "item-123"
        }

        await realtime_service._handle_event(event)

        # Check transcript was added to queue
        assert not realtime_service._transcript_queue.empty()
        transcript = realtime_service._transcript_queue.get_nowait()
        assert transcript.text == "Hello, this is a test."
        assert transcript.is_final is True
        assert transcript.item_id == "item-123"

    @pytest.mark.asyncio
    async def test_handle_transcript_delta(self, realtime_service):
        """Test partial transcript delta is queued."""
        event = {
            "type": "conversation.item.input_audio_transcription.delta",
            "delta": "Hello",
            "item_id": "item-123"
        }

        await realtime_service._handle_event(event)

        assert not realtime_service._transcript_queue.empty()
        transcript = realtime_service._transcript_queue.get_nowait()
        assert transcript.text == "Hello"
        assert transcript.is_final is False

    @pytest.mark.asyncio
    async def test_handle_error_event(self, realtime_service):
        """Test error event triggers callback."""
        error_received = []
        realtime_service.set_on_error(lambda msg: error_received.append(msg))

        event = {
            "type": "error",
            "error": {
                "code": "invalid_request",
                "message": "Test error message"
            }
        }

        await realtime_service._handle_event(event)

        assert len(error_received) == 1
        assert "invalid_request" in error_received[0]
        assert "Test error message" in error_received[0]

    @pytest.mark.asyncio
    async def test_handle_unknown_event(self, realtime_service):
        """Test unknown event type is gracefully ignored."""
        event = {
            "type": "unknown.event.type",
            "data": "some data"
        }

        # Should not raise
        await realtime_service._handle_event(event)


class TestReconnection:
    """Tests for reconnection logic."""

    @pytest.mark.asyncio
    async def test_reconnect_attempts_limited(self, realtime_service):
        """Test reconnection stops after max attempts."""
        with patch('app.services.realtime_transcription.websockets') as mock_ws:
            mock_ws.connect = AsyncMock(side_effect=Exception("Connection failed"))

            # Reduce delay for testing
            realtime_service._reconnect_delay = 0.01
            realtime_service._max_reconnect_attempts = 3

            await realtime_service._reconnect()

            # Should have tried 3 times
            assert mock_ws.connect.call_count == 3
            from app.services.realtime_transcription import ConnectionState
            assert realtime_service.state == ConnectionState.ERROR

    @pytest.mark.asyncio
    async def test_reconnect_success(self, realtime_service, mock_websocket):
        """Test successful reconnection."""
        call_count = [0]

        async def mock_connect(*args, **kwargs):
            call_count[0] += 1
            if call_count[0] < 2:
                raise Exception("Failed first time")
            return mock_websocket

        with patch('app.services.realtime_transcription.websockets') as mock_ws:
            mock_ws.connect = mock_connect

            realtime_service._reconnect_delay = 0.01
            await realtime_service._reconnect()

            from app.services.realtime_transcription import ConnectionState
            assert realtime_service.state == ConnectionState.CONNECTED


class TestCallbacksAndQueue:
    """Tests for callback and queue functionality."""

    @pytest.mark.asyncio
    async def test_transcript_queue_receives(self, realtime_service):
        """Test transcript items are added to queue."""
        event = {
            "type": "conversation.item.input_audio_transcription.completed",
            "transcript": "Test transcript",
            "item_id": "test-id"
        }

        await realtime_service._handle_event(event)

        assert realtime_service._transcript_queue.qsize() == 1

    @pytest.mark.asyncio
    async def test_callback_invoked_on_transcript(self, realtime_service):
        """Test transcript callback is invoked."""
        transcripts_received = []
        realtime_service.set_on_transcript(lambda t: transcripts_received.append(t))

        event = {
            "type": "conversation.item.input_audio_transcription.completed",
            "transcript": "Callback test",
            "item_id": "test-id"
        }

        await realtime_service._handle_event(event)

        assert len(transcripts_received) == 1
        assert transcripts_received[0].text == "Callback test"

    @pytest.mark.asyncio
    async def test_callback_invoked_on_error(self, realtime_service):
        """Test error callback is invoked."""
        errors_received = []
        realtime_service.set_on_error(lambda e: errors_received.append(e))

        event = {
            "type": "error",
            "error": {"code": "test_error", "message": "Test"}
        }

        await realtime_service._handle_event(event)

        assert len(errors_received) == 1


class TestCommitAudioBuffer:
    """Tests for audio buffer commit functionality."""

    @pytest.mark.asyncio
    async def test_commit_audio_buffer(self, realtime_service, mock_websocket):
        """Test commit_audio_buffer sends correct event."""
        with patch('app.services.realtime_transcription.websockets') as mock_ws:
            mock_ws.connect = AsyncMock(return_value=mock_websocket)
            await realtime_service.connect()

            await realtime_service.commit_audio_buffer()

            # Find the commit call
            calls = mock_websocket.send.call_args_list
            commit_found = False
            for call in calls:
                data = json.loads(call[0][0])
                if data.get('type') == 'input_audio_buffer.commit':
                    commit_found = True
                    break

            assert commit_found, "commit event not found in calls"

    @pytest.mark.asyncio
    async def test_commit_audio_buffer_not_connected(self, realtime_service):
        """Test commit when not connected does nothing."""
        # Should not raise
        await realtime_service.commit_audio_buffer()


class TestSessionConfiguration:
    """Tests for session configuration."""

    @pytest.mark.asyncio
    async def test_session_config_sent_on_connect(self, realtime_service, mock_websocket):
        """Test session configuration is sent after connection."""
        with patch('app.services.realtime_transcription.websockets') as mock_ws:
            mock_ws.connect = AsyncMock(return_value=mock_websocket)

            await realtime_service.connect()

            # First send should be session config
            first_call = mock_websocket.send.call_args_list[0]
            data = json.loads(first_call[0][0])

            assert data['type'] == 'session.update'
            assert 'session' in data
            assert data['session']['input_audio_format'] == 'pcm16'
            assert 'turn_detection' in data['session']
