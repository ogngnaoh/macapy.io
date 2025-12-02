"""
Integration tests for ScreenCaptureKit audio capture on macOS.

These tests require real macOS hardware with ScreenCaptureKit support (macOS 12.3+).
They are skipped automatically in CI environments or on non-macOS systems.

Run manually with:
    pytest backend/tests/integration/test_screencapturekit.py -v -s
"""
import pytest
import pytest_asyncio
import asyncio
import logging
import platform

logger = logging.getLogger(__name__)

SYSTEM = platform.system()
MACOS_VERSION = tuple(map(int, platform.mac_ver()[0].split('.')[:2])) if SYSTEM == "Darwin" else (0, 0)


def is_screencapturekit_available():
    """Check if ScreenCaptureKit is available."""
    if SYSTEM != "Darwin":
        return False
    if MACOS_VERSION < (12, 3):
        return False
    try:
        from app.services.audio_capture_macos import ScreenCaptureKitAudioCapture
        return ScreenCaptureKitAudioCapture.is_available()
    except ImportError:
        return False


# Skip all tests in this module if ScreenCaptureKit is not available
pytestmark = [
    pytest.mark.skipif(
        not is_screencapturekit_available(),
        reason="ScreenCaptureKit not available - requires macOS 12.3+ with Screen Recording permission"
    ),
    pytest.mark.asyncio
]


@pytest_asyncio.fixture
async def sck_service():
    """Create a ScreenCaptureKitAudioCapture service."""
    from app.services.audio_capture_macos import ScreenCaptureKitAudioCapture
    service = ScreenCaptureKitAudioCapture(
        sample_rate=16000,
        channels=1,
        chunk_duration=1.0
    )
    yield service
    await service.stop_capture()


class TestScreenCaptureKitAvailability:
    """Tests for ScreenCaptureKit availability checking."""

    async def test_is_available(self, sck_service):
        """Test that is_available() returns True on supported systems."""
        from app.services.audio_capture_macos import ScreenCaptureKitAudioCapture
        assert ScreenCaptureKitAudioCapture.is_available() is True

    async def test_macos_version_check(self):
        """Test that macOS version is correctly detected."""
        assert MACOS_VERSION >= (12, 3), f"Expected macOS 12.3+, got {MACOS_VERSION}"


class TestDeviceListing:
    """Tests for audio device listing."""

    async def test_list_audio_devices(self, sck_service):
        """Test that devices can be listed."""
        devices = await sck_service.list_audio_devices()

        assert isinstance(devices, list)
        assert len(devices) > 0, "Should have at least one audio device"

        # Log devices for debugging
        for d in devices:
            logger.info(f"Device: {d}")

    async def test_system_audio_device_present(self, sck_service):
        """Test that system audio device is present in list."""
        devices = await sck_service.list_audio_devices()

        # Find system audio (loopback) device
        system_audio = next((d for d in devices if d.get("is_loopback")), None)

        assert system_audio is not None, "System audio device should be present"
        assert "System Audio" in system_audio.get("name", "") or system_audio.get("is_loopback")

    async def test_device_structure(self, sck_service):
        """Test that devices have expected structure."""
        devices = await sck_service.list_audio_devices()

        for device in devices:
            assert "index" in device
            assert "name" in device
            assert "is_loopback" in device
            assert "is_default" in device


class TestSystemAudioCapture:
    """Tests for system audio capture via ScreenCaptureKit."""

    async def test_capture_system_audio_only(self, sck_service):
        """Test capturing system audio only (no microphone)."""
        chunks_captured = 0

        try:
            async for chunk in sck_service.capture_audio(
                capture_system=True,
                capture_mic=False
            ):
                chunks_captured += 1
                logger.info(f"System chunk {chunks_captured}: level={chunk.audio_level:.4f}")

                assert chunk.source == "system"
                assert chunk.sample_rate == 16000
                assert chunk.channels == 1
                assert 0.0 <= chunk.audio_level <= 1.0

                if chunks_captured >= 3:
                    break
        except Exception as e:
            pytest.fail(f"System audio capture failed: {e}")

        assert chunks_captured >= 1, "Should capture at least one system audio chunk"


class TestMicrophoneCapture:
    """Tests for microphone capture."""

    async def test_capture_mic_only(self, sck_service):
        """Test capturing microphone audio only (no system audio)."""
        chunks_captured = 0

        try:
            async for chunk in sck_service.capture_audio(
                capture_system=False,
                capture_mic=True
            ):
                chunks_captured += 1
                logger.info(f"Mic chunk {chunks_captured}: level={chunk.audio_level:.4f}")

                assert chunk.source == "user"
                assert chunk.sample_rate == 16000
                assert chunk.channels == 1
                assert 0.0 <= chunk.audio_level <= 1.0

                if chunks_captured >= 3:
                    break
        except Exception as e:
            pytest.fail(f"Microphone capture failed: {e}")

        assert chunks_captured >= 1, "Should capture at least one mic audio chunk"


class TestDualCapture:
    """Tests for simultaneous system and microphone capture."""

    async def test_capture_both_sources(self, sck_service):
        """Test capturing both system audio and microphone."""
        system_chunks = 0
        user_chunks = 0
        total_chunks = 0

        try:
            async for chunk in sck_service.capture_audio(
                capture_system=True,
                capture_mic=True
            ):
                total_chunks += 1
                if chunk.source == "system":
                    system_chunks += 1
                elif chunk.source == "user":
                    user_chunks += 1

                logger.info(
                    f"Chunk {total_chunks}: source={chunk.source}, level={chunk.audio_level:.4f}"
                )

                if total_chunks >= 6:
                    break
        except Exception as e:
            pytest.fail(f"Dual capture failed: {e}")

        logger.info(f"Captured: system={system_chunks}, user={user_chunks}, total={total_chunks}")

        # We should get chunks from at least one source
        assert total_chunks >= 1, "Should capture at least one chunk"


class TestAudioData:
    """Tests for audio data quality and format."""

    async def test_audio_chunk_format(self, sck_service):
        """Test that audio chunks have correct format."""
        import numpy as np

        async for chunk in sck_service.capture_audio(
            capture_system=True,
            capture_mic=False
        ):
            # Check data type
            assert isinstance(chunk.data, np.ndarray)
            assert chunk.data.dtype in [np.float32, np.float64, np.int16]

            # Check metadata
            assert isinstance(chunk.timestamp, float)
            assert chunk.timestamp > 0
            assert chunk.duration > 0
            assert chunk.sample_rate == 16000

            break  # Only check first chunk

    async def test_audio_level_calculation(self, sck_service):
        """Test that audio levels are calculated correctly."""
        async for chunk in sck_service.capture_audio(
            capture_system=True,
            capture_mic=True
        ):
            # Level should be between 0 and 1
            assert 0.0 <= chunk.audio_level <= 1.0

            # If there's audio data, verify level matches RMS
            if len(chunk.data) > 0:
                import numpy as np
                expected_rms = np.sqrt(np.mean(chunk.data.astype(np.float32) ** 2))
                expected_level = min(1.0, max(0.0, expected_rms))

                # Allow some tolerance for different calculation methods
                assert abs(chunk.audio_level - expected_level) < 0.1

            break


class TestStopCapture:
    """Tests for stopping audio capture."""

    async def test_stop_capture(self, sck_service):
        """Test that capture can be stopped cleanly."""
        chunks = 0

        async for chunk in sck_service.capture_audio(
            capture_system=True,
            capture_mic=False
        ):
            chunks += 1
            if chunks >= 2:
                break

        # Stop should complete without error
        await sck_service.stop_capture()

        # Verify service is stopped
        assert sck_service._is_capturing is False

    async def test_stop_capture_idempotent(self, sck_service):
        """Test that stop_capture can be called multiple times."""
        await sck_service.stop_capture()
        await sck_service.stop_capture()  # Should not raise


class TestErrorHandling:
    """Tests for error handling."""

    async def test_no_sources_raises_error(self, sck_service):
        """Test that capturing with no sources raises an error."""
        with pytest.raises(ValueError, match="(?i)at least one audio source"):
            async for _ in sck_service.capture_audio(
                capture_system=False,
                capture_mic=False
            ):
                pass
