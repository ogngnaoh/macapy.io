"""
Unit tests for AudioCaptureService shared utilities.

Tests resampling, audio level calculation, and chunk metadata creation.
ScreenCaptureKit integration is tested via integration tests on real macOS hardware.
"""
import pytest
import numpy as np
from unittest.mock import MagicMock, patch, AsyncMock
import sys

# Mock platform-specific imports before importing the service
sys.modules["pyaudiowpatch"] = MagicMock()

# Mock PyObjC for non-macOS
import platform
if platform.system() != "Darwin":
    sys.modules["objc"] = MagicMock()
    sys.modules["Foundation"] = MagicMock()
    sys.modules["AVFoundation"] = MagicMock()
    sys.modules["ScreenCaptureKit"] = MagicMock()
    sys.modules["CoreMedia"] = MagicMock()

from app.services.audio_capture import (
    AudioCaptureService,
    AudioChunk,
    AudioDeviceInfo,
    CaptureStatus,
    AUDIO_BACKEND
)


@pytest.fixture
def audio_service():
    """Create a fresh AudioCaptureService for each test."""
    # Mock the backend check to allow instantiation
    with patch.dict('app.services.audio_capture.__dict__', {'SYSTEM': 'Darwin', 'AUDIO_BACKEND': 'screencapturekit'}):
        service = AudioCaptureService(
            sample_rate=16000,
            channels=1,
            chunk_duration=1.0
        )
        return service


class TestAudioServiceInitialization:
    """Tests for AudioCaptureService initialization."""

    def test_service_initialization(self, audio_service):
        """Test that service initializes with correct parameters."""
        assert audio_service.sample_rate == 16000
        assert audio_service.channels == 1
        assert audio_service.chunk_duration == 1.0
        assert audio_service.chunk_size == 16000  # sample_rate * chunk_duration
        assert audio_service.status == CaptureStatus.IDLE
        assert audio_service.current_audio_level == 0.0
        assert audio_service.total_chunks_captured == 0

    def test_service_default_initialization(self):
        """Test service with default settings from config."""
        with patch.dict('app.services.audio_capture.__dict__', {'SYSTEM': 'Darwin', 'AUDIO_BACKEND': 'screencapturekit'}):
            service = AudioCaptureService()
            # Default values from settings
            assert service.sample_rate > 0
            assert service.channels >= 1
            assert service.chunk_duration > 0


class TestAudioLevelCalculation:
    """Tests for audio level (RMS) calculation."""

    def test_audio_level_silence(self, audio_service):
        """Test audio level for silence (all zeros)."""
        silence = np.zeros(16000, dtype=np.float32)
        level = audio_service._calculate_audio_level(silence)
        assert level == 0.0

    def test_audio_level_max(self, audio_service):
        """Test audio level for maximum amplitude."""
        max_signal = np.ones(16000, dtype=np.float32)
        level = audio_service._calculate_audio_level(max_signal)
        assert level == 1.0

    def test_audio_level_negative_max(self, audio_service):
        """Test audio level for negative maximum amplitude."""
        neg_max = -np.ones(16000, dtype=np.float32)
        level = audio_service._calculate_audio_level(neg_max)
        assert level == 1.0

    def test_audio_level_sine_wave(self, audio_service):
        """Test audio level for sine wave with known RMS."""
        # RMS of sine wave with amplitude A is A/sqrt(2) ≈ 0.707*A
        t = np.linspace(0, 1, 16000)
        amplitude = 0.5
        sine_wave = (amplitude * np.sin(2 * np.pi * 440 * t)).astype(np.float32)

        level = audio_service._calculate_audio_level(sine_wave)
        expected_rms = amplitude / np.sqrt(2)  # ~0.354

        assert abs(level - expected_rms) < 0.01

    def test_audio_level_clamped_high(self, audio_service):
        """Test that audio level is clamped to 1.0 for very loud signals."""
        loud_signal = np.ones(16000, dtype=np.float32) * 2.0  # Beyond normal range
        level = audio_service._calculate_audio_level(loud_signal)
        assert level == 1.0

    def test_audio_level_random_noise(self, audio_service):
        """Test audio level for random noise is within expected range."""
        np.random.seed(42)
        noise = np.random.randn(16000).astype(np.float32) * 0.3
        level = audio_service._calculate_audio_level(noise)

        # Level should be reasonable for 0.3 amplitude random noise
        assert 0.2 < level < 0.4


class TestAudioResampling:
    """Tests for audio resampling functionality."""

    def test_resample_no_change(self, audio_service):
        """Test that same sample rate returns unchanged audio."""
        audio = np.random.randn(16000).astype(np.float32)
        result = audio_service._resample_audio(audio, 16000, 16000)

        np.testing.assert_array_equal(audio, result)

    def test_resample_48k_to_16k(self, audio_service):
        """Test downsampling from 48kHz to 16kHz."""
        # 1 second at 48kHz = 48000 samples
        audio_48k = np.random.randn(48000).astype(np.float32)
        result = audio_service._resample_audio(audio_48k, 48000, 16000)

        # Should have ~16000 samples (1% tolerance for resampling)
        expected_samples = 16000
        assert abs(len(result) - expected_samples) < expected_samples * 0.01

    def test_resample_44k_to_16k(self, audio_service):
        """Test downsampling from 44.1kHz to 16kHz."""
        audio_44k = np.random.randn(44100).astype(np.float32)
        result = audio_service._resample_audio(audio_44k, 44100, 16000)

        expected_samples = 16000
        assert abs(len(result) - expected_samples) < expected_samples * 0.02

    def test_resample_preserves_dtype(self, audio_service):
        """Test that resampling preserves float32 dtype."""
        audio = np.random.randn(48000).astype(np.float32)
        result = audio_service._resample_audio(audio, 48000, 16000)

        assert result.dtype == np.float32


class TestAudioChunk:
    """Tests for AudioChunk dataclass."""

    def test_audio_chunk_creation(self):
        """Test AudioChunk creation with all fields."""
        data = np.zeros(16000, dtype=np.float32)
        chunk = AudioChunk(
            data=data,
            timestamp=1234567890.0,
            duration=1.0,
            sample_rate=16000,
            channels=1,
            audio_level=0.5,
            source="system"
        )

        assert chunk.timestamp == 1234567890.0
        assert chunk.duration == 1.0
        assert chunk.sample_rate == 16000
        assert chunk.channels == 1
        assert chunk.audio_level == 0.5
        assert chunk.source == "system"
        assert len(chunk.data) == 16000

    def test_audio_chunk_default_source(self):
        """Test AudioChunk default source value."""
        data = np.zeros(16000, dtype=np.float32)
        chunk = AudioChunk(
            data=data,
            timestamp=0.0,
            duration=1.0,
            sample_rate=16000,
            channels=1,
            audio_level=0.0
        )

        assert chunk.source == "unknown"


class TestAudioDeviceInfo:
    """Tests for AudioDeviceInfo dataclass."""

    def test_device_info_creation(self):
        """Test AudioDeviceInfo creation."""
        device = AudioDeviceInfo(
            index=0,
            name="Test Device",
            channels=2,
            sample_rate=48000,
            is_loopback=True,
            is_default=False
        )

        assert device.index == 0
        assert device.name == "Test Device"
        assert device.channels == 2
        assert device.sample_rate == 48000
        assert device.is_loopback is True
        assert device.is_default is False

    def test_device_info_defaults(self):
        """Test AudioDeviceInfo default values."""
        device = AudioDeviceInfo(
            index=1,
            name="Microphone",
            channels=1,
            sample_rate=16000
        )

        assert device.is_loopback is False
        assert device.is_default is False


class TestCaptureStatus:
    """Tests for CaptureStatus enum."""

    def test_capture_status_values(self):
        """Test that all expected status values exist."""
        assert CaptureStatus.IDLE.value == "idle"
        assert CaptureStatus.INITIALIZING.value == "initializing"
        assert CaptureStatus.CAPTURING.value == "capturing"
        assert CaptureStatus.PAUSED.value == "paused"
        assert CaptureStatus.ERROR.value == "error"
        assert CaptureStatus.STOPPED.value == "stopped"


class TestAudioBackendDetection:
    """Tests for audio backend detection."""

    def test_backend_is_set(self):
        """Test that AUDIO_BACKEND is properly set."""
        # Backend should be one of the expected values
        assert AUDIO_BACKEND in ["pyaudiowpatch", "screencapturekit"]
