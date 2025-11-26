from fastapi import APIRouter
from app.api import audio, meetings, transcripts, websocket, documents, ai

api_router = APIRouter()
api_router.include_router(audio.router, prefix="/audio", tags=["audio"])
api_router.include_router(meetings.router, prefix="/meetings", tags=["meetings"])
api_router.include_router(transcripts.router, prefix="/transcripts", tags=["transcripts"])
api_router.include_router(websocket.router, tags=["websocket"])
api_router.include_router(documents.router, tags=["documents"])
api_router.include_router(ai.router, tags=["ai"])

