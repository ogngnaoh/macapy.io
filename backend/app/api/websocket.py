from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from app.services.websocket_manager import manager

router = APIRouter()

@router.websocket("/ws/meeting/{meeting_id}")
async def websocket_endpoint(websocket: WebSocket, meeting_id: str):
    await manager.connect(websocket, meeting_id)
    try:
        while True:
            # Keep the connection alive and listen for any client messages (optional)
            # For now, we just receive text, but we could handle control messages here
            data = await websocket.receive_text()
            # Echo back or process if needed (currently just a placeholder)
            # await manager.broadcast_to_meeting({"message": f"Client said: {data}"}, meeting_id)
    except WebSocketDisconnect:
        manager.disconnect(websocket, meeting_id)
        # Optional: Broadcast that a user left
        # await manager.broadcast_to_meeting({"type": "system", "message": "User disconnected"}, meeting_id)
