#!/usr/bin/env python3
"""
Isolated audio capture test for debugging.
Tests ScreenCaptureKit audio capture on macOS independently of the meeting service.
"""
import asyncio
import sys
import os

# Add project to path
project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, project_root)


async def test_audio():
    print("=" * 60)
    print("Audio Capture Debug Test")
    print("=" * 60)

    # Test 1: Check macOS version
    import platform
    mac_ver = platform.mac_ver()[0]
    print(f"\n[1] macOS Version: {mac_ver}")

    # Test 2: Check ScreenCaptureKit availability
    try:
        from backend.app.services.audio_capture_macos import (
            MACOS_VERSION, SCREENCAPTUREKIT_AVAILABLE, PYOBJC_AVAILABLE
        )
        print(f"\n[2] ScreenCaptureKit Check:")
        print(f"    - macOS version tuple: {MACOS_VERSION}")
        print(f"    - SCK available: {SCREENCAPTUREKIT_AVAILABLE}")
        print(f"    - PyObjC available: {PYOBJC_AVAILABLE}")

        if not PYOBJC_AVAILABLE:
            print("\n❌ PyObjC not available! Check dependencies.")
            print("   Run: pip install pyobjc-framework-ScreenCaptureKit pyobjc-framework-AVFoundation")
            return
    except ImportError as e:
        print(f"\n❌ Import error: {e}")
        return

    # Test 3: List audio devices
    from backend.app.services.audio_capture import AudioCaptureService
    service = AudioCaptureService()

    print(f"\n[3] Audio Devices:")
    devices = await service.list_audio_devices()
    for d in devices:
        marker = "🔊" if d.is_loopback else "🎤"
        default = " (DEFAULT)" if d.is_default else ""
        print(f"    {marker} [{d.index}] {d.name}{default}")

    if not devices:
        print("    ❌ No audio devices found!")
        return

    # Test 4: Attempt capture
    print(f"\n[4] Attempting Audio Capture (10 seconds)...")
    print("    Play some audio on your Mac to test system capture.")
    print("    Speak to test microphone capture.")
    print("-" * 60)

    chunk_count = {"system": 0, "user": 0, "unknown": 0}
    max_level = {"system": 0.0, "user": 0.0, "unknown": 0.0}

    try:
        async for chunk in service.capture_audio():
            source = chunk.source if chunk.source in chunk_count else "unknown"
            chunk_count[source] += 1
            max_level[source] = max(max_level[source], chunk.audio_level)

            # Visual feedback
            level_bar = "█" * int(chunk.audio_level * 20)
            print(f"    {source:6s} | Level: {chunk.audio_level:.4f} {level_bar}")

            # Stop after collecting enough chunks (approx 10 seconds)
            total = chunk_count["system"] + chunk_count["user"]
            if total >= 20:  # 10 chunks each (1s per chunk)
                break

    except Exception as e:
        print(f"\n❌ Capture Error: {e}")
        import traceback
        traceback.print_exc()
        return
    finally:
        await service.stop_capture()

    # Summary
    print("\n" + "=" * 60)
    print("Summary:")
    print(f"  System Audio Chunks: {chunk_count['system']} (max level: {max_level['system']:.4f})")
    print(f"  Microphone Chunks:   {chunk_count['user']} (max level: {max_level['user']:.4f})")

    if chunk_count["system"] == 0 and chunk_count["user"] == 0:
        print("\n❌ NO AUDIO CAPTURED!")
        print("   Possible issues:")
        print("   - Screen Recording permission not granted")
        print("   - Terminal/Python not restarted after granting permission")
        print("   - PyObjC frameworks not properly installed")
        print("\n   To fix:")
        print("   1. Open System Preferences > Privacy & Security > Screen Recording")
        print("   2. Add Terminal.app (or your terminal)")
        print("   3. RESTART the terminal completely")
        print("   4. Run this script again")
    elif max_level["system"] < 0.001 and max_level["user"] < 0.001:
        print("\n⚠️ Audio captured but levels are very low (silence)")
        print("   - Try playing louder audio")
        print("   - Check system volume")
    else:
        print("\n✅ Audio capture working!")


if __name__ == "__main__":
    asyncio.run(test_audio())
