from typing import Dict, List
from fastapi import WebSocket
import logging

logger = logging.getLogger(__name__)


class ConnectionManager:
    def __init__(self):
        # Store active connections: meeting_id -> List[WebSocket]
        self.active_connections: Dict[str, List[WebSocket]] = {}

    async def connect(self, websocket: WebSocket, meeting_id: str):
        await websocket.accept()
        if meeting_id not in self.active_connections:
            self.active_connections[meeting_id] = []
        self.active_connections[meeting_id].append(websocket)
        logger.info(f"WebSocket connected for meeting {meeting_id}. Total connections: {len(self.active_connections[meeting_id])}")

    def disconnect(self, websocket: WebSocket, meeting_id: str):
        if meeting_id in self.active_connections:
            if websocket in self.active_connections[meeting_id]:
                self.active_connections[meeting_id].remove(websocket)
                logger.info(f"WebSocket disconnected for meeting {meeting_id}. Remaining: {len(self.active_connections[meeting_id])}")
            if not self.active_connections[meeting_id]:
                del self.active_connections[meeting_id]

    async def broadcast_to_meeting(self, message: dict, meeting_id: str):
        """Broadcast message to all connections for a meeting with passive cleanup."""
        if meeting_id not in self.active_connections:
            return

        dead_connections = []

        for connection in self.active_connections[meeting_id]:
            try:
                await connection.send_json(message)
            except Exception as e:
                # Mark connection for removal (passive cleanup)
                logger.warning(f"WebSocket broadcast failed, marking for cleanup: {e}")
                dead_connections.append(connection)

        # Remove dead connections
        for dead in dead_connections:
            if dead in self.active_connections.get(meeting_id, []):
                self.active_connections[meeting_id].remove(dead)
                logger.info(f"Removed dead WebSocket connection for meeting {meeting_id}")

        # Clean up empty meeting entries
        if meeting_id in self.active_connections and not self.active_connections[meeting_id]:
            del self.active_connections[meeting_id]

    async def broadcast(self, meeting_id: str, message: dict):
        """Alias for broadcast_to_meeting for compatibility."""
        await self.broadcast_to_meeting(message, meeting_id)

    def get_connection_count(self, meeting_id: str) -> int:
        """Get the number of active connections for a meeting."""
        return len(self.active_connections.get(meeting_id, []))


manager = ConnectionManager()
