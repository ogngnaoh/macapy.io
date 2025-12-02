"""
Dual Audio Capture Verification Script

This script tests the dual audio capture capability (System + Microphone).
It will:
1. Auto-select the default system loopback device.
2. Auto-select the default microphone.
3. Capture and mix audio for 10 seconds.
4. Save the result to 'dual_capture_test.wav'.

Usage:
    python backend/tests/verify_dual_capture.py
"""

import asyncio
import sys
import wave
import logging
from pathlib import Path
import numpy as np

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Add backend directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from app.services.audio_capture import AudioCaptureService

async def main():
    print("=" * 60)
    print("Dual Audio Capture Verification")
    print("=" * 60)

    capture = AudioCaptureService()
    
    print("\n1. Listing devices...")
    devices = await capture.list_audio_devices()
    for d in devices:
        print(f"  [{d.index}] {d.name} ({d.channels}ch, {d.sample_rate}Hz) {'[Loopback]' if d.is_loopback else ''}")

    print("\n2. Starting capture (10 seconds)...")
    print("   Please play some audio on your system AND speak into your microphone.")
    
    captured_chunks = []
    max_chunks = 10
    
    try:
        chunk_count = 0
        # Auto-select both
        async for chunk in capture.capture_audio(auto_select_loopback=True, auto_select_mic=True):
            chunk_count += 1
            
            # Visual feedback
            level_bar = "█" * int(chunk.audio_level * 40)
            print(f"   Chunk {chunk_count}/{max_chunks} | Level: {chunk.audio_level*100:5.1f}% | {level_bar}", end="\r")
            
            captured_chunks.append(chunk.data)
            
            if chunk_count >= max_chunks:
                break
                
        print("\n\n3. Capture complete.")
        
        # Save to WAV
        output_file = Path(__file__).parent / "dual_capture_test.wav"
        audio_data = np.concatenate(captured_chunks)
        audio_data_int16 = (audio_data * 32767).astype(np.int16)
        
        with wave.open(str(output_file), 'wb') as wav_file:
            wav_file.setnchannels(capture.channels)
            wav_file.setsampwidth(2)
            wav_file.setframerate(capture.sample_rate)
            wav_file.writeframes(audio_data_int16.tobytes())
            
        print(f"4. Saved to: {output_file}")
        print("   Please play this file to verify you can hear BOTH system audio and your voice.")
        
    except Exception as e:
        print(f"\nERROR: {e}")
        import traceback
        traceback.print_exc()
    finally:
        await capture.stop_capture()

if __name__ == "__main__":
    asyncio.run(main())
