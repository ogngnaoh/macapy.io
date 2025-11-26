"""
Audio Capture Service for macapy.io

Captures system audio from virtual audio devices (VB-CABLE on Windows)
and provides real-time audio chunks for transcription.

Architecture:
- Async audio capture using pyaudiowpatch (Windows) or sounddevice (cross-platform)
- Buffers audio into configurable chunks (default: 1 second)
- Monitors audio levels for UI feedback
- Handles device errors and reconnection

Usage:
    capture = AudioCaptureService()
    devices = await capture.list_audio_devices()

    async for chunk in capture.capture_audio(device_index=1):
        # chunk is a numpy array of audio data
        audio_level = capture.get_audio_level()
        # Send chunk to Whisper API
"""

import asyncio
import logging
import platform
import struct
from typing import AsyncGenerator, Optional, Dict, List
from dataclasses import dataclass
from enum import Enum

import numpy as np
from scipy import signal

# Import platform-specific audio library
SYSTEM = platform.system()
if SYSTEM == "Windows":
    try:
        import pyaudiowpatch as pyaudio
        AUDIO_BACKEND = "pyaudiowpatch"
    except ImportError:
        import sounddevice as sd
        AUDIO_BACKEND = "sounddevice"
else:
    import sounddevice as sd
    AUDIO_BACKEND = "sounddevice"

from app.config import settings

logger = logging.getLogger(__name__)


class CaptureStatus(Enum):
    """Audio capture status states"""
    IDLE = "idle"
    INITIALIZING = "initializing"
    CAPTURING = "capturing"
    PAUSED = "paused"
    ERROR = "error"
    STOPPED = "stopped"


@dataclass
class AudioDeviceInfo:
    """Information about an audio device"""
    index: int
    name: str
    channels: int
    sample_rate: int
    is_loopback: bool = False  # True for virtual audio devices
    is_default: bool = False


@dataclass
class AudioChunk:
    """Container for audio data chunk"""
    data: np.ndarray  # Audio samples as numpy array
    timestamp: float  # Unix timestamp when captured
    duration: float  # Duration in seconds
    sample_rate: int  # Sample rate (Hz)
    channels: int  # Number of channels
    audio_level: float  # RMS audio level (0.0 to 1.0)


class AudioCaptureService:
    """
    Service for capturing system audio from virtual audio devices.

    This service handles:
    - Device detection and selection
    - Real-time audio capture
    - Audio buffering and chunking
    - Audio level monitoring
    - Error handling and recovery

    Thread-safe and async-compatible.
    """

    def __init__(
        self,
        sample_rate: int = settings.AUDIO_SAMPLE_RATE,
        channels: int = settings.AUDIO_CHANNELS,
        chunk_duration: float = settings.AUDIO_CHUNK_DURATION,
    ):
        """
        Initialize audio capture service.

        Args:
            sample_rate: Audio sample rate in Hz (default: 16000 for Whisper)
            channels: Number of audio channels (1=mono, 2=stereo)
            chunk_duration: Duration of each audio chunk in seconds
        """
        self.sample_rate = sample_rate  # Target sample rate (16kHz for Whisper)
        self.channels = channels
        self.chunk_duration = chunk_duration
        self.chunk_size = int(sample_rate * chunk_duration)  # Samples per chunk

        # Audio processing state
        self.status = CaptureStatus.IDLE
        self.current_device: Optional[AudioDeviceInfo] = None
        self.current_audio_level: float = 0.0
        self.total_chunks_captured: int = 0

        # Device properties (will be set when capturing)
        self._device_sample_rate: Optional[int] = None  # Native device sample rate
        self._device_channels: Optional[int] = None  # Native device channels

        # For pyaudio backend
        self._pyaudio_instance: Optional[pyaudio.PyAudio] = None
        self._stream = None

        # Audio buffer (thread-safe queue)
        self._buffer = asyncio.Queue(maxsize=10)  # Buffer up to 10 chunks
        self._mic_buffer = asyncio.Queue(maxsize=10)  # Buffer for microphone audio

        logger.info(
            f"AudioCaptureService initialized with backend: {AUDIO_BACKEND}, "
            f"target_sample_rate={sample_rate}Hz, channels={channels}, "
            f"chunk_duration={chunk_duration}s"
        )

    async def list_audio_devices(self) -> List[AudioDeviceInfo]:
        """
        List all available audio input devices.

        Returns:
            List of AudioDeviceInfo objects with device information

        Note:
            On Windows with pyaudiowpatch, WASAPI loopback devices allow capturing
            audio directly from output devices without VB-CABLE.
        """
        devices = []

        if AUDIO_BACKEND == "pyaudiowpatch":
            # Use pyaudiowpatch for Windows
            if self._pyaudio_instance is None:
                self._pyaudio_instance = pyaudio.PyAudio()

            default_loopback_index = None
            default_wasapi_info = None

            try:
                # Get default WASAPI loopback device (captures from default output)
                default_wasapi_info = self._pyaudio_instance.get_default_wasapi_loopback()
                if default_wasapi_info:
                    default_loopback_index = default_wasapi_info['index']
                    logger.info(f"Default WASAPI loopback: [{default_loopback_index}] {default_wasapi_info['name']}")
            except (OSError, AttributeError) as e:
                logger.warning(f"Could not get default WASAPI loopback: {e}")

            device_count = self._pyaudio_instance.get_device_count()
            found_default_loopback = False

            for i in range(device_count):
                try:
                    info = self._pyaudio_instance.get_device_info_by_index(i)

                    # Only include input devices
                    if info['maxInputChannels'] > 0:
                        # Check if this is a loopback device
                        # WASAPI loopback devices have "loopback" in name (added by pyaudiowpatch)
                        is_loopback = (
                            'loopback' in info['name'].lower() or
                            'cable' in info['name'].lower() or
                            'stereo mix' in info['name'].lower()
                        )

                        is_default = (i == default_loopback_index)
                        if is_default:
                            found_default_loopback = True

                        device = AudioDeviceInfo(
                            index=i,
                            name=info['name'],
                            channels=info['maxInputChannels'],
                            sample_rate=int(info['defaultSampleRate']),
                            is_loopback=is_loopback,
                            is_default=is_default
                        )
                        devices.append(device)

                except Exception as e:
                    logger.warning(f"Could not get info for device {i}: {e}")

            # If default WASAPI loopback wasn't found in the list, add it explicitly
            if default_wasapi_info and not found_default_loopback:
                logger.info(f"Adding default WASAPI loopback device explicitly: {default_wasapi_info['name']}")
                device = AudioDeviceInfo(
                    index=default_wasapi_info['index'],
                    name=default_wasapi_info['name'],
                    channels=default_wasapi_info['maxInputChannels'],
                    sample_rate=int(default_wasapi_info['defaultSampleRate']),
                    is_loopback=True,
                    is_default=True
                )
                devices.append(device)

        else:
            # Use sounddevice for macOS/Linux
            sd_devices = sd.query_devices()

            for i, device_info in enumerate(sd_devices):
                if device_info['max_input_channels'] > 0:
                    # Check if this is a loopback/virtual device
                    is_loopback = (
                        'blackhole' in device_info['name'].lower() or
                        'loopback' in device_info['name'].lower()
                    )

                    device = AudioDeviceInfo(
                        index=i,
                        name=device_info['name'],
                        channels=device_info['max_input_channels'],
                        sample_rate=int(device_info['default_samplerate']),
                        is_loopback=is_loopback,
                        is_default=(i == sd.default.device[0])
                    )
                    devices.append(device)

        logger.info(f"Found {len(devices)} audio input devices")

        # Log virtual audio devices (important for setup verification)
        loopback_devices = [d for d in devices if d.is_loopback]
        if loopback_devices:
            logger.info(f"Found {len(loopback_devices)} virtual audio device(s): "
                       f"{[d.name for d in loopback_devices]}")
        else:
            logger.warning(
                "No virtual audio devices found! Please install VB-CABLE (Windows) "
                "or BlackHole (macOS) to capture system audio."
            )

        return devices

    async def capture_audio(
        self,
        device_index: Optional[int] = None,
        mic_device_index: Optional[int] = None,
        auto_select_loopback: bool = True,
        auto_select_mic: bool = True
    ) -> AsyncGenerator[AudioChunk, None]:
        """
        Capture audio from the specified device and yield audio chunks.

        This is an async generator that continuously yields audio chunks
        until stopped or an error occurs.

        Args:
            device_index: Index of audio device to use (None = auto-select)
            auto_select_loopback: If True, automatically select virtual audio device

        Yields:
            AudioChunk objects containing audio data and metadata

        Example:
            async for chunk in capture.capture_audio(device_index=1):
                # Process chunk (send to Whisper API)
                logger.info(f"Captured {chunk.duration}s at level {chunk.audio_level}")
        """
        try:
            # Select system device (loopback)
            if device_index is None and auto_select_loopback:
                device_index = await self._auto_select_loopback_device()

            if device_index is None:
                logger.warning("No system audio device selected. Capturing only microphone (if available).")

            # Select microphone device
            if mic_device_index is None and auto_select_mic:
                mic_device_index = await self._auto_select_mic_device()

            if mic_device_index is None:
                logger.info("No microphone device selected. Capturing only system audio.")

            if device_index is None and mic_device_index is None:
                raise ValueError("No audio devices found or selected (neither system nor mic)")

            # Get device info
            devices = await self.list_audio_devices()
            self.current_device = next((d for d in devices if d.index == device_index), None)
            mic_device = next((d for d in devices if d.index == mic_device_index), None)

            log_msg = "Starting audio capture from: "
            if self.current_device:
                log_msg += f"System=[{self.current_device.name}] "
            if mic_device:
                log_msg += f"Mic=[{mic_device.name}]"
            logger.info(log_msg)

            self.status = CaptureStatus.INITIALIZING

            # Start capture based on backend
            if AUDIO_BACKEND == "pyaudiowpatch":
                async for chunk in self._capture_with_pyaudio_dual(device_index, mic_device_index):
                    yield chunk
            else:
                # Fallback for non-Windows (sounddevice) - currently only supports single stream or simple mixing
                # For now, we'll just use the primary device if available, or mic if not
                target_idx = device_index if device_index is not None else mic_device_index
                async for chunk in self._capture_with_sounddevice(target_idx):
                    yield chunk

        except Exception as e:
            logger.error(f"Audio capture error: {e}", exc_info=True)
            self.status = CaptureStatus.ERROR
            raise
        finally:
            await self.stop_capture()

    async def _auto_select_mic_device(self) -> Optional[int]:
        """
        Automatically select the default microphone.
        """
        if AUDIO_BACKEND == "pyaudiowpatch":
            if self._pyaudio_instance is None:
                self._pyaudio_instance = pyaudio.PyAudio()
            try:
                default_input = self._pyaudio_instance.get_default_input_device_info()
                if default_input:
                    logger.info(f"Auto-selected default microphone: {default_input['name']}")
                    return default_input['index']
            except (OSError, AttributeError) as e:
                logger.warning(f"Could not get default microphone: {e}")

        # Fallback: search through device list for a non-loopback input
        devices = await self.list_audio_devices()
        # Prefer default non-loopback
        default_mic = next(
            (d for d in devices if not d.is_loopback and d.is_default),
            None
        )
        if default_mic:
            return default_mic.index
        
        # Or just the first non-loopback
        first_mic = next((d for d in devices if not d.is_loopback), None)
        if first_mic:
            return first_mic.index
            
        return None

    async def _auto_select_loopback_device(self) -> Optional[int]:
        """
        Automatically select the best loopback/virtual audio device.

        On Windows with pyaudiowpatch, this will select the WASAPI loopback
        device for the default output device, allowing capture of system audio
        without needing VB-CABLE or changing system audio settings.

        Returns:
            Device index or None if no suitable device found
        """
        if AUDIO_BACKEND == "pyaudiowpatch":
            # Use WASAPI loopback to capture from default output device
            if self._pyaudio_instance is None:
                self._pyaudio_instance = pyaudio.PyAudio()

            try:
                # This gets the loopback device for the default OUTPUT device
                # (e.g., your JBL speakers), allowing capture without VB-CABLE
                wasapi_loopback = self._pyaudio_instance.get_default_wasapi_loopback()
                if wasapi_loopback:
                    logger.info(
                        f"Auto-selected WASAPI loopback device: {wasapi_loopback['name']} "
                        f"(captures from default output device)"
                    )
                    return wasapi_loopback['index']
            except (OSError, AttributeError) as e:
                logger.warning(f"Could not get WASAPI loopback device: {e}")

        # Fallback: search through device list
        devices = await self.list_audio_devices()

        # Prefer default loopback device
        default_loopback = next(
            (d for d in devices if d.is_loopback and d.is_default),
            None
        )
        if default_loopback:
            logger.info(f"Auto-selected default loopback device: {default_loopback.name}")
            return default_loopback.index

        # Otherwise, select first loopback device
        first_loopback = next((d for d in devices if d.is_loopback), None)
        if first_loopback:
            logger.info(f"Auto-selected loopback device: {first_loopback.name}")
            return first_loopback.index

        logger.warning("No loopback/virtual audio device found for auto-selection")
        return None

    async def _capture_with_pyaudio_dual(
        self,
        system_device_index: Optional[int],
        mic_device_index: Optional[int]
    ) -> AsyncGenerator[AudioChunk, None]:
        """
        Capture audio from system and/or microphone using pyaudiowpatch.
        Uses independent reader tasks to prevent one stream from blocking the other.
        """
        if self._pyaudio_instance is None:
            self._pyaudio_instance = pyaudio.PyAudio()

        streams = []
        tasks = []
        
        # Queues for audio data
        sys_queue = asyncio.Queue(maxsize=5)
        mic_queue = asyncio.Queue(maxsize=5)
        
        # Stream properties
        sys_rate = sys_channels = 0
        mic_rate = mic_channels = 0
        sys_chunk = mic_chunk = 0

        try:
            loop = asyncio.get_event_loop()
            
            # --- Setup System Stream ---
            if system_device_index is not None:
                sys_info = self._pyaudio_instance.get_device_info_by_index(system_device_index)
                sys_rate = int(sys_info['defaultSampleRate'])
                sys_channels = sys_info['maxInputChannels']
                sys_chunk = int(sys_rate * self.chunk_duration)
                
                system_stream = self._pyaudio_instance.open(
                    format=pyaudio.paInt16,
                    channels=sys_channels,
                    rate=sys_rate,
                    input=True,
                    input_device_index=system_device_index,
                    frames_per_buffer=sys_chunk,
                )
                streams.append(system_stream)
                logger.info(f"System stream opened: {sys_rate}Hz, {sys_channels}ch")
                
                # Start reader task
                tasks.append(asyncio.create_task(
                    self._read_stream_loop(system_stream, sys_chunk, sys_queue, "System")
                ))

            # --- Setup Mic Stream ---
            if mic_device_index is not None:
                mic_info = self._pyaudio_instance.get_device_info_by_index(mic_device_index)
                mic_rate = int(mic_info['defaultSampleRate'])
                mic_channels = mic_info['maxInputChannels']
                mic_chunk = int(mic_rate * self.chunk_duration)

                mic_stream = self._pyaudio_instance.open(
                    format=pyaudio.paInt16,
                    channels=mic_channels,
                    rate=mic_rate,
                    input=True,
                    input_device_index=mic_device_index,
                    frames_per_buffer=mic_chunk,
                )
                streams.append(mic_stream)
                logger.info(f"Mic stream opened: {mic_rate}Hz, {mic_channels}ch")
                
                # Start reader task
                tasks.append(asyncio.create_task(
                    self._read_stream_loop(mic_stream, mic_chunk, mic_queue, "Mic")
                ))

            if not streams:
                raise ValueError("No streams could be opened")

            self.status = CaptureStatus.CAPTURING

            # --- Main Capture Loop ---
            while self.status == CaptureStatus.CAPTURING:
                try:
                    # We need to get audio for the current time slice.
                    # If Mic is available, we use it as the clock (since it's reliable hardware).
                    # If only System is available, we use it (but it might block if silent).
                    
                    mixed_audio = None
                    
                    # Helper to process raw bytes
                    def process_raw(raw, rate, channels):
                        if raw is None: return None
                        data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
                        if channels > 1 and self.channels == 1:
                            data = data.reshape(-1, channels).mean(axis=1)
                        if rate != self.sample_rate:
                            data = self._resample_audio(data, rate, self.sample_rate)
                        return data

                    # 1. Get Mic Audio (Primary Clock)
                    mic_data = None
                    if mic_device_index is not None:
                        try:
                            # Wait for mic data (this drives the timing)
                            raw_mic = await asyncio.wait_for(mic_queue.get(), timeout=2.0)
                            mic_data = process_raw(raw_mic, mic_rate, mic_channels)
                        except asyncio.TimeoutError:
                            logger.warning("Mic stream timeout")
                            # If mic times out, we continue to check system
                    
                    # 2. Get System Audio (Secondary)
                    sys_data = None
                    if system_device_index is not None:
                        try:
                            # Check if system data is available NOW (or very soon)
                            # We don't want to wait long if we already have mic data
                            timeout = 0.1 if mic_data is not None else 2.0
                            raw_sys = await asyncio.wait_for(sys_queue.get(), timeout=timeout)
                            sys_data = process_raw(raw_sys, sys_rate, sys_channels)
                        except asyncio.TimeoutError:
                            # System silent or late - ignore for this chunk
                            pass

                    # 3. Mix
                    if mic_data is not None and sys_data is not None:
                        min_len = min(len(mic_data), len(sys_data))
                        mixed_audio = (mic_data[:min_len] + sys_data[:min_len]) / 2.0
                    elif mic_data is not None:
                        mixed_audio = mic_data
                    elif sys_data is not None:
                        mixed_audio = sys_data
                    
                    if mixed_audio is None or len(mixed_audio) == 0:
                        continue

                    # 4. Yield
                    audio_level = self._calculate_audio_level(mixed_audio)
                    self.current_audio_level = audio_level

                    chunk = AudioChunk(
                        data=mixed_audio,
                        timestamp=loop.time(),
                        duration=self.chunk_duration,
                        sample_rate=self.sample_rate,
                        channels=self.channels,
                        audio_level=audio_level
                    )
                    self.total_chunks_captured += 1
                    yield chunk

                except Exception as e:
                    logger.error(f"Error in capture loop: {e}")
                    break

        finally:
            self.status = CaptureStatus.STOPPED
            # Cancel reader tasks
            for t in tasks:
                t.cancel()
            # Close streams
            for s in streams:
                if s:
                    s.stop_stream()
                    s.close()

    async def _read_stream_loop(self, stream, chunk_size, queue, name):
        """Background task to read from a blocking pyaudio stream."""
        loop = asyncio.get_event_loop()
        while self.status == CaptureStatus.CAPTURING:
            try:
                data = await loop.run_in_executor(None, stream.read, chunk_size, False)
                if self.status != CaptureStatus.CAPTURING: break
                
                # Put in queue, remove old if full to keep latency low
                if queue.full():
                    try: queue.get_nowait()
                    except asyncio.QueueEmpty: pass
                
                await queue.put(data)
            except Exception as e:
                if self.status == CaptureStatus.CAPTURING:
                    logger.warning(f"Stream {name} read error: {e}")
                    await asyncio.sleep(1.0) # Backoff

    async def _capture_with_sounddevice(self, device_index: int) -> AsyncGenerator[AudioChunk, None]:
        """
        Capture audio using sounddevice (macOS/Linux backend).

        Uses callback-based capture with an async queue.
        """
        # Audio callback function
        def audio_callback(indata, frames, time_info, status):
            if status:
                logger.warning(f"Audio callback status: {status}")

            # Copy audio data to avoid buffer reuse issues
            audio_data = indata.copy().flatten()

            # Put in queue (non-blocking)
            try:
                self._buffer.put_nowait(audio_data)
            except asyncio.QueueFull:
                logger.warning("Audio buffer full - dropping chunk")

        # Open audio stream with callback
        stream = sd.InputStream(
            device=device_index,
            channels=self.channels,
            samplerate=self.sample_rate,
            blocksize=self.chunk_size,
            dtype=np.float32,
            callback=audio_callback
        )

        try:
            stream.start()
            logger.info(f"Audio stream started: {self.sample_rate}Hz, {self.channels}ch")
            self.status = CaptureStatus.CAPTURING

            # Yield chunks from queue
            while self.status == CaptureStatus.CAPTURING:
                try:
                    # Wait for audio data with timeout
                    audio_data = await asyncio.wait_for(
                        self._buffer.get(),
                        timeout=5.0
                    )

                    # Calculate audio level
                    audio_level = self._calculate_audio_level(audio_data)
                    self.current_audio_level = audio_level

                    # Create audio chunk
                    chunk = AudioChunk(
                        data=audio_data,
                        timestamp=asyncio.get_event_loop().time(),
                        duration=self.chunk_duration,
                        sample_rate=self.sample_rate,
                        channels=self.channels,
                        audio_level=audio_level
                    )

                    self.total_chunks_captured += 1
                    yield chunk

                except asyncio.TimeoutError:
                    logger.debug("No audio data received (timeout)")
                    continue

        finally:
            stream.stop()
            stream.close()

    def _resample_audio(
        self,
        audio_data: np.ndarray,
        orig_sample_rate: int,
        target_sample_rate: int
    ) -> np.ndarray:
        """
        Resample audio data to a different sample rate.

        Args:
            audio_data: Audio samples as numpy array
            orig_sample_rate: Original sample rate (Hz)
            target_sample_rate: Target sample rate (Hz)

        Returns:
            Resampled audio data

        Note:
            Uses scipy's resample_poly for high-quality resampling.
            This is important for maintaining audio quality when converting
            from device native rate (e.g., 48kHz) to Whisper's 16kHz.
        """
        if orig_sample_rate == target_sample_rate:
            return audio_data

        # Calculate resampling ratio
        # Use resample_poly for better quality than simple decimation
        num_samples = int(len(audio_data) * target_sample_rate / orig_sample_rate)

        resampled = signal.resample(audio_data, num_samples)

        return resampled.astype(np.float32)

    def _calculate_audio_level(self, audio_data: np.ndarray) -> float:
        """
        Calculate the audio level (RMS) for UI feedback.

        Args:
            audio_data: Audio samples as numpy array (float32, range -1.0 to 1.0)

        Returns:
            Audio level from 0.0 (silence) to 1.0 (maximum)

        Note:
            Uses Root Mean Square (RMS) calculation which represents
            the "loudness" of the audio signal.
        """
        # Calculate RMS (Root Mean Square)
        rms = np.sqrt(np.mean(audio_data ** 2))

        # Clamp to [0.0, 1.0] range
        return min(1.0, max(0.0, rms))

    def get_audio_level(self) -> float:
        """
        Get the current audio level (0.0 to 1.0).

        Returns:
            Current audio level for UI visualization
        """
        return self.current_audio_level

    async def stop_capture(self):
        """Stop audio capture and clean up resources."""
        logger.info("Stopping audio capture")
        self.status = CaptureStatus.STOPPED

        # Close stream
        if self._stream and AUDIO_BACKEND == "pyaudiowpatch":
            self._stream.stop_stream()
            self._stream.close()
            self._stream = None

        # Clear buffer
        while not self._buffer.empty():
            try:
                self._buffer.get_nowait()
            except asyncio.QueueEmpty:
                break

        self.current_device = None
        logger.info(f"Audio capture stopped. Total chunks captured: {self.total_chunks_captured}")

    def __del__(self):
        """Cleanup when service is destroyed."""
        if self._pyaudio_instance and AUDIO_BACKEND == "pyaudiowpatch":
            self._pyaudio_instance.terminate()
