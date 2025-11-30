#!/usr/bin/env python3
"""
Test microphone capture - captures mic audio and saves to WAV file.
Speak during the capture, then play back the WAV to verify.
"""
import asyncio
import sys
import wave
import numpy as np

sys.path.insert(0, 'backend')

from app.services.audio_capture_macos import ScreenCaptureKitAudioCapture

CAPTURE_DURATION = 10  # seconds
OUTPUT_FILE = "test_mic_audio.wav"
SAMPLE_RATE = 16000


async def test_mic_audio():
    print("=" * 60)
    print("MICROPHONE AUDIO CAPTURE TEST")
    print("=" * 60)
    print(f"\nThis will capture {CAPTURE_DURATION} seconds of MICROPHONE audio.")
    print("Please speak during the capture.\n")

    input("Press ENTER to start capturing microphone audio...")

    sck = ScreenCaptureKitAudioCapture(sample_rate=SAMPLE_RATE)
    all_audio = []
    chunks_received = 0

    print(f"\nCapturing for {CAPTURE_DURATION} seconds...")
    print("Speak now!\n")

    start_time = asyncio.get_event_loop().time()

    try:
        async for chunk in sck.capture_audio(capture_system=False, capture_mic=True):
            elapsed = asyncio.get_event_loop().time() - start_time

            # Collect audio data
            all_audio.append(chunk.data)
            chunks_received += 1

            # Show progress
            print(f"  [{elapsed:.1f}s] Chunk {chunks_received}: "
                  f"level={chunk.audio_level:.4f}, "
                  f"samples={len(chunk.data)}, "
                  f"dtype={chunk.data.dtype}, "
                  f"range=[{chunk.data.min():.3f}, {chunk.data.max():.3f}]")

            if elapsed >= CAPTURE_DURATION:
                break

    except Exception as e:
        print(f"Error during capture: {e}")
        import traceback
        traceback.print_exc()
    finally:
        await sck.stop_capture()

    print(f"\nCapture complete! Received {chunks_received} chunks.")

    if all_audio:
        # Combine all audio chunks
        combined = np.concatenate(all_audio)
        print(f"Total samples: {len(combined)}")
        print(f"Duration: {len(combined) / SAMPLE_RATE:.2f} seconds")
        print(f"Audio range: [{combined.min():.4f}, {combined.max():.4f}]")

        # Check if audio looks valid (float32 should be in [-1, 1] range)
        if np.abs(combined).max() > 2.0:
            print("\nWARNING: Audio values outside expected range!")
            print("This may indicate a format detection issue.")
        elif np.abs(combined).max() < 0.001:
            print("\nWARNING: Audio appears to be silent or very quiet.")
        else:
            print("\nAudio values look normal (within [-1, 1] range).")

        # Save to WAV file
        # Convert float32 [-1, 1] to int16
        audio_int16 = (combined * 32767).astype(np.int16)

        with wave.open(OUTPUT_FILE, 'wb') as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)  # 16-bit
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(audio_int16.tobytes())

        print(f"\nSaved to: {OUTPUT_FILE}")
        print(f"Play it with: afplay {OUTPUT_FILE}")
        print("\nIf the playback sounds correct, the mic capture is working!")
        print("If it sounds garbled/corrupted, there's still a format issue.")
    else:
        print("No audio captured!")


if __name__ == "__main__":
    asyncio.run(test_mic_audio())
