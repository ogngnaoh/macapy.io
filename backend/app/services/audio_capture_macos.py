"""
macOS Audio Capture using ScreenCaptureKit (macOS 12.3+)

This module provides native system audio capture on macOS without requiring
third-party virtual audio devices like BlackHole.

Features:
- Captures system audio directly using ScreenCaptureKit
- Captures microphone input using AVFoundation
- Supports dual capture (system + mic) with separate streams
- Low latency, non-invasive (user can still hear audio normally)
- No configuration required

Requirements:
- macOS 12.3 or later
- pyobjc-framework-ScreenCaptureKit
- pyobjc-framework-AVFoundation
"""

import asyncio
import logging
import platform
from typing import AsyncGenerator, Optional, List
from dataclasses import dataclass
import numpy as np
from scipy import signal

from app.config import settings

logger = logging.getLogger(__name__)

# Check macOS version safely
try:
    _ver_str = platform.mac_ver()[0]
    if _ver_str:
        MACOS_VERSION = tuple(map(int, _ver_str.split('.')[:2]))
    else:
        MACOS_VERSION = (0, 0)
except (ValueError, IndexError, AttributeError):
    MACOS_VERSION = (0, 0)

SCREENCAPTUREKIT_AVAILABLE = MACOS_VERSION >= (12, 3)

if SCREENCAPTUREKIT_AVAILABLE:
    try:
        import objc
        import ctypes
        from Foundation import NSObject, NSRunLoop, NSDefaultRunLoopMode
        from AVFoundation import (
            AVCaptureSession, AVCaptureDevice, AVCaptureDeviceInput,
            AVCaptureAudioDataOutput, AVMediaTypeAudio
        )
        from CoreMedia import CMTimeMake
        # ScreenCaptureKit imports
        import ScreenCaptureKit
        from ScreenCaptureKit import (
            SCContentFilter, SCStreamConfiguration, SCStream,
            SCShareableContent,
            SCStreamOutputTypeAudio,  # Constant value = 1
        )

        # Load libdispatch for creating dispatch queues
        _libdispatch = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        _dispatch_queue_create = _libdispatch.dispatch_queue_create
        _dispatch_queue_create.argtypes = [ctypes.c_char_p, ctypes.c_void_p]
        _dispatch_queue_create.restype = ctypes.c_void_p

        def create_dispatch_queue(label: bytes) -> ctypes.c_void_p:
            """Create a serial dispatch queue."""
            return _dispatch_queue_create(label, None)

        PYOBJC_AVAILABLE = True
    except ImportError as e:
        logger.warning(f"PyObjC frameworks not available: {e}")
        PYOBJC_AVAILABLE = False
    except Exception as e:
        # Catch any other errors (e.g., OSError loading dylib, attribute errors)
        logger.warning(f"Failed to initialize PyObjC: {e}")
        PYOBJC_AVAILABLE = False
else:
    PYOBJC_AVAILABLE = False
    if MACOS_VERSION != (0, 0):
        logger.info(f"ScreenCaptureKit requires macOS 12.3+, current: {MACOS_VERSION}")
    else:
        logger.info("Not running on macOS, ScreenCaptureKit not available")


# Define delegate classes at module level to avoid re-definition errors
# These are only defined if PyObjC is available
_SCStreamDelegate = None
_SCStreamOutputDelegate = None
_AVCaptureAudioDelegate = None

if PYOBJC_AVAILABLE:
    # Registry to keep references to capture services for delegates
    # Key is the id() of the delegate object
    _delegate_to_service = {}

    # Audio accumulation buffers (keyed by delegate id)
    _system_audio_accumulator = {}  # id -> list of audio arrays
    _mic_audio_accumulator = {}  # id -> list of audio arrays
    _system_chunk_start_time = {}  # id -> timestamp when accumulation started
    _mic_chunk_start_time = {}  # id -> timestamp when accumulation started

    class _SCStreamDelegateImpl(NSObject):
        """SCStreamDelegate for handling stream events."""

        def stream_didStopWithError_(self, stream, error):
            if error:
                logger.error(f"Stream stopped with error: {error}")

    _SCStreamDelegate = _SCStreamDelegateImpl



    class _SCStreamOutputDelegateImpl(NSObject):
        """SCStreamOutput delegate for handling audio samples."""

        def stream_didOutputSampleBuffer_ofType_(self, stream, sample_buffer, output_type):
            if output_type == SCStreamOutputTypeAudio:
                try:
                    service = _delegate_to_service.get(id(self))
                    if service is None:
                        return
                    
                    result = service._extract_audio_from_sample_buffer(sample_buffer)
                    if result is None:
                        return
                        
                    audio_data, device_rate = result
                    
                    if audio_data is not None and len(audio_data) > 0:
                        # Resample if needed
                        if device_rate != service.sample_rate:
                            audio_data = service._resample_audio(audio_data, device_rate, service.sample_rate)
                        
                        import time
                        delegate_id = id(self)

                        # Initialize accumulator if needed
                        if delegate_id not in _system_audio_accumulator:
                            _system_audio_accumulator[delegate_id] = []
                            _system_chunk_start_time[delegate_id] = time.time()

                        # Accumulate audio samples
                        _system_audio_accumulator[delegate_id].append(audio_data)

                        # Calculate total samples accumulated
                        total_samples = sum(len(arr) for arr in _system_audio_accumulator[delegate_id])

                        # Only yield when we have enough samples for chunk_duration
                        if total_samples >= service.chunk_size:
                            # Concatenate all accumulated audio
                            combined = np.concatenate(_system_audio_accumulator[delegate_id])

                            # Take exactly chunk_size samples
                            chunk_data = combined[:service.chunk_size]

                            # Keep remainder for next chunk
                            remainder = combined[service.chunk_size:]
                            _system_audio_accumulator[delegate_id] = [remainder] if len(remainder) > 0 else []

                            chunk = AudioChunk(
                                data=chunk_data,
                                timestamp=_system_chunk_start_time[delegate_id],
                                duration=service.chunk_duration,
                                sample_rate=service.sample_rate,
                                channels=service.channels,
                                audio_level=service._calculate_audio_level(chunk_data),
                                source="system"
                            )

                            # Update start time for next chunk
                            _system_chunk_start_time[delegate_id] = time.time()

                            try:
                                service._system_buffer.put_nowait(chunk)
                            except asyncio.QueueFull:
                                logger.warning(
                                    f"System audio buffer full, dropping chunk at {chunk.timestamp:.2f}s "
                                    f"(level={chunk.audio_level:.4f})"
                                )
                except Exception as e:
                    logger.error(f"Error processing audio sample: {e}")

    _SCStreamOutputDelegate = _SCStreamOutputDelegateImpl

    class _AVCaptureAudioDelegateImpl(NSObject):
        """AVCaptureAudioDataOutputSampleBufferDelegate for handling mic samples."""

        def captureOutput_didOutputSampleBuffer_fromConnection_(self, output, sample_buffer, connection):
            try:
                service = _delegate_to_service.get(id(self))
                if service is None:
                    return
                
                result = service._extract_audio_from_sample_buffer(sample_buffer)
                if result is None:
                    return
                    
                audio_data, device_rate = result
                
                if audio_data is not None and len(audio_data) > 0:
                    # Resample if needed
                    if device_rate != service.sample_rate:
                        audio_data = service._resample_audio(audio_data, device_rate, service.sample_rate)
                    
                    import time
                    delegate_id = id(self)

                    # Initialize accumulator if needed
                    if delegate_id not in _mic_audio_accumulator:
                        _mic_audio_accumulator[delegate_id] = []
                        _mic_chunk_start_time[delegate_id] = time.time()

                    # Accumulate audio samples
                    _mic_audio_accumulator[delegate_id].append(audio_data)

                    # Calculate total samples accumulated
                    total_samples = sum(len(arr) for arr in _mic_audio_accumulator[delegate_id])

                    # Only yield when we have enough samples for chunk_duration
                    if total_samples >= service.chunk_size:
                        # Concatenate all accumulated audio
                        combined = np.concatenate(_mic_audio_accumulator[delegate_id])

                        # Take exactly chunk_size samples
                        chunk_data = combined[:service.chunk_size]

                        # Keep remainder for next chunk
                        remainder = combined[service.chunk_size:]
                        _mic_audio_accumulator[delegate_id] = [remainder] if len(remainder) > 0 else []

                        chunk = AudioChunk(
                            data=chunk_data,
                            timestamp=_mic_chunk_start_time[delegate_id],
                            duration=service.chunk_duration,
                            sample_rate=service.sample_rate,
                            channels=service.channels,
                            audio_level=service._calculate_audio_level(chunk_data),
                            source="user"
                        )

                        # Update start time for next chunk
                        _mic_chunk_start_time[delegate_id] = time.time()

                        try:
                            service._mic_buffer.put_nowait(chunk)
                        except asyncio.QueueFull:
                            logger.warning(
                                f"Mic audio buffer full, dropping chunk at {chunk.timestamp:.2f}s "
                                f"(level={chunk.audio_level:.4f})"
                            )
            except Exception as e:
                logger.debug(f"Error processing mic sample: {e}")

    _AVCaptureAudioDelegate = _AVCaptureAudioDelegateImpl


@dataclass
class AudioChunk:
    """Container for audio data chunk"""
    data: np.ndarray
    timestamp: float
    duration: float
    sample_rate: int
    channels: int
    audio_level: float
    source: str  # "system" or "user"


class ScreenCaptureKitAudioCapture:
    """
    Captures system audio using ScreenCaptureKit (macOS 12.3+).

    This provides native system audio capture without requiring
    virtual audio devices. The user can still hear all audio normally.
    """

    def __init__(
        self,
        sample_rate: int = settings.AUDIO_SAMPLE_RATE,
        channels: int = settings.AUDIO_CHANNELS,
        chunk_duration: float = settings.AUDIO_CHUNK_DURATION,
    ):
        self.sample_rate = sample_rate
        self.channels = channels
        self.chunk_duration = chunk_duration
        self.chunk_size = int(sample_rate * chunk_duration)

        self._system_stream: Optional[SCStream] = None
        self._mic_session: Optional[AVCaptureSession] = None
        self._is_capturing = False

        self._system_buffer = asyncio.Queue(maxsize=100)
        self._mic_buffer = asyncio.Queue(maxsize=100)

        logger.info(
            f"ScreenCaptureKitAudioCapture initialized: "
            f"sample_rate={sample_rate}, channels={channels}, "
            f"chunk_duration={chunk_duration}s"
        )
        
    def _resample_audio(
        self,
        audio_data: np.ndarray,
        orig_sample_rate: int,
        target_sample_rate: int
    ) -> np.ndarray:
        """
        Resample audio data to a different sample rate.
        """
        if orig_sample_rate == target_sample_rate:
            return audio_data

        # Calculate resampling ratio
        num_samples = int(len(audio_data) * target_sample_rate / orig_sample_rate)

        # Use resample (FFT-based) for speed/quality balance on chunks
        # Note: resample_poly is generally better but might be slower for small chunks
        resampled = signal.resample(audio_data, num_samples)

        return resampled.astype(np.float32)

    @staticmethod
    def is_available() -> bool:
        """Check if ScreenCaptureKit is available on this system."""
        return SCREENCAPTUREKIT_AVAILABLE and PYOBJC_AVAILABLE

    async def list_audio_devices(self) -> List[dict]:
        """List available audio input devices (microphones)."""
        devices = []

        if not PYOBJC_AVAILABLE:
            return devices

        try:
            # Get audio input devices using AVFoundation
            av_devices = AVCaptureDevice.devicesWithMediaType_(AVMediaTypeAudio)

            for i, device in enumerate(av_devices):
                devices.append({
                    "index": i,
                    "name": str(device.localizedName()),
                    "unique_id": str(device.uniqueID()),
                    "is_loopback": False,
                    "is_default": device == AVCaptureDevice.defaultDeviceWithMediaType_(AVMediaTypeAudio)
                })

            # Add virtual "System Audio" device representing ScreenCaptureKit
            devices.insert(0, {
                "index": -1,
                "name": "System Audio (ScreenCaptureKit)",
                "unique_id": "screencapturekit-system",
                "is_loopback": True,
                "is_default": False
            })

        except Exception as e:
            logger.error(f"Error listing audio devices: {e}")

        return devices

    async def capture_audio(
        self,
        capture_system: bool = True,
        capture_mic: bool = True,
        mic_device_id: Optional[str] = None
    ) -> AsyncGenerator[AudioChunk, None]:
        """
        Capture audio from system and/or microphone.

        Args:
            capture_system: Capture system audio via ScreenCaptureKit
            capture_mic: Capture microphone input
            mic_device_id: Specific microphone device ID (None = default)

        Yields:
            AudioChunk objects with source="system" or source="user"
        """
        if not self.is_available():
            raise RuntimeError(
                "ScreenCaptureKit not available. "
                f"Requires macOS 12.3+, current: {'.'.join(map(str, MACOS_VERSION))}"
            )

        self._is_capturing = True
        tasks = []

        try:
            # Start system audio capture
            if capture_system:
                await self._start_system_capture()
                tasks.append(asyncio.create_task(self._read_system_audio()))

            # Start microphone capture
            if capture_mic:
                await self._start_mic_capture(mic_device_id)
                tasks.append(asyncio.create_task(self._read_mic_audio()))

            if not tasks:
                raise ValueError("At least one audio source must be enabled")

            # Yield audio chunks from both sources
            while self._is_capturing:
                try:
                    # Check system audio buffer
                    if capture_system:
                        try:
                            chunk = self._system_buffer.get_nowait()
                            yield chunk
                        except asyncio.QueueEmpty:
                            pass

                    # Check mic buffer
                    if capture_mic:
                        try:
                            chunk = self._mic_buffer.get_nowait()
                            yield chunk
                        except asyncio.QueueEmpty:
                            pass

                    # Small delay to prevent busy loop
                    await asyncio.sleep(0.01)

                except Exception as e:
                    logger.error(f"Error in capture loop: {e}")
                    break

        finally:
            self._is_capturing = False
            for task in tasks:
                task.cancel()
            await self._stop_capture()

    async def _start_system_capture(self):
        """Start capturing system audio using ScreenCaptureKit."""
        logger.info("Starting ScreenCaptureKit system audio capture...")

        try:
            # Get shareable content (we need this to create a filter)
            content = await self._get_shareable_content()
            self._content = content  # Keep reference

            if not content:
                raise RuntimeError("Failed to get shareable content")

            # Create stream configuration for audio only
            config = SCStreamConfiguration.alloc().init()
            config.setCapturesAudio_(True)
            config.setExcludesCurrentProcessAudio_(False)
            config.setSampleRate_(self.sample_rate)
            config.setChannelCount_(self.channels)

            # We don't need video, but SCK requires a display
            # Set minimal video config
            config.setWidth_(100)
            config.setHeight_(100)
            config.setMinimumFrameInterval_(CMTimeMake(1, 30))  # 30 FPS
            config.setShowsCursor_(False)
            self._config = config  # Keep reference

            # Create content filter (capture all audio)
            displays = content.displays()
            self._displays = displays  # Keep reference
            if displays and len(displays) > 0:
                # Filter for main display (captures all system audio)
                content_filter = SCContentFilter.alloc().initWithDisplay_excludingWindows_(
                    displays[0], []
                )
                self._content_filter = content_filter  # Keep reference
            else:
                raise RuntimeError("No displays found")

            # Create delegates
            stream_delegate = self._create_stream_delegate()
            self._stream_delegate = stream_delegate  # Keep reference

            # Create and configure stream
            self._system_stream = SCStream.alloc().initWithFilter_configuration_delegate_(
                content_filter, config, stream_delegate
            )

            # Create dispatch queue for audio processing
            queue_ptr = create_dispatch_queue(b"com.macapy.sck_audio")
            dispatch_queue = objc.objc_object(c_void_p=queue_ptr)
            self._dispatch_queue = dispatch_queue  # Keep reference

            # Add audio output with dispatch queue
            audio_delegate = self._create_audio_output_delegate()
            success, error = self._system_stream.addStreamOutput_type_sampleHandlerQueue_error_(
                audio_delegate,
                SCStreamOutputTypeAudio,  # Value = 1
                dispatch_queue,
                None
            )
            if not success:
                raise RuntimeError(f"Failed to add audio output to stream: {error}")

            # Start capture
            await self._start_stream()

            logger.info("ScreenCaptureKit system audio capture started")

        except Exception as e:
            logger.error(f"Failed to start system audio capture: {e}")
            raise

    async def _get_shareable_content(self):
        """Get SCShareableContent asynchronously."""
        loop = asyncio.get_event_loop()
        future = loop.create_future()

        def completion_handler(content, error):
            try:
                if error:
                    loop.call_soon_threadsafe(
                        future.set_exception,
                        RuntimeError(f"Failed to get shareable content: {error}")
                    )
                else:
                    loop.call_soon_threadsafe(future.set_result, content)
            except RuntimeError:
                # Loop might be closed if test finished
                pass

        SCShareableContent.getShareableContentExcludingDesktopWindows_onScreenWindowsOnly_completionHandler_(
            False, False, completion_handler
        )

        return await future

    async def _start_stream(self):
        """Start the SCStream asynchronously."""
        loop = asyncio.get_event_loop()
        future = loop.create_future()

        def completion_handler(error):
            try:
                if error:
                    loop.call_soon_threadsafe(
                        future.set_exception,
                        RuntimeError(f"Failed to start stream: {error}")
                    )
                else:
                    loop.call_soon_threadsafe(future.set_result, None)
            except RuntimeError:
                pass

        self._system_stream.startCaptureWithCompletionHandler_(completion_handler)

        await future

    def _create_stream_delegate(self):
        """Create SCStreamDelegate for handling stream events."""
        return _SCStreamDelegate.alloc().init()

    def _create_audio_output_delegate(self):
        """Create delegate for handling audio samples."""
        delegate = _SCStreamOutputDelegate.alloc().init()
        # Register this service with the delegate
        _delegate_to_service[id(delegate)] = self
        # Keep reference to prevent garbage collection
        self._audio_delegate = delegate
        return delegate

    # Track if we've logged the audio format (to avoid spam)
    _format_logged = False

    def _extract_audio_from_sample_buffer(self, sample_buffer) -> Optional[tuple[np.ndarray, int]]:
        """Extract audio samples from CMSampleBuffer as numpy array.

        Returns:
            Tuple of (audio_data, sample_rate) or None if extraction failed.
        """
        try:
            from CoreMedia import (
                CMSampleBufferGetDataBuffer,
                CMSampleBufferGetFormatDescription,
                CMBlockBufferGetDataLength,
                CMBlockBufferCopyDataBytes,
                CMAudioFormatDescriptionGetStreamBasicDescription,
            )
            # AudioToolbox constants
            kAudioFormatFlagIsFloat = 1  # (1 << 0)
            kAudioFormatFlagIsSignedInteger = 4  # (1 << 2)

            # Get the data buffer
            data_buffer = CMSampleBufferGetDataBuffer(sample_buffer)
            if not data_buffer:
                return None

            # Get buffer length
            length = CMBlockBufferGetDataLength(data_buffer)
            if length == 0:
                return None

            # Copy data
            data = bytearray(length)
            CMBlockBufferCopyDataBytes(data_buffer, 0, length, data)

            # Default fallback sample rate
            sample_rate = self.sample_rate

            # Get format description to determine audio format
            format_desc = CMSampleBufferGetFormatDescription(sample_buffer)
            if format_desc:
                asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format_desc)
                if asbd:
                    bits_per_channel = asbd.mBitsPerChannel
                    format_flags = asbd.mFormatFlags
                    sample_rate = int(asbd.mSampleRate)
                    channels = asbd.mChannelsPerFrame

                    # Log format once for debugging
                    if not ScreenCaptureKitAudioCapture._format_logged:
                        logger.info(
                            f"Audio format detected: {bits_per_channel}-bit, "
                            f"flags=0x{format_flags:x}, rate={sample_rate}Hz, "
                            f"channels={channels}, "
                            f"float={bool(format_flags & kAudioFormatFlagIsFloat)}"
                        )
                        ScreenCaptureKitAudioCapture._format_logged = True

                    # Handle different formats
                    if bits_per_channel == 32 and (format_flags & kAudioFormatFlagIsFloat):
                        # Float32 format (ScreenCaptureKit default)
                        audio = np.frombuffer(data, dtype=np.float32)
                        return audio, sample_rate
                    elif bits_per_channel == 16:
                        # Int16 PCM format (some microphones)
                        audio = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
                        return audio, sample_rate
                    else:
                        logger.warning(
                            f"Unexpected audio format: {bits_per_channel}-bit, flags=0x{format_flags:x}"
                        )

            # Fallback: Try to detect format by buffer size
            bytes_per_sample_float32 = 4
            bytes_per_sample_int16 = 2

            # Try float32 first
            if length % bytes_per_sample_float32 == 0:
                audio = np.frombuffer(data, dtype=np.float32)
                if np.abs(audio).max() <= 2.0:
                    return audio, sample_rate

            # Fallback to int16
            if length % bytes_per_sample_int16 == 0:
                audio = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
                return audio, sample_rate

            logger.warning(f"Could not determine audio format for buffer of {length} bytes")
            return None

        except Exception as e:
            logger.error(f"Error extracting audio: {e}")
            return None

    async def _start_mic_capture(self, device_id: Optional[str] = None):
        """Start capturing microphone audio using AVFoundation."""
        logger.info("Starting microphone capture...")

        try:
            # Create capture session
            session = AVCaptureSession.alloc().init()

            # Get microphone device
            if device_id:
                device = AVCaptureDevice.deviceWithUniqueID_(device_id)
            else:
                device = AVCaptureDevice.defaultDeviceWithMediaType_(AVMediaTypeAudio)

            if not device:
                raise RuntimeError("No microphone found")

            logger.info(f"Using microphone: {device.localizedName()}")

            # Create input - PyObjC returns tuple (result, error) for error: methods
            input_device, error = AVCaptureDeviceInput.deviceInputWithDevice_error_(device, None)
            if error or not input_device:
                raise RuntimeError(f"Failed to create input: {error}")

            # Add input to session
            if session.canAddInput_(input_device):
                session.addInput_(input_device)
            else:
                raise RuntimeError("Cannot add microphone input")

            # Create audio output with proper dispatch queue
            audio_output = AVCaptureAudioDataOutput.alloc().init()

            # Create dispatch queue for audio processing
            queue_ptr = create_dispatch_queue(b"com.macapy.mic_capture")
            # Convert ctypes pointer to objc object for PyObjC
            dispatch_queue = objc.objc_object(c_void_p=queue_ptr)

            # Create and set delegate
            mic_delegate = self._create_mic_delegate()
            audio_output.setSampleBufferDelegate_queue_(mic_delegate, dispatch_queue)

            # Add output to session
            if session.canAddOutput_(audio_output):
                session.addOutput_(audio_output)
            else:
                raise RuntimeError("Cannot add audio output")

            # Start session
            session.startRunning()
            self._mic_session = session

            logger.info("Microphone capture started")

        except Exception as e:
            logger.error(f"Failed to start microphone capture: {e}")
            raise

    def _create_mic_delegate(self):
        """Create delegate for handling microphone samples."""
        delegate = _AVCaptureAudioDelegate.alloc().init()
        # Register this service with the delegate
        _delegate_to_service[id(delegate)] = self
        # Keep reference to prevent garbage collection
        self._mic_delegate_obj = delegate
        return delegate

    async def _read_system_audio(self):
        """Background task to keep RunLoop running for system audio."""
        while self._is_capturing:
            await asyncio.sleep(0.1)

    async def _read_mic_audio(self):
        """Background task to keep RunLoop running for mic audio."""
        while self._is_capturing:
            await asyncio.sleep(0.1)

    def _calculate_audio_level(self, audio_data: np.ndarray) -> float:
        """Calculate RMS audio level."""
        rms = np.sqrt(np.mean(audio_data ** 2))
        return min(1.0, max(0.0, rms))

    async def _stop_capture(self):
        """Stop all audio capture."""
        logger.info("Stopping audio capture...")

        if self._system_stream:
            try:
                logger.info("Stopping system stream...")
                # self._system_stream.stopCaptureWithCompletionHandler_(completion_handler)
                # await asyncio.wait_for(future, timeout=5.0)
                
                # Explicitly stopping causes a SIGTRAP/crash on some systems/configurations.
                # Relying on deallocation (setting to None) seems to work safely.
                logger.info("Skipping explicit stopCapture to avoid crash, relying on deallocation")
                
                logger.info("System stream stopped (via release)")
            except Exception as e:
                logger.warning(f"Error stopping system stream: {e}")
            finally:
                self._system_stream = None

        if self._mic_session:
            try:
                logger.info("Stopping mic session...")
                self._mic_session.stopRunning()
                logger.info("Mic session stopped")
            except Exception as e:
                logger.warning(f"Error stopping mic session: {e}")
            finally:
                self._mic_session = None

        # Cleanup delegate registry and accumulators
        logger.info("Cleaning up delegates...")
        if hasattr(self, '_audio_delegate'):
            delegate_id = id(self._audio_delegate)
            if delegate_id in _delegate_to_service:
                del _delegate_to_service[delegate_id]
            if delegate_id in _system_audio_accumulator:
                del _system_audio_accumulator[delegate_id]
            if delegate_id in _system_chunk_start_time:
                del _system_chunk_start_time[delegate_id]

        if hasattr(self, '_mic_delegate_obj'):
            delegate_id = id(self._mic_delegate_obj)
            if delegate_id in _delegate_to_service:
                del _delegate_to_service[delegate_id]
            if delegate_id in _mic_audio_accumulator:
                del _mic_audio_accumulator[delegate_id]
            if delegate_id in _mic_chunk_start_time:
                del _mic_chunk_start_time[delegate_id]

        logger.info("Audio capture stopped")

    async def stop_capture(self):
        """Public method to stop capture."""
        self._is_capturing = False
        await self._stop_capture()


# Factory function to get the best audio capture for the platform
def get_audio_capture_service():
    """
    Get the best audio capture service for the current platform.

    Returns ScreenCaptureKitAudioCapture on macOS 12.3+,
    falls back to standard AudioCaptureService otherwise.
    """
    if ScreenCaptureKitAudioCapture.is_available():
        logger.info("Using ScreenCaptureKit for audio capture (macOS 12.3+)")
        return ScreenCaptureKitAudioCapture()
    else:
        logger.info("ScreenCaptureKit not available, using sounddevice fallback")
        from app.services.audio_capture import AudioCaptureService
        return AudioCaptureService()
