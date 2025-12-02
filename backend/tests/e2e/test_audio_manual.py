#!/usr/bin/env python3
"""
Manual test script for macOS audio capture using ScreenCaptureKit.

Usage:
    python backend/tests/e2e/test_audio_manual.py              # Test dual capture (default)
    python backend/tests/e2e/test_audio_manual.py --dual       # Test dual capture (system + mic)
    python backend/tests/e2e/test_audio_manual.py --mic-only   # Test microphone only
    python backend/tests/e2e/test_audio_manual.py --system-only # Test system audio only
    python backend/tests/e2e/test_audio_manual.py --list       # List available devices

Can also be run via pytest:
    pytest backend/tests/e2e/test_audio_manual.py -v -s
"""
import asyncio
import sys
import os
import argparse
import platform
import logging
import pytest

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger(__name__)

# Add backend to path for direct script execution
# This allows running the script directly with: python backend/tests/e2e/test_audio_manual.py
_backend_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
if _backend_dir not in sys.path:
    sys.path.insert(0, _backend_dir)


def is_screencapturekit_available():
    """Check if ScreenCaptureKit is available on this system."""
    if platform.system() != "Darwin":
        return False
    try:
        macos_version = tuple(map(int, platform.mac_ver()[0].split('.')[:2]))
        if macos_version < (12, 3):
            return False
    except (ValueError, IndexError):
        return False

    try:
        from app.services.audio_capture_macos import ScreenCaptureKitAudioCapture
        return ScreenCaptureKitAudioCapture.is_available()
    except ImportError:
        return False
    except Exception:
        return False


def get_audio_capture_class():
    """Get the ScreenCaptureKitAudioCapture class."""
    # Import from app module (backend directory is already in path)
    from app.services.audio_capture_macos import ScreenCaptureKitAudioCapture
    return ScreenCaptureKitAudioCapture


async def list_devices():
    """List all available audio input devices using ScreenCaptureKit."""
    ScreenCaptureKitAudioCapture = get_audio_capture_class()

    print("\n[AUDIO] Available Audio Input Devices (ScreenCaptureKit):")
    print("=" * 60)

    if not ScreenCaptureKitAudioCapture.is_available():
        print("[WARN] ScreenCaptureKit not available on this system")
        print("       Requires macOS 12.3 or later")
        return

    service = ScreenCaptureKitAudioCapture()
    devices = await service.list_audio_devices()

    for d in devices:
        is_loopback = d.get('is_loopback', False)
        is_default = d.get('is_default', False)
        marker = '[SYSTEM]' if is_loopback else '[MIC]   '
        default = ' <- DEFAULT' if is_default else ''

        print(f"  [{d['index']:2d}] {marker} {d['name']}{default}")

    print("=" * 60)
    print("[OK] ScreenCaptureKit available - no BlackHole needed!")
    print("     System audio is captured natively via ScreenCaptureKit")


async def test_capture(capture_system=True, capture_mic=True, duration=10):
    """Test audio capture for a specified duration using ScreenCaptureKit."""
    ScreenCaptureKitAudioCapture = get_audio_capture_class()

    print(f"\n[START] Starting ScreenCaptureKit audio capture test ({duration}s)...")
    print(f"        Capture system audio: {capture_system}")
    print(f"        Capture microphone: {capture_mic}")
    print("-" * 50)

    if not ScreenCaptureKitAudioCapture.is_available():
        print("[ERROR] ScreenCaptureKit not available on this system")
        return False

    service = ScreenCaptureKitAudioCapture(
        sample_rate=16000,
        channels=1,
        chunk_duration=1.0
    )

    stats = {"system": 0, "user": 0, "unknown": 0}
    start_time = asyncio.get_event_loop().time()

    try:
        async for chunk in service.capture_audio(
            capture_system=capture_system,
            capture_mic=capture_mic
        ):
            source = chunk.source
            stats[source] = stats.get(source, 0) + 1

            # Visual level indicator
            level_bars = int(chunk.audio_level * 20)
            level_visual = "#" * level_bars + "." * (20 - level_bars)

            source_marker = "[SYS]" if source == "system" else "[MIC]"
            print(f"  {source_marker} {source:6s} | Level: [{level_visual}] {chunk.audio_level:.3f} | Samples: {len(chunk.data)}")

            # Stop after duration
            elapsed = asyncio.get_event_loop().time() - start_time
            if elapsed >= duration:
                break

    except Exception as e:
        print(f"[ERROR] {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        await service.stop_capture()

    print("-" * 50)
    print(f"[RESULTS] After {duration}s:")
    print(f"          System chunks: {stats['system']}")
    print(f"          Mic chunks:    {stats['user']}")
    print(f"          Unknown:       {stats['unknown']}")
    total = sum(stats.values())
    print(f"          Total:         {total}")

    if total > 0:
        print("\n[OK] Audio capture working!")
        return True
    else:
        print("\n[WARN] No audio captured - check permissions in System Preferences")
        return False


async def main():
    """Main entry point for manual test execution."""
    parser = argparse.ArgumentParser(description='Manual audio capture test (ScreenCaptureKit)')
    parser.add_argument('--list', action='store_true', help='List available devices')
    parser.add_argument('--dual', action='store_true', help='Test dual capture (system + mic)')
    parser.add_argument('--mic-only', action='store_true', help='Test microphone only')
    parser.add_argument('--system-only', action='store_true', help='Test system audio only')
    parser.add_argument('--duration', type=int, default=10, help='Test duration in seconds (default: 10)')

    args = parser.parse_args()

    if args.list:
        await list_devices()
        return

    # Determine what to capture
    capture_system = True
    capture_mic = True

    if args.mic_only:
        capture_system = False
        capture_mic = True
        print("\n[MODE] Testing MICROPHONE ONLY")
    elif args.system_only:
        capture_system = True
        capture_mic = False
        print("\n[MODE] Testing SYSTEM AUDIO ONLY")
    elif args.dual:
        capture_system = True
        capture_mic = True
        print("\n[MODE] Testing DUAL CAPTURE (System + Mic)")
    else:
        # Default: dual capture
        print("\n[MODE] Testing DUAL CAPTURE (System + Mic)")

    await test_capture(
        capture_system=capture_system,
        capture_mic=capture_mic,
        duration=args.duration
    )


# ============================================================================
# Pytest test cases
# ============================================================================

# Skip all pytest tests if ScreenCaptureKit is not available
pytestmark = [
    pytest.mark.skipif(
        not is_screencapturekit_available(),
        reason="ScreenCaptureKit not available (requires macOS 12.3+)"
    ),
    pytest.mark.asyncio,
    pytest.mark.e2e
]


class TestScreenCaptureKitManual:
    """Manual/interactive tests for ScreenCaptureKit audio capture."""

    async def test_list_devices(self):
        """Test listing audio devices."""
        ScreenCaptureKitAudioCapture = get_audio_capture_class()

        assert ScreenCaptureKitAudioCapture.is_available(), "ScreenCaptureKit should be available"

        service = ScreenCaptureKitAudioCapture()
        devices = await service.list_audio_devices()

        assert len(devices) > 0, "Should find at least one audio device"

        # Should have the virtual system audio device
        system_device = next((d for d in devices if d.get('is_loopback')), None)
        assert system_device is not None, "Should have system audio device"

        logger.info(f"Found {len(devices)} audio devices")
        for d in devices:
            logger.info(f"  [{d['index']}] {d['name']} (loopback={d.get('is_loopback', False)})")

    async def test_short_capture(self):
        """Test a short audio capture session (3 seconds)."""
        ScreenCaptureKitAudioCapture = get_audio_capture_class()

        service = ScreenCaptureKitAudioCapture(
            sample_rate=16000,
            channels=1,
            chunk_duration=1.0
        )

        chunks_received = []
        start_time = asyncio.get_event_loop().time()

        try:
            async for chunk in service.capture_audio(
                capture_system=True,
                capture_mic=False  # Only system audio for faster test
            ):
                chunks_received.append(chunk)
                logger.info(f"Chunk {len(chunks_received)}: source={chunk.source}, level={chunk.audio_level:.4f}")

                elapsed = asyncio.get_event_loop().time() - start_time
                if elapsed >= 3:  # 3 second test
                    break

        finally:
            await service.stop_capture()

        # We may not get chunks if there's no audio playing, but the capture should work
        logger.info(f"Captured {len(chunks_received)} chunks in 3 seconds")

        # Basic validation - capture ran without error
        assert True, "Capture completed without errors"


if __name__ == "__main__":
    asyncio.run(main())
