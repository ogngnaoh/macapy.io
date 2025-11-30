"""
Audio API Endpoints

Provides REST API endpoints for audio device management and capture control.
"""

from typing import List, Optional
from fastapi import APIRouter, HTTPException, BackgroundTasks
from pydantic import BaseModel, Field
import logging

from app.services.audio_capture import AudioCaptureService, AudioDeviceInfo, CaptureStatus

logger = logging.getLogger(__name__)

router = APIRouter()

# Global audio capture service instance
audio_service = AudioCaptureService()

# Active capture task tracking
active_capture_task: Optional[BackgroundTasks] = None


# Pydantic models for API responses
class AudioDeviceResponse(BaseModel):
    """Audio device information for API response"""
    index: int
    name: str
    channels: int
    sample_rate: int
    is_loopback: bool = Field(..., description="True if this is a virtual audio device")
    is_default: bool = Field(..., description="True if this is the default device")


class AudioDeviceListResponse(BaseModel):
    """List of available audio devices"""
    devices: List[AudioDeviceResponse]
    total: int
    loopback_devices: List[AudioDeviceResponse] = Field(
        ...,
        description="Subset of devices that are virtual audio devices (recommended for system audio capture)"
    )


class AudioStatusResponse(BaseModel):
    """Current audio capture status"""
    status: str
    is_capturing: bool
    current_device: Optional[AudioDeviceResponse] = None
    audio_level: float = Field(..., ge=0.0, le=1.0, description="Current audio level (0.0 to 1.0)")
    total_chunks_captured: int


class StartCaptureRequest(BaseModel):
    """Request to start audio capture"""
    device_index: Optional[int] = Field(
        None,
        description="Device index to capture from (None = auto-select virtual audio device)"
    )
    auto_select_loopback: bool = Field(
        True,
        description="Automatically select virtual audio device if device_index is None"
    )


class StartCaptureResponse(BaseModel):
    """Response after starting audio capture"""
    success: bool
    message: str
    device: Optional[AudioDeviceResponse] = None


@router.get("/devices", response_model=AudioDeviceListResponse)
async def list_audio_devices():
    """
    List all available audio input devices.

    Returns device information including virtual audio devices (loopback devices)
    that can capture system audio.

    **For Windows users**: WASAPI loopback devices capture system audio directly.
    **For macOS users**: System Audio via ScreenCaptureKit (requires Screen Recording permission).
    """
    try:
        devices = await audio_service.list_audio_devices()

        device_responses = [
            AudioDeviceResponse(
                index=d.index,
                name=d.name,
                channels=d.channels,
                sample_rate=d.sample_rate,
                is_loopback=d.is_loopback,
                is_default=d.is_default
            )
            for d in devices
        ]

        loopback_devices = [d for d in device_responses if d.is_loopback]

        return AudioDeviceListResponse(
            devices=device_responses,
            total=len(device_responses),
            loopback_devices=loopback_devices
        )

    except Exception as e:
        logger.error(f"Error listing audio devices: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Failed to list audio devices: {str(e)}")


@router.get("/status", response_model=AudioStatusResponse)
async def get_audio_status():
    """
    Get current audio capture status.

    Returns information about whether capture is active, current device,
    and real-time audio level for UI visualization.
    """
    device_response = None
    if audio_service.current_device:
        device_response = AudioDeviceResponse(
            index=audio_service.current_device.index,
            name=audio_service.current_device.name,
            channels=audio_service.current_device.channels,
            sample_rate=audio_service.current_device.sample_rate,
            is_loopback=audio_service.current_device.is_loopback,
            is_default=audio_service.current_device.is_default
        )

    return AudioStatusResponse(
        status=audio_service.status.value,
        is_capturing=(audio_service.status == CaptureStatus.CAPTURING),
        current_device=device_response,
        audio_level=audio_service.get_audio_level(),
        total_chunks_captured=audio_service.total_chunks_captured
    )


@router.post("/start", response_model=StartCaptureResponse)
async def start_audio_capture(request: StartCaptureRequest, background_tasks: BackgroundTasks):
    """
    Start audio capture from the specified device.

    **Note**: This endpoint starts capture but doesn't do anything with the audio yet.
    In Stage 2.2, we'll add transcription integration to process captured audio.

    For now, this is used for testing audio capture functionality.
    """
    global active_capture_task

    # Check if already capturing
    if audio_service.status == CaptureStatus.CAPTURING:
        return StartCaptureResponse(
            success=False,
            message="Audio capture is already running"
        )

    try:
        # For now, we'll just validate the device exists
        # In Stage 2.2, we'll add background task to process audio
        devices = await audio_service.list_audio_devices()

        if request.device_index is not None:
            device = next((d for d in devices if d.index == request.device_index), None)
            if not device:
                raise HTTPException(
                    status_code=404,
                    detail=f"Device index {request.device_index} not found"
                )
        elif request.auto_select_loopback:
            # Auto-select loopback device
            loopback_devices = [d for d in devices if d.is_loopback]
            if not loopback_devices:
                raise HTTPException(
                    status_code=404,
                    detail="System audio capture not available. On macOS, grant Screen Recording permission in System Settings."
                )
            device = loopback_devices[0]
        else:
            raise HTTPException(
                status_code=400,
                detail="Either device_index must be specified or auto_select_loopback must be True"
            )

        # Background processing will be handled by the transcription service
        # For now, just return success
        logger.info(f"Audio capture would start on device: {device.name}")

        return StartCaptureResponse(
            success=True,
            message=f"Ready to capture from: {device.name}",
            device=AudioDeviceResponse(
                index=device.index,
                name=device.name,
                channels=device.channels,
                sample_rate=device.sample_rate,
                is_loopback=device.is_loopback,
                is_default=device.is_default
            )
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error starting audio capture: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Failed to start audio capture: {str(e)}")


@router.post("/stop")
async def stop_audio_capture():
    """
    Stop audio capture.

    Stops the active audio capture and cleans up resources.
    """
    try:
        await audio_service.stop_capture()
        return {
            "success": True,
            "message": "Audio capture stopped",
            "total_chunks_captured": audio_service.total_chunks_captured
        }

    except Exception as e:
        logger.error(f"Error stopping audio capture: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Failed to stop audio capture: {str(e)}")


@router.get("/level")
async def get_audio_level():
    """
    Get current audio level for UI visualization.

    Returns the current audio level (0.0 to 1.0) which can be used
    to display a visual indicator in the UI.

    This endpoint is designed to be polled frequently (e.g., every 100ms)
    for real-time audio level display.
    """
    return {
        "audio_level": audio_service.get_audio_level(),
        "is_capturing": audio_service.status == CaptureStatus.CAPTURING
    }
